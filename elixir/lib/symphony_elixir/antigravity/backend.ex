defmodule SymphonyElixir.Antigravity.Backend do
  @moduledoc """
  Local native AntiGravity backend behind the shared execution contract.

  The adapter owns only native NDJSON translation and a fail-closed process boundary. Scheduling,
  retries, workspaces, tracker lifecycle, and reconciliation remain owned by Symphony.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.{Antigravity.Transport, Config}

  @impl true
  def validate_config(%{worker: %{ssh_hosts: hosts}, antigravity: antigravity}) when is_list(hosts) do
    if Enum.any?(hosts, &(is_binary(&1) and String.trim(&1) != "")) do
      {:error, {:unsupported_backend_worker_hosts, :antigravity}}
    else
      validate_local_config(antigravity)
    end
  end

  def validate_config(%{antigravity: antigravity}), do: validate_local_config(antigravity)
  def validate_config(_settings), do: {:error, :missing_antigravity_config}

  @impl true
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) ->
        {:error, {:unsupported_backend_worker_host, :antigravity, host}}

      _ ->
        start_local_session(workspace, opts)
    end
  end

  @impl true
  def run_turn(session, prompt, %{} = _issue, opts)
      when is_binary(prompt) and is_list(opts) do
    config = Config.settings!()
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    native_handler = fn event ->
      event
      |> native_update(session)
      |> on_message.()
    end

    transport_opts = [
      on_event: native_handler,
      first_event_timeout_ms: config.antigravity.first_event_timeout_ms,
      turn_timeout_ms: Keyword.get(opts, :timeout_ms, config.antigravity.turn_timeout_ms),
      cancel_grace_ms: config.antigravity.cancel_grace_ms
    ]

    case Transport.run_turn(session.transport, prompt, transport_opts) do
      {:ok, result} ->
        handle_result(session, result, on_message)

      {:error, {:antigravity_turn_timeout, stage, terminal} = reason} ->
        abort_turn(session, stage, terminal, reason, on_message)

      {:error, reason} ->
        fail_turn(session, :native_protocol, reason, on_message)
    end
  end

  @impl true
  def stop_session(%{transport: transport}) do
    case Transport.close(transport) do
      :ok -> :ok
      {:error, reason} -> raise RuntimeError, "AntiGravity process cleanup failed: #{inspect(reason)}"
    end
  end

  defp start_local_session(workspace, opts) do
    config = Config.settings!()

    transport_opts =
      opts
      |> Keyword.take([:launcher])
      |> Keyword.put(:secret_environment_names, config.tracker.secret_environment_names)

    with :ok <- validate_local_config(config.antigravity),
         {:ok, transport} <-
           Transport.start(
             workspace,
             config.antigravity.executable,
             config.antigravity.profile_root,
             config.antigravity.turn_timeout_ms,
             transport_opts
           ) do
      {:ok,
       %{
         transport: transport,
         workspace: transport.workspace,
         backend_process_pid: transport.process_group_id,
         stderr_path: transport.stderr_path
       }}
    end
  end

  defp handle_result(session, %{denied_actions: denied_actions} = result, on_message)
       when is_list(denied_actions) and denied_actions != [] do
    payload = %{
      "status" => result.status,
      "denied_actions_count" => length(denied_actions),
      "reason" => "native permission or input is required"
    }

    on_message.(update(session, :turn_input_required, result.session_id, payload))
    {:error, {:antigravity_input_required, %{status: result.status, denied_actions_count: length(denied_actions)}}}
  end

  defp handle_result(session, %{status: "SUCCESS"} = result, on_message) do
    emit_usage(session, result, on_message)

    on_message.(
      update(session, :turn_completed, result.session_id, %{
        "status" => result.status,
        "response" => result.response,
        "num_turns" => result.num_turns
      })
    )

    {:ok,
     %{
       session_id: result.session_id,
       result: result.response,
       status: result.status,
       usage: result.usage,
       num_turns: result.num_turns,
       duration_seconds: result.duration_seconds,
       stderr_path: session.stderr_path,
       backend_process_pid: session.backend_process_pid,
       backend: :antigravity
     }}
  end

  defp handle_result(session, %{status: "WAITING"} = result, on_message) do
    on_message.(
      update(session, :turn_input_required, result.session_id, %{
        "status" => result.status,
        "reason" => "native worker is waiting for input"
      })
    )

    {:error, {:antigravity_input_required, %{status: result.status}}}
  end

  defp handle_result(session, %{status: status} = result, on_message)
       when status in ["CANCELED", "INTERRUPTED"] do
    on_message.(update(session, :turn_aborted, result.session_id, %{"status" => status}))
    {:error, {:antigravity_turn_aborted, status}}
  end

  defp handle_result(session, result, on_message) do
    fail_turn(
      session,
      :native_terminal_status,
      {:antigravity_turn_failed, %{status: result.status, error_present: is_binary(result.error) and result.error != ""}},
      on_message,
      result.session_id
    )
  end

  defp abort_turn(session, stage, terminal, reason, on_message) do
    on_message.(
      update(session, :turn_aborted, nil, %{
        "stage" => Atom.to_string(stage),
        "terminal" => inspect(terminal),
        "locally_initiated" => true
      })
    )

    {:error, reason}
  end

  defp fail_turn(session, stage, reason, on_message, session_id \\ nil) do
    on_message.(
      update(session, :turn_ended_with_error, session_id, %{
        "stage" => Atom.to_string(stage),
        "reason" => reason_code(reason)
      })
    )

    {:error, reason}
  end

  defp emit_usage(session, result, on_message) do
    on_message.(
      session
      |> update(:usage, result.session_id, %{"usage" => result.usage})
      |> Map.put(:usage, result.usage)
    )
  end

  defp native_update(%{"event" => "init", "conversation_id" => session_id, "init" => init}, session) do
    session
    |> update(:session_started, session_id, init)
    |> Map.put(:permission_mode, Map.get(init, "permission_mode"))
    |> Map.put(:workspace, Map.get(init, "cwd"))
  end

  defp native_update(%{"event" => "step_update", "step_update" => step} = event, session) do
    session
    |> update(:step_update, Map.get(step, "conversation_id"), event)
    |> maybe_put(:assistant_text_delta, Map.get(step, "text_delta"))
  end

  defp native_update(%{"event" => "result", "result" => result} = event, session) do
    session
    |> update(:native_result, Map.get(result, "conversation_id"), event)
    |> Map.put(:status, Map.get(result, "status"))
  end

  defp update(session, event, session_id, payload) do
    %{
      event: event,
      payload: payload,
      raw: Jason.encode!(payload),
      session_id: session_id,
      timestamp: DateTime.utc_now(),
      backend: :antigravity,
      backend_process_pid: session.backend_process_pid,
      stderr_path: session.stderr_path
    }
  end

  defp maybe_put(map, _key, value) when not is_binary(value) or value == "", do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp validate_local_config(config) do
    cond do
      not is_binary(config.executable) or String.trim(config.executable) == "" ->
        {:error, :missing_antigravity_executable}

      Path.type(config.executable) != :absolute ->
        {:error, {:antigravity_executable_must_be_absolute, config.executable}}

      not is_binary(config.profile_root) or String.trim(config.profile_root) == "" ->
        {:error, :missing_antigravity_profile_root}

      Path.type(config.profile_root) != :absolute ->
        {:error, {:antigravity_profile_root_must_be_absolute, config.profile_root}}

      true ->
        :ok
    end
  end

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({reason, _first, _second}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({reason, _first, _second, _third}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(_reason), do: "antigravity_protocol_error"

  defp default_on_message(_message), do: :ok
end
