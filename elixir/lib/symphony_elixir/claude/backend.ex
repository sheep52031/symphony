defmodule SymphonyElixir.Claude.Backend do
  @moduledoc """
  Removable, local-only Claude Code subscription backend. Authentication and the default model
  belong to the operator's official `claude` CLI; Symphony never loads its credential files.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.{Claude.FinalText, Claude.Stream, Config, Workflow}

  @impl true
  def validate_config(%{worker: %{ssh_hosts: hosts}} = settings) do
    if Enum.any?(hosts, &(is_binary(&1) and String.trim(&1) != "")) do
      {:error, {:unsupported_backend_worker_hosts, :claude}}
    else
      validate_local_config(settings)
    end
  end

  def validate_config(settings), do: validate_local_config(settings)

  @impl true
  def start_session(workspace, opts \\ []) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) -> {:error, {:unsupported_backend_worker_host, :claude, host}}
      _ -> start_local(workspace)
    end
  end

  defp start_local(workspace) do
    with {:ok, workflow} <- Workflow.current(),
         {:ok, config} <- local_config(Map.get(workflow.config, "claude", %{})),
         {:ok, executable} <- resolve_executable(config.command),
         true <- File.dir?(workspace) or {:error, {:workspace_not_found, workspace}} do
      Stream.start(Path.expand(workspace), executable, config.config_dir)
    end
  end

  @impl true
  def run_turn(session, prompt, _issue, opts) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    timeout_ms = Keyword.get(opts, :timeout_ms, Config.settings!().codex.turn_timeout_ms)
    monitor = Process.monitor(session)

    try do
      case Stream.turn(session, prompt, timeout_ms) do
        {:ok, ref} -> await_turn(session, monitor, ref, on_message)
        {:error, reason} -> fail_turn(on_message, reason)
      end
    catch
      :exit, reason -> fail_turn(on_message, {:claude_session_exit, reason})
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_turn(session, monitor, ref, on_message) do
    receive do
      {:claude_stream, ^ref, {:event, event}} ->
        emit_event(on_message, event)
        await_turn(session, monitor, ref, on_message)

      {:claude_stream, ^ref, {:done, {:ok, result}}} ->
        # The orchestrator keeps this payload as the issue's last message. The final assistant text
        # is the verdict; the full result event already reached the caller as an earlier update.
        emit(on_message, :turn_completed, FinalText.summary(result) || result, %{session_id: result["session_id"]})
        {:ok, %{session_id: result["session_id"], result: result, backend: :claude}}

      {:claude_stream, ^ref, {:done, {:error, reason}}} ->
        fail_turn(on_message, reason)

      {:DOWN, ^monitor, :process, ^session, reason} ->
        fail_turn(on_message, {:claude_session_exit, reason})
    end
  end

  @impl true
  def stop_session(session), do: Stream.close(session)

  defp validate_local_config(settings) do
    # WorkflowStore calls validation while loading: never call Workflow.current/0 here.
    with {:ok, raw} <- raw_config(settings),
         {:ok, config} <- local_config(raw),
         {:ok, _executable} <- resolve_executable(config.command) do
      :ok
    end
  end

  defp raw_config(%{claude: config}), do: {:ok, config}

  defp raw_config(_settings) do
    with {:ok, workflow} <- Workflow.load() do
      {:ok, Map.get(workflow.config, "claude", %{})}
    end
  end

  defp local_config(raw) when is_map(raw) do
    command = Map.get(raw, "command", Map.get(raw, :command, "claude"))
    operator_home = System.get_env("HOME") || System.user_home!()
    default_dir = System.get_env("CLAUDE_CONFIG_DIR") || Path.join(operator_home, ".claude")
    config_dir = Map.get(raw, "config_dir", Map.get(raw, :config_dir, default_dir))

    cond do
      not is_binary(command) or String.trim(command) == "" ->
        {:error, {:invalid_claude_config, "claude.command must be a nonblank executable name or path"}}

      not is_binary(config_dir) or String.trim(config_dir) == "" ->
        {:error, {:invalid_claude_config, "claude.config_dir must be a nonblank directory path"}}

      true ->
        {:ok, %{command: command, config_dir: Path.expand(config_dir)}}
    end
  end

  defp local_config(_raw), do: {:error, {:invalid_claude_config, "claude must be a map"}}

  defp resolve_executable(command) do
    case System.find_executable(command) do
      nil -> {:error, {:backend_executable_not_found, :claude, command}}
      executable -> {:ok, executable}
    end
  end

  defp fail_turn(on_message, reason) do
    emit(on_message, :turn_ended_with_error, %{"reason" => inspect(reason)}, %{})
    {:error, reason}
  end

  defp emit_event(on_message, %{"type" => "system", "subtype" => "init"} = event),
    do: emit(on_message, :session_started, event, %{session_id: event["session_id"], model: event["model"]})

  defp emit_event(on_message, %{"type" => "stream_event", "event" => %{"delta" => %{"type" => "text_delta", "text" => text}}} = event),
    do: emit(on_message, :message_update, event, %{assistant_text_delta: text})

  defp emit_event(on_message, %{"type" => "assistant", "message" => %{"content" => content}} = event) when is_list(content) do
    text =
      Enum.map_join(content, "", fn
        %{"type" => "text", "text" => text} -> text
        _ -> ""
      end)

    emit(on_message, :message_ended, event, %{assistant_text: text})
  end

  defp emit_event(on_message, %{"type" => "result", "usage" => usage} = event) when is_map(usage),
    do: emit(on_message, :usage, event, %{usage: usage})

  defp emit_event(on_message, event), do: emit(on_message, :notification, event, %{})

  defp emit(on_message, name, payload, fields) do
    on_message.(Map.merge(%{event: name, timestamp: DateTime.utc_now(), backend: :claude, payload: payload}, fields))
  end
end
