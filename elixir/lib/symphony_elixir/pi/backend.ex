defmodule SymphonyElixir.Pi.Backend do
  @moduledoc """
  Pi RPC execution backend.

  This adapter is intentionally local-only during the first integration slice. It keeps Pi's
  native session and event model behind the execution boundary instead of making the orchestrator
  speak a Codex-shaped protocol.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.{Config, Pi.Rpc}

  @type session :: %{
          rpc: Rpc.session(),
          session_id: String.t() | nil
        }

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) ->
        {:error, {:unsupported_backend_worker_host, :pi, host}}

      _ ->
        start_local_session(workspace)
    end
  end

  defp start_local_session(workspace) do
    config = Config.settings!()
    stderr_path = Path.join(workspace, ".symphony/pi-rpc.stderr.log")

    case Rpc.start(
           workspace,
           config.pi.command,
           stderr_path: stderr_path,
           env: tracker_secret_port_env(config)
         ) do
      {:ok, rpc} -> initialize_session(rpc, config)
      {:error, _reason} = error -> error
    end
  end

  defp initialize_session(rpc, config) do
    case Rpc.request(rpc, "get_state", %{}, timeout_ms: config.codex.read_timeout_ms) do
      {:ok, response} ->
        case session_id_from_state(response) do
          session_id when is_binary(session_id) ->
            {:ok, %{rpc: rpc, session_id: session_id}}

          _ ->
            Rpc.close(rpc)
            {:error, {:invalid_session_state, :missing_session_id}}
        end

      {:error, reason} ->
        Rpc.close(rpc)
        {:error, reason}
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{rpc: rpc, session_id: session_id}, prompt, issue, opts)
      when is_binary(prompt) and is_map(issue) do
    config = Config.settings!()
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    timeout_ms = Keyword.get(opts, :timeout_ms, config.codex.turn_timeout_ms)
    session_name = "#{issue.identifier}: #{issue.title}"

    on_event = fn event -> emit_event(on_message, event) end

    on_message.(%{
      event: :session_started,
      payload: %{session_id: session_id},
      session_id: session_id,
      timestamp: DateTime.utc_now(),
      backend: :pi
    })

    case Rpc.request(
           rpc,
           "set_session_name",
           %{"name" => session_name},
           timeout_ms: config.codex.read_timeout_ms,
           on_event: on_event
         ) do
      {:ok, _} ->
        run_prompt_turn(rpc, session_id, prompt, config, on_message, on_event, timeout_ms)

      {:error, reason} ->
        emit_turn_error(on_message, reason)
        {:error, reason}
    end
  end

  defp run_prompt_turn(rpc, session_id, prompt, config, on_message, on_event, timeout_ms) do
    case Rpc.request(
           rpc,
           "prompt",
           %{"message" => prompt},
           timeout_ms: timeout_ms,
           on_event: on_event,
           until: &settled_event?/1
         ) do
      {:ok, prompt_response} ->
        complete_turn(rpc, session_id, prompt_response, config, on_message, on_event)

      {:error, :timeout} ->
        abort_after_timeout(rpc, config, on_message, on_event)

      {:error, reason} ->
        emit_turn_error(on_message, reason)
        {:error, reason}
    end
  end

  defp complete_turn(rpc, session_id, prompt_response, config, on_message, on_event) do
    with {:ok, assistant_response} <-
           Rpc.request(
             rpc,
             "get_last_assistant_text",
             %{},
             timeout_ms: config.codex.read_timeout_ms,
             on_event: on_event
           ),
         {:ok, stats_response} <-
           Rpc.request(
             rpc,
             "get_session_stats",
             %{},
             timeout_ms: config.codex.read_timeout_ms,
             on_event: on_event
           ) do
      emit_usage(on_message, stats_response)

      {:ok,
       %{
         result: assistant_response,
         session_id: session_id,
         turn_id: Map.get(prompt_response, "id"),
         stats: stats_response,
         stderr_path: rpc.stderr_path
       }}
    else
      {:error, reason} ->
        emit_turn_error(on_message, reason)
        {:error, reason}
    end
  end

  defp abort_after_timeout(rpc, config, on_message, on_event) do
    outcome =
      case Rpc.request(rpc, "abort", %{}, timeout_ms: config.codex.read_timeout_ms, on_event: on_event) do
        {:ok, _response} -> :acknowledged
        {:error, reason} -> {:failed, reason}
      end

    on_message.(%{
      event: :turn_aborted,
      payload: %{reason: :timeout, outcome: outcome},
      timestamp: DateTime.utc_now(),
      backend: :pi
    })

    case outcome do
      :acknowledged -> {:error, {:turn_timeout, :abort_acknowledged}}
      {:failed, reason} -> {:error, {:turn_timeout, {:abort_failed, reason}}}
    end
  end

  defp emit_turn_error(on_message, reason) do
    on_message.(%{
      event: :turn_ended_with_error,
      payload: %{reason: reason},
      timestamp: DateTime.utc_now(),
      backend: :pi
    })
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(%{rpc: rpc}), do: Rpc.close(rpc)

  defp tracker_secret_port_env(%{tracker: %{secret_environment_names: names}})
       when is_list(names) do
    Enum.map(names, &{String.to_charlist(&1), false})
  end

  defp tracker_secret_port_env(_config), do: []

  defp session_id_from_state(%{"data" => %{"sessionId" => session_id}}) when is_binary(session_id),
    do: session_id

  defp session_id_from_state(_response), do: nil

  defp settled_event?(%{"type" => "agent_settled"}), do: true
  defp settled_event?(%{"type" => "agent_end", "willRetry" => false}), do: true
  defp settled_event?(_event), do: false

  defp emit_event(on_message, event) when is_function(on_message, 1) and is_map(event) do
    on_message.(%{
      event: event_name(event),
      payload: event,
      raw: Jason.encode!(event),
      timestamp: DateTime.utc_now(),
      backend: :pi
    })
  end

  defp emit_usage(on_message, %{"data" => %{"tokens" => tokens}})
       when is_function(on_message, 1) and is_map(tokens) do
    usage = normalize_usage(tokens)

    if map_size(usage) > 0 do
      on_message.(%{
        event: :usage,
        payload: %{"usage" => usage},
        usage: usage,
        timestamp: DateTime.utc_now(),
        backend: :pi
      })
    end
  end

  defp emit_usage(_on_message, _response), do: :ok

  defp normalize_usage(tokens) do
    tokens
    |> copy_integer(tokens, "input", "input_tokens")
    |> copy_integer(tokens, "output", "output_tokens")
    |> copy_integer(tokens, "total", "total_tokens")
  end

  defp copy_integer(usage, tokens, source, target) do
    case Map.get(tokens, source) do
      value when is_integer(value) and value >= 0 -> Map.put(usage, target, value)
      _ -> usage
    end
  end

  defp event_name(%{"type" => "agent_start"}), do: :agent_started
  defp event_name(%{"type" => "agent_end"}), do: :agent_ended
  defp event_name(%{"type" => "agent_settled"}), do: :agent_settled
  defp event_name(%{"type" => "turn_start"}), do: :turn_started
  defp event_name(%{"type" => "turn_end"}), do: :turn_ended
  defp event_name(%{"type" => "message_update"}), do: :message_update
  defp event_name(%{"type" => "tool_execution_start"}), do: :tool_execution_started
  defp event_name(%{"type" => "tool_execution_update"}), do: :tool_execution_updated
  defp event_name(%{"type" => "tool_execution_end"}), do: :tool_execution_ended
  defp event_name(%{"type" => "extension_ui_request"}), do: :extension_ui_request
  defp event_name(%{"type" => type}) when is_binary(type), do: :notification
  defp event_name(_event), do: :notification

  defp default_on_message(_message), do: :ok
end
