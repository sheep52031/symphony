defmodule SymphonyElixir.MiniMax.Backend do
  @moduledoc """
  Removable, local-only MiniMax Code (`mcode`) backend. Authentication and the default model
  belong to the operator's own `mcode` login; Symphony never loads its credential files.

  The adapter drives the official CLI in headless `exec` mode with `--output-format stream-json`
  and maps the native stream events onto the shared Symphony update and result shapes. Removing
  this module and its registry entry leaves the remaining backends untouched.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.{Config, MiniMax.Stream, Workflow}

  @summary_characters 2_000
  @default_command "mcode"
  @default_max_steps 60

  @impl true
  def validate_config(%{worker: %{ssh_hosts: hosts}} = settings) do
    if Enum.any?(hosts, &(is_binary(&1) and String.trim(&1) != "")) do
      {:error, {:unsupported_backend_worker_hosts, :minimax}}
    else
      validate_local_config(settings)
    end
  end

  def validate_config(settings), do: validate_local_config(settings)

  @impl true
  def start_session(workspace, opts \\ []) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) -> {:error, {:unsupported_backend_worker_host, :minimax, host}}
      _ -> start_local(workspace)
    end
  end

  defp start_local(workspace) do
    with {:ok, workflow} <- Workflow.current(),
         {:ok, config} <- local_config(Map.get(workflow.config, "minimax", %{})),
         {:ok, executable} <- resolve_executable(config.command),
         true <- File.dir?(workspace) or {:error, {:workspace_not_found, workspace}} do
      Stream.start(Path.expand(workspace), executable, config.data_dir,
        max_steps: config.max_steps,
        model: config.model
      )
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
      :exit, reason -> fail_turn(on_message, {:minimax_session_exit, reason})
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_turn(session, monitor, ref, on_message) do
    receive do
      {:minimax_stream, ^ref, {:event, event}} ->
        emit_event(on_message, event)
        await_turn(session, monitor, ref, on_message)

      {:minimax_stream, ^ref, {:done, {:ok, result}}} ->
        # The orchestrator keeps this payload as the issue's last message; the final text is the verdict.
        payload = %{"result" => summary(result["output"]), "session_id" => result["session_id"]}
        emit(on_message, :turn_completed, payload, %{session_id: result["session_id"]})
        {:ok, %{session_id: result["session_id"], result: payload, backend: :minimax}}

      {:minimax_stream, ^ref, {:done, {:error, reason}}} ->
        fail_turn(on_message, reason)

      {:DOWN, ^monitor, :process, ^session, reason} ->
        fail_turn(on_message, {:minimax_session_exit, reason})
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

  defp raw_config(%{minimax: config}), do: {:ok, config}

  defp raw_config(_settings) do
    with {:ok, workflow} <- Workflow.load() do
      {:ok, Map.get(workflow.config, "minimax", %{})}
    end
  end

  defp local_config(raw) when is_map(raw) do
    command = Map.get(raw, "command", Map.get(raw, :command, @default_command))
    data_dir = Map.get(raw, "data_dir", Map.get(raw, :data_dir))
    max_steps = Map.get(raw, "max_steps", Map.get(raw, :max_steps, @default_max_steps))
    model = Map.get(raw, "model", Map.get(raw, :model))

    with :ok <- validate_command(command),
         :ok <- validate_data_dir(data_dir),
         :ok <- validate_max_steps(max_steps),
         :ok <- validate_model(model) do
      {:ok,
       %{
         command: command,
         data_dir: Path.expand(data_dir || default_data_dir()),
         max_steps: max_steps,
         model: model
       }}
    end
  end

  defp local_config(_raw), do: {:error, {:invalid_minimax_config, "minimax must be a map"}}

  defp validate_command(command) when is_binary(command),
    do: validate_nonblank(command, "minimax.command must be a nonblank executable name or path")

  defp validate_command(_command),
    do: {:error, {:invalid_minimax_config, "minimax.command must be a nonblank executable name or path"}}

  defp validate_data_dir(nil), do: :ok

  defp validate_data_dir(data_dir) when is_binary(data_dir),
    do: validate_nonblank(data_dir, "minimax.data_dir must be a nonblank directory path")

  defp validate_data_dir(_data_dir),
    do: {:error, {:invalid_minimax_config, "minimax.data_dir must be a nonblank directory path"}}

  defp validate_max_steps(max_steps) when is_integer(max_steps) and max_steps > 0, do: :ok

  defp validate_max_steps(_max_steps),
    do: {:error, {:invalid_minimax_config, "minimax.max_steps must be a positive integer"}}

  defp validate_model(nil), do: :ok

  defp validate_model(model) when is_binary(model),
    do: validate_nonblank(model, "minimax.model must be a nonblank provider/model id")

  defp validate_model(_model),
    do: {:error, {:invalid_minimax_config, "minimax.model must be a nonblank provider/model id"}}

  defp validate_nonblank(value, message) do
    if String.trim(value) == "" do
      {:error, {:invalid_minimax_config, message}}
    else
      :ok
    end
  end

  defp default_data_dir do
    operator_home = System.get_env("HOME") || System.user_home!()
    Path.join(operator_home, ".minimax")
  end

  defp resolve_executable(command) do
    case System.find_executable(command) do
      nil -> {:error, {:backend_executable_not_found, :minimax, command}}
      executable -> {:ok, executable}
    end
  end

  defp summary(text) when is_binary(text), do: String.slice(text, 0, @summary_characters)
  defp summary(_text), do: ""

  defp fail_turn(on_message, reason) do
    emit(on_message, :turn_ended_with_error, %{"reason" => inspect(reason)}, %{})
    {:error, reason}
  end

  defp emit_event(on_message, %{"type" => "session.started"} = event),
    do: emit(on_message, :session_started, event, %{session_id: event["sessionId"]})

  defp emit_event(on_message, %{"type" => "session.resumed"} = event),
    do: emit(on_message, :session_started, event, %{session_id: event["sessionId"]})

  defp emit_event(
         on_message,
         %{"type" => "item.started", "item" => %{"type" => "agent_message", "contentDelta" => text}} = event
       )
       when is_binary(text),
       do: emit(on_message, :message_update, event, %{assistant_text_delta: text})

  defp emit_event(
         on_message,
         %{"type" => "item.updated", "item" => %{"type" => "agent_message", "contentDelta" => text}} = event
       )
       when is_binary(text),
       do: emit(on_message, :message_update, event, %{assistant_text_delta: text})

  defp emit_event(
         on_message,
         %{"type" => "item.completed", "item" => %{"type" => "agent_message", "content" => text}} = event
       )
       when is_binary(text),
       do: emit(on_message, :message_ended, event, %{assistant_text: text})

  defp emit_event(on_message, %{"type" => "turn.completed", "usage" => usage} = event) when is_map(usage),
    do: emit(on_message, :usage, event, %{usage: usage})

  # The authoritative result is delivered with the turn completion.
  defp emit_event(_on_message, %{"type" => "exec.result"}), do: :ok
  defp emit_event(_on_message, %{"type" => "exec.completed"}), do: :ok

  defp emit_event(on_message, event), do: emit(on_message, :notification, event, %{})

  defp emit(on_message, name, payload, fields) do
    on_message.(Map.merge(%{event: name, timestamp: DateTime.utc_now(), backend: :minimax, payload: payload}, fields))
  end
end
