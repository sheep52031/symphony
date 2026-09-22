defmodule SymphonyElixir.Antigravity.Backend do
  @moduledoc """
  Local native AntiGravity backend behind the shared execution contract.

  The adapter owns only native NDJSON translation and a fail-closed process boundary. Scheduling,
  retries, workspaces, tracker lifecycle, and reconciliation remain owned by Symphony.
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger
  alias SymphonyElixir.{Antigravity.Launcher, Antigravity.Transport, Config, TerminalFailure}

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
  @spec validate_binding(map(), SymphonyElixir.Config.Schema.t()) :: :ok | {:error, term()}
  def validate_binding(options, _settings) when is_map(options) do
    normalized = Map.new(options, fn {key, value} -> {to_string(key), value} end)

    cond do
      Map.keys(normalized) != ["profile_root"] ->
        {:error, :invalid_antigravity_launch_binding_options}

      not is_binary(normalized["profile_root"]) or String.trim(normalized["profile_root"]) == "" ->
        {:error, :missing_antigravity_binding_profile_root}

      Path.type(normalized["profile_root"]) != :absolute ->
        {:error, {:antigravity_profile_root_must_be_absolute, normalized["profile_root"]}}

      true ->
        :ok
    end
  end

  @impl true
  @spec preflight_binding(map(), Path.t(), SymphonyElixir.Config.Schema.t()) ::
          :ok | {:error, term()}
  def preflight_binding(options, workspace, settings)
      when is_map(options) and is_binary(workspace) do
    profile_root = Map.get(options, :profile_root) || Map.get(options, "profile_root")

    case Launcher.build(
           workspace,
           settings.antigravity.executable,
           profile_root,
           settings.antigravity.turn_timeout_ms,
           []
         ) do
      {:ok, _launch} -> :ok
      {:error, _reason} = error -> error
    end
  end

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
  def run_turn(session, prompt, %{} = issue, opts)
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
        handle_result(session, result, issue, opts, on_message)

      {:error, {:antigravity_terminal_error, native_error}} ->
        {reason, details} = classify_native_error(Map.get(native_error, "error"))

        terminal_fail(
          session,
          issue,
          opts,
          reason,
          Map.merge(details, %{session_id: Map.get(native_error, "conversation_id")}),
          on_message
        )

      {:error, {:antigravity_turn_timeout, stage, terminal}} ->
        terminal_fail(
          session,
          issue,
          opts,
          :worker_stalled,
          timeout_details(stage, terminal),
          on_message
        )

      {:error, {:antigravity_process_exit, _status}} ->
        terminal_fail(
          session,
          issue,
          opts,
          :worker_crashed,
          %{liveness: :dead_or_unreachable},
          on_message
        )

      {:error, reason} ->
        terminal_fail(
          session,
          issue,
          opts,
          :provider_protocol_error,
          %{provider_code: protocol_code(reason)},
          on_message
        )
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

    binding = Keyword.get(opts, :binding)
    profile_root = binding_profile_root(binding, config.antigravity.profile_root)

    with :ok <- validate_local_config(%{config.antigravity | profile_root: profile_root}),
         {:ok, transport} <-
           Transport.start(
             workspace,
             config.antigravity.executable,
             profile_root,
             config.antigravity.turn_timeout_ms,
             transport_opts
           ) do
      {:ok,
       %{
         transport: transport,
         workspace: transport.workspace,
         backend_process_pid: transport.process_group_id,
         stderr_path: transport.stderr_path,
         binding_id: binding_id(binding)
       }}
    end
  end

  defp handle_result(session, %{denied_actions: denied_actions} = result, _issue, _opts, on_message)
       when is_list(denied_actions) and denied_actions != [] do
    payload = %{
      "status" => result.status,
      "denied_actions_count" => length(denied_actions),
      "reason" => "native permission or input is required"
    }

    on_message.(update(session, :turn_input_required, result.session_id, payload))
    {:error, {:antigravity_input_required, %{status: result.status, denied_actions_count: length(denied_actions)}}}
  end

  defp handle_result(session, %{status: "SUCCESS"} = result, _issue, _opts, on_message) do
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

  defp handle_result(session, %{status: "WAITING"} = result, _issue, _opts, on_message) do
    on_message.(
      update(session, :turn_input_required, result.session_id, %{
        "status" => result.status,
        "reason" => "native worker is waiting for input"
      })
    )

    {:error, {:antigravity_input_required, %{status: result.status}}}
  end

  defp handle_result(session, %{status: status} = result, _issue, _opts, on_message)
       when status in ["CANCELED", "INTERRUPTED"] do
    on_message.(update(session, :turn_aborted, result.session_id, %{"status" => status}))
    {:error, {:antigravity_turn_aborted, status}}
  end

  defp handle_result(session, result, issue, opts, on_message) do
    {reason, details} =
      case result.status do
        "ERROR" -> classify_native_error(result.error)
        "INVALID" -> {:provider_protocol_error, %{provider_code: "INVALID_RESULT"}}
        _ -> {:unknown_terminal_failure, %{}}
      end

    terminal_fail(
      session,
      issue,
      opts,
      reason,
      Map.put(details, :session_id, result.session_id),
      on_message
    )
  end

  defp terminal_fail(session, issue, opts, reason, details, on_message) do
    context = %{
      backend: :antigravity,
      issue_id: Map.get(issue, :id) || Map.get(issue, "id"),
      issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      attempt: Keyword.get(opts, :attempt),
      session_id: Map.get(details, :session_id) || Transport.session_id(session.transport),
      workspace: session.workspace,
      binding_id: session.binding_id
    }

    evidence = TerminalFailure.build(reason, Map.delete(details, :session_id), context)

    case TerminalFailure.persist(session.workspace, evidence) do
      {:ok, _path} ->
        on_message.(
          session
          |> update(:terminal_failure, evidence.session_id, evidence)
          |> Map.put(:terminal_failure, evidence)
          |> Map.put(:terminal_failure_persisted, true)
        )

        {:error, {:backend_terminal_failure, evidence}}

      {:error, persist_reason} ->
        storage_failure = %{
          event_id: evidence.event_id,
          code: stable_storage_error(persist_reason)
        }

        fault_persisted =
          case TerminalFailure.persist_storage_fault(
                 session.workspace,
                 evidence,
                 storage_failure.code
               ) do
            {:ok, _path} -> true
            {:error, _reason} -> false
          end

        Logger.error("Terminal evidence storage unavailable event_id=#{evidence.event_id} reason=#{storage_failure.code} fault_persisted=#{fault_persisted}; stopping lifecycle dispatch fail-closed")

        on_message.(
          session
          |> update(:terminal_storage_failure, evidence.session_id, storage_failure)
          |> Map.put(:terminal_storage_failure, storage_failure)
        )

        {:error, {:backend_terminal_storage_failure, evidence.event_id}}
    end
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

  defp classify_native_error(message) do
    raw_message = if is_binary(message), do: message, else: "native provider failure"
    normalized = String.downcase(raw_message)
    details = native_error_details(raw_message)

    {classify_native_error_reason(normalized, details), details}
  end

  defp classify_native_error_reason(normalized, details) do
    cond do
      quota_error?(normalized, details) -> :provider_quota_exhausted
      authentication_error?(normalized, details) -> :provider_auth_failed
      permission_error?(normalized, details) -> :permission_denied
      network_error?(normalized) -> :provider_network_unreachable
      true -> :unknown_terminal_failure
    end
  end

  defp quota_error?(normalized, details) do
    String.contains?(normalized, "resource_exhausted") or
      (details[:http_status] == 429 and String.contains?(normalized, "quota"))
  end

  defp authentication_error?(normalized, details) do
    String.contains?(normalized, [
      "unauthenticated",
      "authentication failed",
      "invalid credential",
      "login required",
      "oauth failed"
    ]) or details[:http_status] == 401
  end

  defp permission_error?(normalized, details) do
    String.contains?(normalized, ["permission_denied", "permission denied", "forbidden"]) or
      details[:http_status] == 403
  end

  defp network_error?(normalized) do
    String.contains?(normalized, [
      "network unreachable",
      "name or service not known",
      "temporary failure in name resolution",
      "connection refused",
      "connection reset",
      "dns resolution failed"
    ])
  end

  defp native_error_details(message) do
    %{
      provider_code: provider_code(message),
      http_status: http_status(message),
      reset_hint: reset_hint(message),
      liveness: :dead_or_unreachable
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp provider_code(message) do
    case Regex.run(~r/\b(RESOURCE_EXHAUSTED|UNAUTHENTICATED|PERMISSION_DENIED|UNAVAILABLE)\b/i, message, capture: :all_but_first) do
      [code] -> String.upcase(code)
      _ -> nil
    end
  end

  defp http_status(message) do
    case Regex.run(~r/(?:\bcode\b|\bstatus\b|\bhttp\b)\s*[:=(]?\s*(\d{3})\b/i, message, capture: :all_but_first) do
      [status] ->
        case Integer.parse(status) do
          {value, ""} when value in 100..599 -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp reset_hint(message) do
    case Regex.run(
           ~r/\bresets?\s+in\s+([0-9]+(?:\s*[smhd])(?:\s*[0-9]+\s*[smhd]){0,3})\b/i,
           message,
           capture: :all_but_first
         ) do
      [hint] -> String.replace(hint, ~r/\s+/, "")
      _ -> nil
    end
  end

  defp timeout_details(_stage, terminal) do
    progress_seen = timeout_progress_seen?(terminal)

    %{
      liveness:
        if(progress_seen,
          do: :alive_but_thinking,
          else: :dead_or_unreachable
        )
    }
  end

  defp timeout_progress_seen?(%{progress_seen: value}) when is_boolean(value), do: value
  defp timeout_progress_seen?({:cleanup_failed, _reason, terminal}), do: timeout_progress_seen?(terminal)
  defp timeout_progress_seen?(_terminal), do: false

  defp protocol_code(reason) when is_atom(reason), do: "PROTOCOL_" <> (reason |> Atom.to_string() |> String.upcase())
  defp protocol_code(_reason), do: "PROTOCOL_ERROR"

  defp stable_storage_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp stable_storage_error({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp stable_storage_error({reason, _first, _second}) when is_atom(reason), do: Atom.to_string(reason)
  defp stable_storage_error(_reason), do: "terminal_storage_error"

  defp binding_profile_root(%{options: options}, default) when is_map(options) do
    Map.get(options, :profile_root) || Map.get(options, "profile_root") || default
  end

  defp binding_profile_root(_binding, default), do: default

  defp binding_id(%{binding_id: binding_id}) when is_binary(binding_id), do: binding_id
  defp binding_id(_binding), do: nil

  defp default_on_message(_message), do: :ok
end
