defmodule SymphonyElixir.Deepseek.Stream do
  @moduledoc """
  Local DeepSeek Harness (`dsh`) headless session owner. Each turn starts the executable in the
  issue workspace with the prompt on stdin (from a private file, so the child never sees a pipe
  that waits for EOF) and reads its NDJSON events. The first turn's session id is resumed with
  `--session-id`. Only the existing Pi transport's process launch/cleanup primitives are reused;
  no Pi RPC messages are sent.

  Usage is reported as a running total for the whole session: each `step_end` reports that
  step's usage, and cached context is counted again on every step, so the totals are summed here
  rather than read from the harness's last step.
  """

  use GenServer

  alias SymphonyElixir.Pi.Rpc

  @max_line_bytes 4_194_304
  @exit_grace_ms 250
  @secret_name ~r/(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE[_-]?KEY)/i
  # Supplied by the operator wrapper or environment: passed through untouched, its value never read or logged.
  @forwarded_environment ["DEEPSEEK_API_KEY"]
  @prompt_relative_path ".symphony/deepseek/prompt.txt"
  @stderr_relative_path ".symphony/deepseek/turn.stderr.log"

  @spec start(Path.t(), Path.t(), Path.t()) :: GenServer.on_start()
  def start(workspace, executable, dsh_home), do: GenServer.start(__MODULE__, {self(), workspace, executable, dsh_home})

  @spec turn(pid(), String.t(), pos_integer(), non_neg_integer()) :: {:ok, reference()} | {:error, term()}
  def turn(pid, prompt, timeout_ms, stall_timeout_ms),
    do: GenServer.call(pid, {:turn, self(), prompt, timeout_ms, stall_timeout_ms}, :infinity)

  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.stop(pid, :normal, :infinity)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init({owner, workspace, executable, dsh_home}) do
    {:ok,
     %{
       owner: Process.monitor(owner),
       workspace: workspace,
       executable: executable,
       dsh_home: dsh_home,
       session_id: nil,
       usage: %{input: 0, output: 0},
       active: nil
     }}
  end

  @impl true
  def handle_call({:turn, caller, prompt, timeout_ms, stall_timeout_ms}, _from, %{active: nil} = state) do
    with {:ok, prompt_path} <- write_prompt(state.workspace, prompt),
         {:ok, transport} <- start_transport(state, turn_command(state, prompt_path)) do
      ref = make_ref()

      active =
        %{
          caller: caller,
          caller_monitor: Process.monitor(caller),
          ref: ref,
          deadline: Process.send_after(self(), {:deadline, ref}, timeout_ms),
          stall_ms: stall_timeout_ms,
          stall_token: nil,
          stall_timer: nil,
          transport: transport,
          pending: "",
          final: nil,
          turn_reason: nil,
          exit_status: nil
        }
        |> rearm_stall()

      {:reply, {:ok, ref}, %{state | active: active}}
    else
      {:error, reason} -> {:reply, {:error, {:deepseek_start_failed, state.executable, reason}}, state}
    end
  end

  def handle_call({:turn, _, _, _, _}, _from, state), do: {:reply, {:error, :deepseek_turn_in_progress}, state}

  @impl true
  def handle_info({port, {:data, {kind, chunk}}}, %{active: %{transport: %{port: port}}} = state) do
    active = rearm_stall(state.active)
    line = active.pending <> chunk

    cond do
      byte_size(line) > @max_line_bytes ->
        finish(%{state | active: active}, {:error, :deepseek_stream_line_too_large})

      kind == :noeol ->
        {:noreply, %{state | active: %{active | pending: line}}}

      true ->
        handle_line(%{state | active: %{active | pending: ""}}, line)
    end
  end

  # The exit status can overtake stdout still buffered in the port, so the outcome waits for a short grace window.
  def handle_info({port, {:exit_status, status}}, %{active: %{transport: %{port: port}}} = state) do
    token = make_ref()
    Process.send_after(self(), {:exit_grace, token}, @exit_grace_ms)
    {:noreply, %{state | active: %{state.active | exit_status: {status, token}}}}
  end

  def handle_info({:exit_grace, token}, %{active: %{exit_status: {status, token}}} = state),
    do: finish(state, exit_outcome(status, state))

  def handle_info({:deadline, ref}, %{active: %{ref: ref}} = state), do: finish(state, {:error, :deepseek_turn_timeout})

  def handle_info({:stall, token}, %{active: %{stall_token: token}} = state), do: finish(state, {:error, :deepseek_stall_timeout})

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner: ref} = state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active: %{caller_monitor: ref}} = state),
    do: finish(state, {:error, :deepseek_caller_exited})

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{active: active}) do
    if active, do: close_transport(active.transport)
    :ok
  end

  defp handle_line(state, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = event} when is_binary(type) -> handle_event(state, event)
      _ -> finish(state, {:error, :deepseek_invalid_stream_json})
    end
  end

  defp handle_event(state, %{"type" => "error"} = event), do: finish(state, {:error, error_reason(event, state.session_id)})

  defp handle_event(state, event) do
    send(state.active.caller, {:deepseek_stream, state.active.ref, {:event, event}})

    case track(state, event) do
      {:ok, state} -> {:noreply, state}
      {:failed, reason} -> finish(state, {:error, reason})
    end
  end

  defp track(state, %{"type" => "session", "sessionId" => id}) when is_binary(id) and id != "",
    do: {:ok, %{state | session_id: id}}

  defp track(state, %{"type" => "status", "phase" => "turn_end", "reason" => %{"kind" => "completed"}}),
    do: {:ok, put_active(state, :turn_reason, "completed")}

  defp track(_state, %{"type" => "status", "phase" => "turn_end"} = event), do: {:failed, {:deepseek_turn_failed, reason_kind(event)}}

  defp track(state, %{"type" => "status", "phase" => "step_end", "usage" => usage}) when is_map(usage) do
    input = count(usage, "inputTokens") + count(usage, "cacheReadTokens") + count(usage, "cacheWriteTokens")
    output = count(usage, "outputTokens")
    totals = %{input: state.usage.input + input, output: state.usage.output + output}

    send(state.active.caller, {:deepseek_stream, state.active.ref, {:usage, usage_update(totals)}})
    {:ok, %{state | usage: totals}}
  end

  defp track(state, %{"type" => "final", "text" => text}) when is_binary(text), do: {:ok, put_active(state, :final, text)}
  defp track(state, _event), do: {:ok, state}

  defp usage_update(%{input: input, output: output}) do
    %{"input_tokens" => input, "output_tokens" => output, "total_tokens" => input + output}
  end

  defp count(usage, key) do
    case Map.get(usage, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp reason_kind(%{"reason" => %{"kind" => kind}}) when is_binary(kind), do: kind
  defp reason_kind(_event), do: "unknown"

  defp error_reason(%{"message" => message}, session_id) when is_binary(session_id) and is_binary(message) do
    if Regex.match?(~r/session .* does not exist/, message),
      do: {:deepseek_unknown_session, session_id},
      else: :deepseek_error_event
  end

  defp error_reason(_event, _session_id), do: :deepseek_error_event

  defp put_active(state, key, value), do: %{state | active: Map.put(state.active, key, value)}

  defp exit_outcome(status, state) do
    cond do
      status != 0 -> {:error, {:deepseek_exit, status}}
      not is_binary(state.session_id) -> {:error, :deepseek_missing_session_id}
      state.active.turn_reason != "completed" -> {:error, :deepseek_missing_turn_end}
      not is_binary(state.active.final) -> {:error, :deepseek_missing_final}
      true -> {:ok, %{session_id: state.session_id, text: state.active.final}}
    end
  end

  defp finish(%{active: active} = state, outcome) do
    Process.cancel_timer(active.deadline)
    cancel_stall(active)
    Process.demonitor(active.caller_monitor, [:flush])
    close_transport(active.transport)
    send(active.caller, {:deepseek_stream, active.ref, {:done, outcome}})
    {:noreply, %{state | active: nil}}
  end

  defp rearm_stall(%{stall_ms: ms} = active) when is_integer(ms) and ms > 0 do
    cancel_stall(active)
    token = make_ref()
    %{active | stall_token: token, stall_timer: Process.send_after(self(), {:stall, token}, ms)}
  end

  defp rearm_stall(active), do: active

  defp cancel_stall(%{stall_timer: timer}) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_stall(_active), do: :ok

  defp write_prompt(workspace, prompt) do
    directory = Path.join(workspace, ".symphony/deepseek")
    path = Path.join(workspace, @prompt_relative_path)

    with true <- File.dir?(workspace) or {:error, {:workspace_not_found, workspace}},
         :ok <- File.mkdir_p(directory),
         _ <- File.rm(path),
         :ok <- File.write(path, prompt, [:exclusive]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    end
  end

  defp turn_command(state, prompt_path) do
    resume = if state.session_id, do: ["--session-id", state.session_id], else: []
    shell_command([state.executable, "--profile", "headless", "--json"] ++ resume ++ ["-"]) <> " < " <> shell_escape(prompt_path)
  end

  defp start_transport(state, command) do
    # Rpc startup verifies a live process-group leader. Hold the turn until that verification
    # completes, then release the shell gate (not a Pi RPC request).
    launch = "IFS= read -r _symphony_ready && exec " <> command
    stderr_path = Path.join(state.workspace, @stderr_relative_path)

    with {:ok, transport} <- Rpc.start(state.workspace, launch, stderr_path: stderr_path, env: child_environment(state.dsh_home)) do
      Port.command(transport.port, "\n")
      {:ok, transport}
    end
  end

  defp shell_command(args), do: Enum.map_join(args, " ", &shell_escape/1)

  defp close_transport(transport) do
    # Rpc.close only signals the group while the port is alive. The harness can exit before its
    # tool children, so the recorded dedicated group is also signalled after exit_status.
    signal_group(transport, "TERM")
    Rpc.close(transport)
    signal_group(transport, "KILL")
    :ok
  end

  defp signal_group(transport, signal) do
    group = transport.process_group_id

    if is_integer(group) and group > 0 do
      System.cmd("kill", ["-" <> signal, "--", "-#{group}"], stderr_to_stdout: true)
    end

    :ok
  end

  defp child_environment(dsh_home) do
    names = System.get_env() |> Map.keys() |> Enum.filter(&Regex.match?(@secret_name, &1))
    tracker_names = SymphonyElixir.Config.settings!().tracker.secret_environment_names || []

    scrubbed =
      (names ++ tracker_names)
      |> Enum.reject(&(&1 in @forwarded_environment or &1 == "DSH_HOME"))
      |> Enum.uniq()
      |> Enum.map(&{String.to_charlist(&1), false})

    # Only the directory path is passed; the harness state inside it is never read or copied.
    [{~c"DSH_HOME", String.to_charlist(dsh_home)} | scrubbed]
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
