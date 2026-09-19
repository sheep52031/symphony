defmodule SymphonyElixir.Pi.Backend do
  @moduledoc """
  Pi RPC execution backend.

  This adapter is local-only and keeps Pi's native session and event model behind the execution
  boundary rather than making the orchestrator speak a Codex-shaped protocol.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.{Config, Pi.Rpc}

  @pi_isolation_flags [
    "--no-extensions",
    "--no-skills",
    "--no-themes",
    "--no-prompt-templates",
    "--no-context-files",
    "--no-approve"
  ]
  @pi_secret_name_pattern ~r/(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE[_-]?KEY)/i

  @type session :: %{
          rpc: Rpc.session(),
          session_id: String.t(),
          session_state: map()
        }

  @impl true
  @spec validate_config(SymphonyElixir.Config.Schema.t()) :: :ok | {:error, term()}
  def validate_config(%{worker: %{ssh_hosts: hosts}}) when is_list(hosts) do
    if Enum.any?(hosts, &(is_binary(&1) and String.trim(&1) != "")) do
      {:error, {:unsupported_backend_worker_hosts, :pi}}
    else
      :ok
    end
  end

  def validate_config(_settings), do: :ok

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) -> {:error, {:unsupported_backend_worker_host, :pi, host}}
      _ -> start_local_session(workspace)
    end
  end

  defp start_local_session(workspace) do
    config = Config.settings!()
    stderr_path = Path.join(workspace, ".symphony/pi-rpc.stderr.log")

    with {:ok, isolation} <- prepare_pi_isolation(workspace),
         {:ok, rpc} <-
           Rpc.start(workspace, pi_command(config.pi.command, isolation),
             stderr_path: stderr_path,
             env: pi_secret_port_env() ++ tracker_secret_port_env(config) ++ pi_isolation_environment(isolation)
           ) do
      initialize_session(rpc, config)
    end
  end

  defp initialize_session(rpc, config) do
    case Rpc.request(rpc, "get_state", %{}, timeout_ms: timeout_ms(config, :request)) do
      {:ok, response} ->
        case session_id_from_state(response) do
          session_id when is_binary(session_id) ->
            {:ok, %{rpc: rpc, session_id: session_id, session_state: Map.get(response, "data", %{})}}

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
  def run_turn(%{rpc: rpc, session_id: session_id, session_state: session_state}, prompt, issue, opts)
      when is_binary(prompt) and is_map(issue) do
    config = Config.settings!()
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_timeout_ms = Keyword.get(opts, :timeout_ms, timeout_ms(config, :turn))
    session_name = "#{issue.identifier}: #{issue.title}"
    proof = session_proof(rpc, session_id, session_state, session_name)

    context = %{
      config: config,
      on_event: fn event -> emit_event(on_message, event) end,
      on_message: on_message,
      proof: proof,
      rpc: rpc,
      timeouts: %{
        first_event: timeout_ms(config, :first_event),
        post_result: timeout_ms(config, :post_result),
        request: timeout_ms(config, :request),
        turn: turn_timeout_ms
      }
    }

    on_message.(
      proof_update(
        %{
          event: :session_started,
          payload: proof,
          session_id: session_id,
          timestamp: DateTime.utc_now(),
          backend: :pi
        },
        proof
      )
    )

    case Rpc.request(rpc, "set_session_name", %{"name" => session_name},
           timeout_ms: context.timeouts.request,
           on_event: context.on_event
         ) do
      {:ok, _} -> run_prompt_turn(context, prompt)
      {:error, reason} -> fail_turn(context, reason, :set_session_name_failed)
    end
  end

  defp run_prompt_turn(context, prompt) do
    failure_key = {__MODULE__, :turn_failure, make_ref()}

    on_event = fn event ->
      context.on_event.(event)

      case assistant_outcome(event) do
        :ignore -> :ok
        :succeeded -> Process.delete(failure_key)
        {:failed, reason} -> Process.put(failure_key, reason)
      end
    end

    try do
      context.rpc
      |> Rpc.request("prompt", %{"message" => prompt},
        timeout_ms: context.timeouts.turn,
        first_event_timeout_ms: context.timeouts.first_event,
        on_event: on_event,
        until: &settled_event?/1
      )
      |> handle_prompt_result(context, failure_key)
    after
      Process.delete(failure_key)
    end
  end

  defp handle_prompt_result({:ok, prompt_response}, context, failure_key) do
    case Process.get(failure_key) do
      nil -> complete_turn(context, prompt_response)
      reason -> fail_turn(context, reason, :provider_turn_failed)
    end
  end

  defp handle_prompt_result({:error, {:timeout, :first_event}}, context, _failure_key),
    do: abort_after_timeout(context, :first_event)

  defp handle_prompt_result({:error, :timeout}, context, _failure_key),
    do: abort_after_timeout(context, :absolute_turn_deadline)

  defp handle_prompt_result({:error, reason}, context, _failure_key),
    do: fail_turn(context, reason, :prompt_failed)

  defp complete_turn(context, prompt_response) do
    deadline_ms = monotonic_ms() + context.timeouts.post_result

    with {:ok, assistant_response} <-
           completion_request(context, "get_last_assistant_text", :assistant_text, deadline_ms),
         {:ok, stats_response} <-
           completion_request(context, "get_session_stats", :session_stats, deadline_ms) do
      turn = %{
        result: assistant_response,
        session_id: context.proof.session_id,
        turn_id: Map.get(prompt_response, "id"),
        stats: stats_response,
        stderr_path: context.rpc.stderr_path,
        backend: :pi,
        model: context.proof.model,
        thinking_level: context.proof.thinking_level,
        backend_process_pid: context.proof.backend_process_pid
      }

      emit_usage(context.on_message, stats_response)

      context.on_message.(
        proof_update(
          %{
            event: :turn_completed,
            payload: %{"assistant_text" => get_in(assistant_response, ["data", "text"])},
            session_id: context.proof.session_id,
            timestamp: DateTime.utc_now(),
            backend: :pi
          },
          context.proof
        )
      )

      {:ok, turn}
    else
      {:error, {:post_result_timeout, _phase} = reason} ->
        fail_turn(context, reason, :post_result_timeout)

      {:error, reason} ->
        fail_turn(context, reason, :completion_read_failed)
    end
  end

  defp completion_request(context, type, phase, deadline_ms) do
    case Rpc.request(context.rpc, type, %{},
           timeout_ms: context.timeouts.post_result,
           deadline_ms: deadline_ms,
           on_event: context.on_event
         ) do
      {:error, :timeout} -> {:error, {:post_result_timeout, phase}}
      result -> result
    end
  end

  defp abort_after_timeout(context, timeout_stage) do
    outcome =
      case Rpc.request(context.rpc, "abort", %{},
             timeout_ms: context.timeouts.request,
             on_event: context.on_event
           ) do
        {:ok, _response} -> :acknowledged
        {:error, reason} -> {:failed, reason}
      end

    reason =
      case outcome do
        :acknowledged -> {:turn_timeout, {timeout_stage, :abort_acknowledged}}
        {:failed, abort_reason} -> {:turn_timeout, {timeout_stage, {:abort_failed, abort_reason}}}
      end

    context.on_message.(
      proof_update(
        %{
          event: :turn_aborted,
          payload: %{"reason" => inspect(reason), "abort_outcome" => inspect(outcome)},
          session_id: context.proof.session_id,
          timestamp: DateTime.utc_now(),
          backend: :pi
        },
        context.proof
      )
    )

    {:error, reason}
  end

  defp fail_turn(context, reason, stage) do
    context.on_message.(
      proof_update(
        %{
          event: :turn_ended_with_error,
          payload: %{"stage" => Atom.to_string(stage), "reason" => inspect(reason)},
          session_id: context.proof.session_id,
          timestamp: DateTime.utc_now(),
          backend: :pi
        },
        context.proof
      )
    )

    {:error, reason}
  end

  defp session_proof(rpc, session_id, state, session_name) do
    %{
      session_id: session_id,
      session_file: Map.get(state, "sessionFile"),
      session_name: session_name,
      model: model_summary(Map.get(state, "model")),
      thinking_level: Map.get(state, "thinkingLevel"),
      backend_process_pid: rpc.os_pid,
      backend_command: rpc.command,
      stderr_path: rpc.stderr_path
    }
  end

  defp model_summary(model) when is_map(model), do: Map.take(model, ["id", "name", "api", "provider", "contextWindow", "maxTokens"])
  defp model_summary(_model), do: nil

  defp proof_update(update, proof) do
    Map.merge(update, Map.take(proof, [:backend_command, :backend_process_pid, :model, :session_file, :stderr_path, :thinking_level]))
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(%{rpc: rpc}), do: Rpc.close(rpc)

  defp prepare_pi_isolation(workspace) when is_binary(workspace) do
    session_dir = Path.join(workspace, ".symphony/pi-session")

    with :ok <- File.mkdir_p(session_dir), :ok <- File.chmod(session_dir, 0o700) do
      {:ok, %{session_dir: session_dir}}
    end
  rescue
    error in [ArgumentError, File.Error] -> {:error, error}
  end

  defp pi_isolation_environment(%{session_dir: session_dir}), do: [{~c"PI_CODING_AGENT_SESSION_DIR", String.to_charlist(session_dir)}]

  defp pi_secret_port_env do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&Regex.match?(@pi_secret_name_pattern, &1))
    |> Enum.map(&{String.to_charlist(&1), false})
  end

  defp pi_command(command, isolation) do
    isolation_flags = ["--session-dir", shell_escape(isolation.session_dir) | @pi_isolation_flags] |> Enum.join(" ")
    command <> " " <> isolation_flags
  end

  defp tracker_secret_port_env(%{tracker: %{secret_environment_names: names}}) when is_list(names) do
    names
    |> Enum.filter(&(is_binary(&1) and String.match?(&1, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)))
    |> Enum.map(&{String.to_charlist(&1), false})
  end

  defp tracker_secret_port_env(_config), do: []

  defp timeout_ms(config, :request),
    do: config.pi.request_timeout_ms || config.codex.read_timeout_ms

  defp timeout_ms(config, :first_event),
    do: config.pi.first_event_timeout_ms || timeout_ms(config, :request)

  defp timeout_ms(config, :turn),
    do: config.pi.turn_timeout_ms || config.codex.turn_timeout_ms

  defp timeout_ms(config, :post_result),
    do: config.pi.post_result_timeout_ms || timeout_ms(config, :request)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp session_id_from_state(%{"data" => %{"sessionId" => session_id}}) when is_binary(session_id), do: session_id
  defp session_id_from_state(_response), do: nil

  defp settled_event?(%{"type" => "agent_settled"}), do: true
  defp settled_event?(_event), do: false

  defp assistant_outcome(%{"type" => type, "message" => message}) when type in ["message_end", "turn_end"] and is_map(message), do: assistant_message_outcome(message)
  defp assistant_outcome(_event), do: :ignore

  defp assistant_message_outcome(%{"role" => "assistant", "stopReason" => stop_reason} = message) when stop_reason in ["error", "aborted"],
    do: {:failed, {:pi_assistant_failed, Map.take(message, ["stopReason", "errorMessage", "provider", "model"])}}

  defp assistant_message_outcome(%{"role" => "assistant"}), do: :succeeded
  defp assistant_message_outcome(_message), do: :ignore

  defp emit_event(on_message, event) when is_function(on_message, 1) and is_map(event) do
    update = %{event: event_name(event), payload: event, raw: Jason.encode!(event), timestamp: DateTime.utc_now(), backend: :pi}
    on_message.(update |> maybe_put_event_assistant_text(event) |> maybe_put_event_usage(event))
  end

  defp maybe_put_event_assistant_text(update, %{"type" => "message_end", "message" => message}) do
    case assistant_message_text(message) do
      text when is_binary(text) and text != "" -> Map.put(update, :assistant_text, text)
      _ -> update
    end
  end

  defp maybe_put_event_assistant_text(update, %{"type" => "message_update", "assistantMessageEvent" => %{"type" => "text_delta", "delta" => delta}}) when is_binary(delta),
    do: Map.put(update, :assistant_text_delta, delta)

  defp maybe_put_event_assistant_text(update, _event), do: update

  defp assistant_message_text(%{"role" => "assistant", "content" => content}) when is_binary(content), do: content

  defp assistant_message_text(%{"role" => "assistant", "content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp assistant_message_text(_message), do: nil

  defp maybe_put_event_usage(update, %{"usage" => usage}) when is_map(usage) do
    normalized = normalize_usage(usage)
    if map_size(normalized) > 0, do: Map.put(update, :usage, normalized), else: update
  end

  defp maybe_put_event_usage(update, _event), do: update

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
    |> copy_integer(tokens, "totalTokens", "total_tokens")
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
  defp event_name(%{"type" => "message_start"}), do: :message_started
  defp event_name(%{"type" => "message_update"}), do: :message_update
  defp event_name(%{"type" => "message_end"}), do: :message_ended
  defp event_name(%{"type" => "tool_execution_start"}), do: :tool_execution_started
  defp event_name(%{"type" => "tool_execution_update"}), do: :tool_execution_updated
  defp event_name(%{"type" => "tool_execution_end"}), do: :tool_execution_ended
  defp event_name(%{"type" => "extension_ui_request"}), do: :extension_ui_request
  defp event_name(%{"type" => type}) when is_binary(type), do: :notification
  defp event_name(_event), do: :notification

  defp shell_escape(value) when is_binary(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  defp default_on_message(_message), do: :ok
end
