defmodule SymphonyElixir.Deepseek.Backend do
  @moduledoc """
  Removable, local-only DeepSeek Harness (`dsh`) backend. The operator's wrapper or environment
  supplies `DEEPSEEK_API_KEY`; Symphony passes that one variable through and never reads, logs or
  stores its value. Harness state lives in the configured `deepseek.dsh_home`, never in `~/.dsh`.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.{Config, Deepseek.Stream, Workflow}

  @summary_characters 2_000
  @default_command "dsh"

  @impl true
  def validate_config(%{worker: %{ssh_hosts: hosts}} = settings) do
    if Enum.any?(hosts, &(is_binary(&1) and String.trim(&1) != "")) do
      {:error, {:unsupported_backend_worker_hosts, :deepseek}}
    else
      validate_local_config(settings)
    end
  end

  def validate_config(settings), do: validate_local_config(settings)

  @impl true
  def start_session(workspace, opts \\ []) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) -> {:error, {:unsupported_backend_worker_host, :deepseek, host}}
      _ -> start_local(workspace)
    end
  end

  defp start_local(workspace) do
    with {:ok, workflow} <- Workflow.current(),
         {:ok, config} <- local_config(Map.get(workflow.config, "deepseek", %{})),
         {:ok, executable} <- resolve_executable(config.command),
         true <- File.dir?(workspace) or {:error, {:workspace_not_found, workspace}} do
      Stream.start(Path.expand(workspace), executable, config.dsh_home)
    end
  end

  @impl true
  def run_turn(session, prompt, _issue, opts) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    timeout_ms = Keyword.get(opts, :timeout_ms, Config.settings!().codex.turn_timeout_ms)
    stall_timeout_ms = Keyword.get(opts, :stall_timeout_ms, Config.agent_stall_timeout_ms())
    monitor = Process.monitor(session)

    try do
      case Stream.turn(session, prompt, timeout_ms, stall_timeout_ms) do
        {:ok, ref} -> await_turn(session, monitor, ref, on_message)
        {:error, reason} -> fail_turn(on_message, reason)
      end
    catch
      :exit, reason -> fail_turn(on_message, {:deepseek_session_exit, reason})
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_turn(session, monitor, ref, on_message) do
    receive do
      {:deepseek_stream, ^ref, {:event, event}} ->
        emit_event(on_message, event)
        await_turn(session, monitor, ref, on_message)

      {:deepseek_stream, ^ref, {:usage, usage}} ->
        emit(on_message, :usage, usage, %{usage: usage})
        await_turn(session, monitor, ref, on_message)

      {:deepseek_stream, ^ref, {:done, {:ok, %{session_id: session_id, text: text}}}} ->
        # The orchestrator keeps this payload as the issue's last message; the final text is the verdict.
        payload = %{"result" => String.slice(text, 0, @summary_characters), "session_id" => session_id}
        emit(on_message, :turn_completed, payload, %{session_id: session_id})
        {:ok, %{session_id: session_id, result: payload, backend: :deepseek}}

      {:deepseek_stream, ^ref, {:done, {:error, reason}}} ->
        fail_turn(on_message, reason)

      {:DOWN, ^monitor, :process, ^session, reason} ->
        fail_turn(on_message, {:deepseek_session_exit, reason})
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

  defp raw_config(%{deepseek: config}), do: {:ok, config}

  defp raw_config(_settings) do
    with {:ok, workflow} <- Workflow.load() do
      {:ok, Map.get(workflow.config, "deepseek", %{})}
    end
  end

  defp local_config(raw) when is_map(raw) do
    command = Map.get(raw, "command", Map.get(raw, :command, @default_command))
    dsh_home = Map.get(raw, "dsh_home", Map.get(raw, :dsh_home))
    operator_home = System.get_env("HOME") || System.user_home!()

    cond do
      not is_binary(command) or String.trim(command) == "" ->
        {:error, {:invalid_deepseek_config, "deepseek.command must be a nonblank executable name or path"}}

      not is_binary(dsh_home) or String.trim(dsh_home) == "" ->
        {:error, {:invalid_deepseek_config, "deepseek.dsh_home must be a nonblank directory path"}}

      reserved_home?(dsh_home, operator_home) ->
        {:error, {:invalid_deepseek_config, "deepseek.dsh_home must not be the operator ~/.dsh directory"}}

      true ->
        {:ok, %{command: command, dsh_home: Path.expand(dsh_home)}}
    end
  end

  defp local_config(_raw), do: {:error, {:invalid_deepseek_config, "deepseek must be a map"}}

  defp reserved_home?(dsh_home, operator_home) do
    expanded = Path.expand(dsh_home)
    reserved = Path.join(Path.expand(operator_home), ".dsh")
    expanded == reserved or String.starts_with?(expanded, reserved <> "/")
  end

  defp resolve_executable(command) do
    case System.find_executable(command) do
      nil -> {:error, {:backend_executable_not_found, :deepseek, command}}
      executable -> {:ok, executable}
    end
  end

  defp fail_turn(on_message, reason) do
    emit(on_message, :turn_ended_with_error, %{"reason" => inspect(reason)}, %{})
    {:error, reason}
  end

  defp emit_event(on_message, %{"type" => "session"} = event),
    do: emit(on_message, :session_started, event, %{session_id: event["sessionId"]})

  defp emit_event(on_message, %{"type" => "text", "text" => text} = event) when is_binary(text),
    do: emit(on_message, :message_update, event, %{assistant_text_delta: text})

  # The final text is delivered as :turn_completed once the harness has exited cleanly.
  defp emit_event(_on_message, %{"type" => "final"}), do: :ok

  defp emit_event(on_message, event), do: emit(on_message, :notification, event, %{})

  defp emit(on_message, name, payload, fields) do
    on_message.(Map.merge(%{event: name, timestamp: DateTime.utc_now(), backend: :deepseek, payload: payload}, fields))
  end
end
