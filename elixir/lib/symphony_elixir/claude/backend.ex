defmodule SymphonyElixir.Claude.Backend do
  @moduledoc """
  Removable, local-only Claude Code subscription backend. Authentication and the default model
  belong to the operator's official `claude` CLI; Symphony never loads its credential files.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.{Claude.Stream, Config}

  @impl true
  def validate_config(%{worker: %{ssh_hosts: hosts}}) do
    if Enum.any?(hosts, &(is_binary(&1) and String.trim(&1) != "")) do
      {:error, {:unsupported_backend_worker_hosts, :claude}}
    else
      executable_available()
    end
  end

  def validate_config(_settings), do: executable_available()

  @impl true
  def start_session(workspace, opts \\ []) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) -> {:error, {:unsupported_backend_worker_host, :claude, host}}
      _ -> start_local(workspace)
    end
  end

  defp start_local(workspace) do
    with :ok <- executable_available(),
         true <- File.dir?(workspace) or {:error, {:workspace_not_found, workspace}} do
      Stream.start(Path.expand(workspace), System.find_executable("claude"))
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
        emit(on_message, :turn_completed, result, %{session_id: result["session_id"]})
        {:ok, %{session_id: result["session_id"], result: result, backend: :claude}}

      {:claude_stream, ^ref, {:done, {:error, reason}}} ->
        fail_turn(on_message, reason)

      {:DOWN, ^monitor, :process, ^session, reason} ->
        fail_turn(on_message, {:claude_session_exit, reason})
    end
  end

  @impl true
  def stop_session(session), do: Stream.close(session)

  defp executable_available do
    if System.find_executable("claude"), do: :ok, else: {:error, {:backend_executable_not_found, :claude, "claude"}}
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
