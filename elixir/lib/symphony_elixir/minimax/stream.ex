defmodule SymphonyElixir.MiniMax.Stream do
  @moduledoc """
  Local MiniMax Code (`mcode`) headless session owner. Each turn starts the official CLI in
  `exec` mode with `--output-format stream-json` and resumes the previous CLI session by id.
  Only the existing Pi transport's process launch/cleanup primitives are reused; no Pi RPC
  messages are sent. The caller receives native MiniMax Code stream-json events.

  The credential belongs to the operator's own `mcode` login. This module passes the data
  directory path across the boundary and never reads, copies, or logs its contents.
  """

  use GenServer

  alias SymphonyElixir.Pi.Rpc

  @max_buffer_bytes 8_388_608
  @secret_name ~r/(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE[_-]?KEY)/i
  # Managed-login providers are selected through the operator's own credential store. The
  # environment copies are cleared so a stray host variable cannot silently pick another source.
  @provider_environment ["MINIMAX_API_KEY", "MINIMAX_BASE_URL", "MINIMAX_TOKEN"]
  @prompt_relative_path ".symphony/minimax/prompt.txt"
  @stderr_relative_path ".symphony/minimax/turn.stderr.log"
  @default_max_steps 60

  @type option :: {:max_steps, pos_integer()} | {:model, String.t()}

  @spec start(Path.t(), Path.t(), Path.t(), [option()]) :: GenServer.on_start()
  def start(workspace, executable, data_dir, opts \\ []) do
    GenServer.start(__MODULE__, {self(), workspace, executable, data_dir, opts})
  end

  @spec turn(pid(), String.t(), pos_integer()) :: {:ok, reference()} | {:error, term()}
  def turn(pid, prompt, timeout_ms) do
    GenServer.call(pid, {:turn, self(), prompt, timeout_ms}, :infinity)
  end

  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.stop(pid, :normal, :infinity)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init({owner, workspace, executable, data_dir, opts}) do
    {:ok,
     %{
       owner: Process.monitor(owner),
       workspace: workspace,
       executable: executable,
       data_dir: data_dir,
       max_steps: Keyword.get(opts, :max_steps, @default_max_steps),
       model: Keyword.get(opts, :model),
       session_id: nil,
       active: nil
     }}
  end

  @impl true
  def handle_call({:turn, caller, prompt, timeout_ms}, _from, %{active: nil} = state) do
    with {:ok, prompt_path} <- write_prompt(state.workspace, prompt),
         {:ok, transport} <- start_transport(state, turn_command(state, prompt_path)) do
      ref = make_ref()

      active = %{
        caller: caller,
        caller_monitor: Process.monitor(caller),
        ref: ref,
        deadline: Process.send_after(self(), {:deadline, ref}, timeout_ms),
        transport: transport,
        pending: "",
        result: nil,
        last_message: nil,
        failure: nil
      }

      {:reply, {:ok, ref}, %{state | active: active}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:turn, _caller, _prompt, _timeout_ms}, _from, state) do
    {:reply, {:error, :minimax_turn_in_progress}, state}
  end

  @impl true
  def handle_info({port, {:data, {_kind, chunk}}}, %{active: %{transport: %{port: port}} = active} = state) do
    buffer = active.pending <> chunk

    if byte_size(buffer) > @max_buffer_bytes do
      finish(state, {:error, :minimax_stream_too_large})
    else
      {:noreply, consume(state, buffer)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{active: %{transport: %{port: port}}} = state) do
    finish(state, exit_outcome(status, state.active, state.session_id, state.workspace))
  end

  def handle_info({:deadline, ref}, %{active: %{ref: ref}} = state) do
    finish(state, {:error, :minimax_turn_timeout})
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner: ref} = state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active: %{caller_monitor: ref}} = state) do
    finish(state, {:error, :minimax_caller_exited})
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp finish(state, outcome) do
    active = state.active
    Process.cancel_timer(active.deadline)
    Process.demonitor(active.caller_monitor, [:flush])
    close_transport(active.transport)
    send(active.caller, {:minimax_stream, active.ref, {:done, outcome}})
    {:noreply, %{state | active: nil}}
  end

  @impl true
  def terminate(_reason, %{active: active}) do
    if active, do: close_transport(active.transport)
    :ok
  end

  # The CLI frames its stream as JSON objects. The scanner accepts both newline-delimited and
  # concatenated objects, so a framing change in the CLI does not silently drop events.
  defp consume(state, buffer) do
    case next_event(buffer) do
      {:ok, event, rest} ->
        consume(handle_event(state, event), rest)

      :none ->
        %{state | active: %{state.active | pending: buffer}}
    end
  end

  defp next_event(buffer) do
    case :binary.match(buffer, "{") do
      :nomatch ->
        :none

      {offset, _length} ->
        decode_event(buffer, offset)
    end
  end

  defp decode_event(buffer, offset) do
    case scan_object(buffer, offset, 0, false, false) do
      {:ok, _scanned, rest_offset} -> decode_json(buffer, offset, rest_offset)
      :incomplete -> :none
    end
  end

  defp decode_json(buffer, offset, rest_offset) do
    size = rest_offset - offset

    case Jason.decode(binary_part(buffer, offset, size)) do
      {:ok, event} when is_map(event) ->
        {:ok, event, binary_part(buffer, rest_offset, byte_size(buffer) - rest_offset)}

      _other ->
        :none
    end
  end

  defp scan_object(binary, offset, _depth, _in_string, _escaped) when offset >= byte_size(binary), do: :incomplete

  defp scan_object(binary, offset, depth, in_string, escaped) do
    char = binary_part(binary, offset, 1)

    cond do
      escaped ->
        scan_object(binary, offset + 1, depth, in_string, false)

      in_string and char == <<?\\>> ->
        scan_object(binary, offset + 1, depth, in_string, true)

      char == <<?">> ->
        scan_object(binary, offset + 1, depth, not in_string, false)

      char == <<?{>> ->
        scan_object(binary, offset + 1, depth + 1, false, false)

      char == <<?}>> ->
        close_object(binary, offset, depth)

      true ->
        scan_object(binary, offset + 1, depth, in_string, false)
    end
  end

  defp close_object(binary, offset, depth) when depth <= 1, do: {:ok, binary, offset + 1}

  defp close_object(binary, offset, depth), do: scan_object(binary, offset + 1, depth - 1, false, false)

  defp handle_event(state, event) do
    active = state.active
    send(active.caller, {:minimax_stream, active.ref, {:event, event}})

    active =
      case event do
        %{"type" => "item.completed", "item" => %{"type" => "agent_message", "content" => text}}
        when is_binary(text) ->
          %{active | last_message: text}

        %{"type" => "exec.result"} ->
          %{active | result: event}

        %{"type" => "turn.failed"} ->
          %{active | failure: {:minimax_turn_failed, Map.take(event, ["status", "error"])}}

        _other ->
          active
      end

    %{state | session_id: event["sessionId"] || state.session_id, active: active}
  end

  defp exit_outcome(status, active, session_id, workspace) do
    case message_failure(read_stderr(workspace)) do
      nil -> result_outcome(status, active, session_id)
      reason -> {:error, reason}
    end
  end

  defp result_outcome(status, active, session_id) do
    cond do
      active.failure != nil ->
        {:error, active.failure}

      active.result == nil ->
        {:error, {:minimax_exit, status}}

      active.result["status"] != "succeeded" ->
        {:error, {:minimax_failed, Map.take(active.result, ["status", "error"])}}

      true ->
        {:ok, final_result(active, session_id)}
    end
  end

  defp final_result(active, session_id) do
    result = active.result

    %{
      "session_id" => session_id || result["sessionId"],
      "output" => output_text(result["output"]) || active.last_message,
      "model" => result["model"],
      "usage" => result["usage"],
      "status" => result["status"]
    }
  end

  defp output_text(output) when is_binary(output), do: output
  defp output_text(output) when is_map(output) or is_list(output), do: Jason.encode!(output)
  defp output_text(_output), do: nil

  defp message_failure(text) do
    cond do
      Regex.match?(~r/sign in to minimax|not logged in|please .*log ?in|authentication (?:failed|required)/i, text) ->
        :minimax_not_logged_in

      Regex.match?(~r/usage.?limit|rate.?limit|quota|out of extra usage|credit balance/i, text) ->
        :minimax_usage_limit

      true ->
        nil
    end
  end

  defp read_stderr(workspace) do
    case File.read(Path.join(workspace, @stderr_relative_path)) do
      {:ok, text} -> text
      _error -> ""
    end
  end

  defp write_prompt(workspace, prompt) do
    directory = Path.join(workspace, ".symphony/minimax")
    path = Path.join(workspace, @prompt_relative_path)

    with true <- File.dir?(workspace) or {:error, {:workspace_not_found, workspace}},
         :ok <- File.mkdir_p(directory),
         _existing <- File.rm(path),
         :ok <- File.write(path, prompt, [:exclusive]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    end
  end

  defp turn_command(state, prompt_path) do
    args = [
      "exec",
      "--cwd",
      state.workspace,
      "--output-format",
      "stream-json",
      # "ask" and "smart" can request a permission a headless host cannot answer.
      "--permission",
      "full",
      "--max-steps",
      Integer.to_string(state.max_steps),
      "--input",
      "-"
    ]

    args = if state.model, do: args ++ ["--model", state.model], else: args
    args = if state.session_id, do: args ++ ["--session", state.session_id], else: args

    shell_command([state.executable | args]) <> " < " <> shell_escape(prompt_path)
  end

  defp start_transport(state, command) do
    # Rpc startup verifies a live process-group leader. Hold the turn until that verification
    # completes, then release the shell gate (not a MiniMax Code request).
    launch = "IFS= read -r _symphony_ready && exec " <> command
    stderr_path = Path.join(state.workspace, @stderr_relative_path)

    with {:ok, transport} <- Rpc.start(state.workspace, launch, stderr_path: stderr_path, env: child_environment(state.data_dir)) do
      Port.command(transport.port, "\n")
      {:ok, transport}
    end
  end

  defp close_transport(transport) do
    # Rpc.close only signals the group while the port is alive. The CLI can exit before its tool
    # children, so this adapter also signals the recorded dedicated group after exit_status.
    signal_group(transport, "TERM")
    Rpc.close(transport)
    signal_group(transport, "KILL")
    :ok
  end

  defp signal_group(%{process_group_id: group}, signal) when is_integer(group) and group > 0 do
    case System.find_executable("kill") do
      nil -> :ok
      kill -> System.cmd(kill, ["-" <> signal, "--", "-" <> Integer.to_string(group)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _error -> :ok
  end

  defp signal_group(_transport, _signal), do: :ok

  defp child_environment(data_dir) do
    names = System.get_env() |> Map.keys() |> Enum.filter(&Regex.match?(@secret_name, &1))
    tracker_names = SymphonyElixir.Config.settings!().tracker.secret_environment_names || []

    scrubbed =
      (names ++ @provider_environment ++ tracker_names)
      |> Enum.uniq()
      |> Enum.map(&{String.to_charlist(&1), false})

    # Only the data directory path crosses the boundary. Its contents are never read here.
    [
      {~c"MINIMAX_DATA_DIR", String.to_charlist(data_dir)}
      | Enum.reject(scrubbed, fn {name, _value} -> name == ~c"MINIMAX_DATA_DIR" end)
    ]
  end

  defp shell_command(args), do: Enum.map_join(args, " ", &shell_escape/1)

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
