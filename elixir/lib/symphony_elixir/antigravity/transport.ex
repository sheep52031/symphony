defmodule SymphonyElixir.Antigravity.Transport do
  @moduledoc false

  alias SymphonyElixir.Antigravity.Launcher

  @line_bytes 1_048_576
  @max_identity_bytes 256
  @max_text_delta_bytes 65_536
  @step_types ~w(user_input agent_response tool checkpoint)
  @terminal_statuses ~w(SUCCESS ERROR CANCELED INTERRUPTED INVALID WAITING RUNNING)
  @process_group_detection_attempts 400
  @graceful_close_ms 250
  @forced_close_ms 500
  @bash_path "/usr/bin/bash"
  @setsid_path "/usr/bin/setsid"
  @kill_path "/usr/bin/kill"
  @ps_path "/usr/bin/ps"
  @usage_fields ~w(input_tokens output_tokens thinking_tokens cache_read_tokens total_tokens)
  @secret_name_pattern ~r/(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE[_-]?KEY)/i

  @type session :: %{
          port: port(),
          state: pid(),
          workspace: Path.t(),
          stderr_path: Path.t(),
          process_group_path: Path.t(),
          process_group_id: non_neg_integer(),
          os_pid: non_neg_integer() | nil,
          cleanup_guard_pid: pid() | nil,
          launch: Launcher.launch()
        }

  @type native_event_handler :: (map() -> term())

  @spec start(Path.t(), Path.t(), Path.t(), pos_integer(), keyword()) ::
          {:ok, session()} | {:error, term()}
  def start(workspace, agy_executable, profile_root, turn_timeout_ms, opts \\ []) do
    launcher = Keyword.get(opts, :launcher, &Launcher.build/5)
    launcher_opts = Keyword.take(opts, [:bubblewrap_executable])

    with {:ok, launch} <- launcher.(workspace, agy_executable, profile_root, turn_timeout_ms, launcher_opts),
         :ok <- prepare_runtime_directory(launch.workspace) do
      start_port(launch, opts)
    end
  rescue
    error in [ArgumentError, ErlangError, File.Error] -> {:error, error}
  end

  @spec run_turn(session(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{port: port} = session, prompt, opts \\ []) when is_port(port) and is_binary(prompt) do
    on_event = Keyword.get(opts, :on_event, &default_on_event/1)
    first_event_timeout_ms = Keyword.fetch!(opts, :first_event_timeout_ms)
    turn_timeout_ms = Keyword.fetch!(opts, :turn_timeout_ms)
    cancel_grace_ms = Keyword.get(opts, :cancel_grace_ms, 1_000)

    with :ok <- claim_turn(session.state) do
      try do
        with :ok <- send_prompt(port, prompt) do
          started_ms = monotonic_ms()

          loop = %{
            session: session,
            on_event: on_event,
            pending_line: "",
            progress_seen?: false,
            first_event_deadline_ms: started_ms + first_event_timeout_ms,
            turn_deadline_ms: started_ms + turn_timeout_ms,
            cancel_grace_ms: cancel_grace_ms
          }

          loop
          |> receive_turn()
          |> finalize_turn_result(session)
        end
      after
        release_turn(session.state)
      end
    end
  end

  @spec close(session()) :: :ok | {:error, term()}
  def close(session) do
    process_result = close_process(session)
    release_cleanup_guard(session)
    runtime_result = remove_runtime_files(session)
    stop_state(session.state)
    merge_cleanup_results(process_result, runtime_result)
  end

  @spec stderr(session()) :: {:ok, String.t()} | {:error, term()}
  def stderr(%{stderr_path: stderr_path}), do: File.read(stderr_path)

  defp start_port(launch, opts) do
    runtime_directory = Path.join(launch.workspace, ".symphony/antigravity")
    suffix = System.unique_integer([:positive, :monotonic])
    stderr_path = Path.join(runtime_directory, "session-#{suffix}.stderr.log")
    process_group_path = Path.join(runtime_directory, "session-#{suffix}.pgid")

    with :ok <- prepare_runtime_file(stderr_path),
         :ok <- prepare_runtime_file(process_group_path),
         :ok <- trusted_system_executable(@setsid_path, "setsid"),
         :ok <- trusted_system_executable(@bash_path, "bash"),
         :ok <- trusted_system_executable(@kill_path, "kill"),
         :ok <- trusted_system_executable(@ps_path, "ps") do
      command = Enum.map_join([launch.executable | launch.args], " ", &shell_escape/1)

      grouped_command =
        "umask 077; printf '%s' \"$$\" > #{shell_escape(process_group_path)}; exec #{command}"

      launch_command =
        "exec #{shell_escape(@setsid_path)} --wait #{shell_escape(@bash_path)} -c #{shell_escape(grouped_command)} 2> #{shell_escape(stderr_path)}"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(@bash_path)},
          [
            :binary,
            :exit_status,
            args: [~c"-c", String.to_charlist(launch_command)],
            cd: String.to_charlist(launch.workspace),
            env: secret_port_env(Keyword.get(opts, :secret_environment_names, [])),
            line: @line_bytes
          ]
        )

      finalize_started_port(port, launch, stderr_path, process_group_path)
    end
  end

  defp finalize_started_port(port, launch, stderr_path, process_group_path) do
    process_group_id = read_process_group_id(process_group_path)

    if is_nil(process_group_id) do
      close_port(port)
      {:error, :antigravity_process_group_setup_failed}
    else
      {:ok, state} =
        Agent.start_link(fn ->
          %{
            busy?: false,
            closed?: false,
            init_seen?: false,
            session_id: nil,
            turn_count: 0,
            usage: nil
          }
        end)

      base = %{
        port: port,
        state: state,
        workspace: launch.workspace,
        stderr_path: stderr_path,
        process_group_path: process_group_path,
        process_group_id: process_group_id,
        os_pid: port_os_pid(port),
        cleanup_guard_pid: nil,
        launch: launch
      }

      {:ok, %{base | cleanup_guard_pid: start_cleanup_guard(self(), base)}}
    end
  end

  defp receive_turn(loop) do
    timeout_ms = remaining_timeout_ms(loop)

    receive do
      {port, {:data, {:eol, chunk}}} when port == loop.session.port ->
        line = loop.pending_line <> to_string(chunk)
        handle_line(%{loop | pending_line: ""}, line)

      {port, {:data, {:noeol, chunk}}} when port == loop.session.port ->
        case append_pending_line(loop.pending_line, chunk) do
          {:ok, pending_line} -> receive_turn(%{loop | pending_line: pending_line})
          {:error, reason} -> {:error, reason}
        end

      {port, {:exit_status, status}} when port == loop.session.port ->
        mark_closed(loop.session.state)
        {:error, {:antigravity_process_exit, status}}
    after
      timeout_ms ->
        timeout_turn(loop)
    end
  end

  defp handle_line(loop, line) do
    normalized = String.trim_trailing(line, "\r")

    if byte_size(normalized) >= @line_bytes do
      {:error, :antigravity_protocol_frame_too_large}
    else
      case Jason.decode(normalized) do
        {:ok, %{} = event} -> handle_event(loop, event)
        {:ok, _other} -> {:error, {:invalid_antigravity_protocol_message, :not_an_object}}
        {:error, _reason} -> {:error, {:malformed_antigravity_protocol_line, :invalid_json}}
      end
    end
  end

  defp handle_event(loop, %{"event" => "init"} = event) do
    with {:ok, proof} <- accept_init(loop.session, event) do
      loop.on_event.(%{
        "event" => "init",
        "conversation_id" => proof.session_id,
        "init" => %{"cwd" => proof.cwd, "permission_mode" => proof.permission_mode}
      })

      receive_turn(Map.put(loop, :session_proof, proof))
    end
  end

  defp handle_event(loop, %{"event" => "step_update", "step_update" => update})
       when is_map(update) do
    with :ok <- validate_event_identity(loop.session.state, Map.get(update, "conversation_id")),
         {:ok, sanitized} <- validate_step_update(update) do
      loop.on_event.(%{"event" => "step_update", "step_update" => sanitized})

      receive_turn(%{loop | progress_seen?: true})
    end
  end

  defp handle_event(loop, %{"event" => "result", "result" => result})
       when is_map(result) do
    with {:ok, accepted} <- accept_result(loop.session.state, result) do
      loop.on_event.(%{
        "event" => "result",
        "result" => %{
          "conversation_id" => accepted.session_id,
          "status" => accepted.status
        }
      })

      {:ok, accepted}
    end
  end

  defp handle_event(_loop, %{"event" => _event}),
    do: {:error, :unsupported_antigravity_event}

  defp handle_event(_loop, _event), do: {:error, {:invalid_antigravity_protocol_message, :missing_event}}

  defp accept_init(session, %{"conversation_id" => session_id, "init" => init}) when is_map(init) do
    cwd = Map.get(init, "cwd")
    permission_mode = Map.get(init, "permission_mode")

    cond do
      not valid_identity?(session_id) ->
        {:error, :invalid_antigravity_conversation_id}

      cwd != session.workspace ->
        {:error, :antigravity_workspace_mismatch}

      permission_mode != "request-review" ->
        {:error, :unsafe_antigravity_permission_mode}

      true ->
        record_init(session, session_id, cwd, permission_mode)
    end
  end

  defp accept_init(_session, _event), do: {:error, :invalid_antigravity_init}

  defp record_init(session, session_id, cwd, permission_mode) do
    Agent.get_and_update(session.state, fn state ->
      if state.init_seen? do
        {{:error, :duplicate_antigravity_init}, state}
      else
        proof = %{
          session_id: session_id,
          cwd: cwd,
          permission_mode: permission_mode,
          backend_process_pid: session.process_group_id,
          stderr_path: session.stderr_path
        }

        {{:ok, proof}, %{state | init_seen?: true, session_id: session_id}}
      end
    end)
  end

  defp accept_result(state_pid, result) do
    identity = Map.get(result, "conversation_id")
    status = Map.get(result, "status")
    num_turns = Map.get(result, "num_turns")
    usage = Map.get(result, "usage")

    Agent.get_and_update(state_pid, fn state ->
      with true <- state.init_seen? || {:error, :antigravity_result_before_init},
           true <- identity == state.session_id || {:error, :antigravity_identity_mismatch},
           true <-
             status in @terminal_statuses || {:error, :invalid_antigravity_terminal_status},
           true <- num_turns == state.turn_count + 1 || {:error, :invalid_antigravity_turn_count},
           :ok <- validate_result_fields(status, result),
           {:ok, normalized_usage} <- validate_usage(usage, state.usage) do
        accepted = %{
          session_id: identity,
          status: status,
          response: Map.get(result, "response"),
          error: Map.get(result, "error"),
          denied_actions: Map.get(result, "denied_actions", []),
          duration_seconds: Map.get(result, "duration_seconds"),
          num_turns: num_turns,
          usage: normalized_usage
        }

        {{:ok, accepted}, %{state | turn_count: num_turns, usage: normalized_usage, busy?: false}}
      else
        {:error, reason} -> {{:error, reason}, state}
        false -> {{:error, :invalid_antigravity_result}, state}
      end
    end)
  end

  defp validate_event_identity(state_pid, identity) do
    Agent.get(state_pid, fn state ->
      cond do
        not valid_identity?(identity) -> {:error, :invalid_antigravity_conversation_id}
        not state.init_seen? -> {:error, :antigravity_event_before_init}
        identity != state.session_id -> {:error, :antigravity_identity_mismatch}
        true -> :ok
      end
    end)
  end

  defp validate_step_update(update) do
    step_type = Map.get(update, "step_type")

    with :ok <- validate_step_type(step_type),
         :ok <- validate_text_delta(update) do
      sanitized = %{"conversation_id" => Map.fetch!(update, "conversation_id"), "step_type" => step_type}

      sanitized =
        if Map.has_key?(update, "text_delta"),
          do: Map.put(sanitized, "text_delta", Map.fetch!(update, "text_delta")),
          else: sanitized

      {:ok, sanitized}
    end
  end

  defp validate_step_type(step_type) when step_type in @step_types, do: :ok
  defp validate_step_type(_step_type), do: {:error, :invalid_antigravity_step_type}

  defp validate_text_delta(update) do
    case Map.fetch(update, "text_delta") do
      :error -> :ok
      {:ok, text_delta} when is_binary(text_delta) and byte_size(text_delta) <= @max_text_delta_bytes -> :ok
      {:ok, text_delta} when is_binary(text_delta) -> {:error, :antigravity_text_delta_too_large}
      {:ok, _text_delta} -> {:error, :invalid_antigravity_text_delta}
    end
  end

  defp valid_identity?(identity) when is_binary(identity),
    do: identity != "" and byte_size(identity) <= @max_identity_bytes

  defp valid_identity?(_identity), do: false

  defp validate_result_fields(status, result) do
    response = Map.get(result, "response")
    error = Map.get(result, "error")
    denied_actions = Map.get(result, "denied_actions", [])
    duration = Map.get(result, "duration_seconds")

    cond do
      status == "SUCCESS" and not is_binary(response) -> {:error, :invalid_antigravity_response}
      not (is_nil(error) or is_binary(error)) -> {:error, :invalid_antigravity_error}
      not is_list(denied_actions) -> {:error, :invalid_antigravity_denied_actions}
      not is_number(duration) or duration < 0 -> {:error, :invalid_antigravity_duration}
      true -> :ok
    end
  end

  defp validate_usage(usage, previous) when is_map(usage) do
    normalized = Map.take(usage, @usage_fields)

    valid? =
      Enum.all?(@usage_fields, fn field ->
        value = Map.get(normalized, field)
        is_integer(value) and value >= 0
      end)

    cumulative? =
      is_nil(previous) or
        Enum.all?(@usage_fields, fn field -> Map.fetch!(normalized, field) >= Map.fetch!(previous, field) end)

    cond do
      not valid? -> {:error, :invalid_antigravity_usage}
      not cumulative? -> {:error, :noncumulative_antigravity_usage}
      true -> {:ok, normalized}
    end
  end

  defp validate_usage(_usage, _previous), do: {:error, :invalid_antigravity_usage}

  defp reviewed_terminal_status(status) when status in @terminal_statuses, do: status
  defp reviewed_terminal_status(_status), do: "UNKNOWN"

  defp remaining_timeout_ms(loop) do
    deadline =
      if loop.progress_seen? do
        loop.turn_deadline_ms
      else
        min(loop.first_event_deadline_ms, loop.turn_deadline_ms)
      end

    max(deadline - monotonic_ms(), 0)
  end

  defp timeout_turn(loop) do
    stage =
      if not loop.progress_seen? and monotonic_ms() >= loop.first_event_deadline_ms,
        do: :first_event,
        else: :absolute_turn_deadline

    signal_process_group(loop.session, "INT")
    terminal = collect_cancellation(loop, monotonic_ms() + loop.cancel_grace_ms, "")
    mark_closed(loop.session.state)

    case close_process(loop.session) do
      :ok -> {:error, {:antigravity_turn_timeout, stage, terminal}}
      {:error, reason} -> {:error, {:antigravity_turn_timeout, stage, {:cleanup_failed, reason, terminal}}}
    end
  end

  defp collect_cancellation(loop, deadline_ms, pending_line) do
    remaining = max(deadline_ms - monotonic_ms(), 0)

    receive do
      {port, {:data, {:eol, chunk}}} when port == loop.session.port ->
        line = pending_line <> to_string(chunk)

        case Jason.decode(String.trim_trailing(line, "\r")) do
          {:ok, %{"event" => "result", "result" => result}} when is_map(result) ->
            %{status: reviewed_terminal_status(Map.get(result, "status")), terminal_observed: true}

          {:ok, %{}} ->
            collect_cancellation(loop, deadline_ms, "")

          _ ->
            collect_cancellation(loop, deadline_ms, "")
        end

      {port, {:data, {:noeol, chunk}}} when port == loop.session.port ->
        case append_pending_line(pending_line, chunk) do
          {:ok, next_pending} -> collect_cancellation(loop, deadline_ms, next_pending)
          {:error, _reason} -> %{terminal_observed: false, oversized_frame: true}
        end

      {port, {:exit_status, _status}} when port == loop.session.port ->
        %{process_exited: true, terminal_observed: false}
    after
      remaining -> %{terminal_observed: false, grace_expired: true}
    end
  end

  defp finalize_turn_result({:error, {:antigravity_turn_timeout, _stage, _terminal}} = error, _session),
    do: error

  defp finalize_turn_result({:error, reason}, session) do
    mark_closed(session.state)

    case close_process(session) do
      :ok -> {:error, reason}
      {:error, cleanup_reason} -> {:error, {:antigravity_protocol_cleanup_failed, reason, cleanup_reason}}
    end
  end

  defp finalize_turn_result(result, _session), do: result

  defp append_pending_line(pending_line, chunk) do
    next = pending_line <> to_string(chunk)

    if byte_size(next) > @line_bytes,
      do: {:error, :antigravity_protocol_frame_too_large},
      else: {:ok, next}
  end

  defp send_prompt(port, prompt) do
    payload = %{"event" => "user", "message" => %{"content" => prompt}}

    Port.command(port, Jason.encode!(payload) <> "\n")
    :ok
  rescue
    ArgumentError -> {:error, :antigravity_port_closed}
  end

  defp claim_turn(state_pid) do
    Agent.get_and_update(state_pid, fn state ->
      cond do
        state.closed? -> {{:error, :antigravity_session_closed}, state}
        state.busy? -> {{:error, :antigravity_turn_already_running}, state}
        true -> {:ok, %{state | busy?: true}}
      end
    end)
  end

  defp release_turn(state_pid) do
    if Process.alive?(state_pid), do: Agent.update(state_pid, &%{&1 | busy?: false})
    :ok
  catch
    :exit, _ -> :ok
  end

  defp mark_closed(state_pid) do
    if Process.alive?(state_pid), do: Agent.update(state_pid, &%{&1 | closed?: true, busy?: false})
    :ok
  catch
    :exit, _ -> :ok
  end

  defp stop_state(state_pid) do
    if Process.alive?(state_pid), do: Agent.stop(state_pid, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp trusted_system_executable(path, name) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 -> :ok
      _ -> {:error, {:antigravity_runtime_executable_not_found, name, path}}
    end
  end

  defp secret_port_env(extra_names) do
    names =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&Regex.match?(@secret_name_pattern, &1))
      |> Kernel.++(Enum.filter(extra_names, &valid_environment_name?/1))
      |> Enum.uniq()

    Enum.map(names, &{String.to_charlist(&1), false})
  end

  defp valid_environment_name?(name),
    do: is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp read_process_group_id(path), do: read_process_group_id(path, @process_group_detection_attempts)
  defp read_process_group_id(_path, 0), do: nil

  defp read_process_group_id(path, attempts) do
    with {:ok, contents} <- File.read(path),
         {process_group_id, ""} <- contents |> String.trim() |> Integer.parse(),
         true <- dedicated_process_group?(process_group_id) do
      process_group_id
    else
      _ ->
        Process.sleep(5)
        read_process_group_id(path, attempts - 1)
    end
  rescue
    _error -> nil
  end

  defp dedicated_process_group?(process_group_id) do
    case System.cmd(@ps_path, ["-o", "pgid=", "-p", Integer.to_string(process_group_id)], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) == Integer.to_string(process_group_id)
      _ -> false
    end
  rescue
    _error -> false
  end

  defp start_cleanup_guard(owner_pid, session) do
    spawn(fn ->
      owner_ref = Process.monitor(owner_pid)

      receive do
        :antigravity_closed ->
          Process.demonitor(owner_ref, [:flush])
          :ok

        {:DOWN, ^owner_ref, :process, ^owner_pid, _reason} ->
          close_process(session)
          remove_runtime_files(session)
      end
    end)
  end

  defp release_cleanup_guard(%{cleanup_guard_pid: guard_pid}) when is_pid(guard_pid) do
    send(guard_pid, :antigravity_closed)
    :ok
  end

  defp release_cleanup_guard(_session), do: :ok

  defp close_process(session) do
    close_port(session.port)

    if wait_for_process_group_exit(session, @graceful_close_ms) do
      :ok
    else
      terminate_process_group(session)
    end
  end

  defp terminate_process_group(session) do
    signal_process_group(session, "TERM")

    if wait_for_process_group_exit(session, @graceful_close_ms) do
      :ok
    else
      kill_process_group(session)
    end
  end

  defp kill_process_group(session) do
    signal_process_group(session, "KILL")

    if wait_for_process_group_exit(session, @forced_close_ms),
      do: :ok,
      else: {:error, :antigravity_process_group_survived}
  end

  defp signal_process_group(%{process_group_id: process_group_id}, signal)
       when is_integer(process_group_id) and process_group_id > 0 do
    System.cmd(@kill_path, ["-#{signal}", "--", "-#{process_group_id}"], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp wait_for_process_group_exit(session, timeout_ms) do
    deadline_ms = monotonic_ms() + timeout_ms
    do_wait_for_process_group_exit(session, deadline_ms)
  end

  defp do_wait_for_process_group_exit(session, deadline_ms) do
    cond do
      not process_group_alive?(session) ->
        true

      monotonic_ms() >= deadline_ms ->
        false

      true ->
        Process.sleep(10)
        do_wait_for_process_group_exit(session, deadline_ms)
    end
  end

  defp process_group_alive?(%{process_group_id: process_group_id})
       when is_integer(process_group_id) and process_group_id > 0 do
    match?(
      {_output, 0},
      System.cmd(@kill_path, ["-0", "--", "-#{process_group_id}"], stderr_to_stdout: true)
    )
  rescue
    _error -> false
  end

  defp prepare_runtime_directory(workspace) do
    with :ok <- ensure_runtime_directory(Path.join(workspace, ".symphony"), false) do
      ensure_runtime_directory(Path.join(workspace, ".symphony/antigravity"), true)
    end
  end

  defp ensure_runtime_directory(path, restrict_existing?) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        if restrict_existing?, do: File.chmod(path, 0o700), else: :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_antigravity_runtime_path, path, type}}

      {:error, :enoent} ->
        with :ok <- File.mkdir(path), do: File.chmod(path, 0o700)

      {:error, reason} ->
        {:error, {:invalid_antigravity_runtime_path, path, reason}}
    end
  end

  defp prepare_runtime_file(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_antigravity_runtime_path, path, type}}
      {:error, reason} -> {:error, {:invalid_antigravity_runtime_path, path, reason}}
    end
  end

  defp remove_runtime_files(session) do
    with :ok <- remove_existing_file(session.process_group_path) do
      remove_existing_file(session.stderr_path)
    end
  end

  defp merge_cleanup_results(:ok, :ok), do: :ok
  defp merge_cleanup_results({:error, reason}, :ok), do: {:error, reason}
  defp merge_cleanup_results(:ok, {:error, reason}), do: {:error, {:antigravity_runtime_cleanup_failed, reason}}

  defp merge_cleanup_results({:error, process_reason}, {:error, runtime_reason}),
    do: {:error, {:antigravity_cleanup_failed, process_reason, runtime_reason}}

  defp remove_existing_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_port(port) do
    case :erlang.port_info(port) do
      :undefined -> :ok
      _ -> Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid >= 0 -> pid
      _ -> nil
    end
  end

  defp shell_escape(value) when is_binary(value),
    do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp default_on_event(_event), do: :ok
end
