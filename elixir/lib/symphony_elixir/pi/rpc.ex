defmodule SymphonyElixir.Pi.Rpc do
  @moduledoc """
  Pi-native RPC transport for the local thin execution adapter.

  Pi RPC is a strict JSONL protocol on stdout. The client deliberately keeps stderr in a
  separate file and does not try to normalize Pi messages into the Codex protocol.
  """

  require Logger

  @port_line_bytes 1_048_576
  @default_timeout_ms 5_000
  @graceful_close_ms 250
  @forced_close_ms 250
  @process_group_detection_attempts 400
  @dialog_ui_methods ["select", "confirm", "input", "editor"]
  @fire_and_forget_ui_methods ["notify", "setStatus", "setWidget", "setTitle", "set_editor_text"]

  @type session :: %{
          port: port(),
          workspace: Path.t(),
          stderr_path: Path.t(),
          command: String.t(),
          os_pid: non_neg_integer() | nil,
          process_group_id: non_neg_integer() | nil,
          process_group_path: Path.t() | nil,
          cleanup_guard_pid: pid() | nil
        }

  @spec start(Path.t(), String.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start(workspace, command, opts \\ []) when is_binary(workspace) and is_binary(command) do
    expanded_workspace = Path.expand(workspace)
    stderr_path = Keyword.get(opts, :stderr_path, Path.join(expanded_workspace, ".pi-rpc.stderr.log"))

    cond do
      String.trim(command) == "" ->
        {:error, :empty_command}

      not File.dir?(expanded_workspace) ->
        {:error, {:workspace_not_found, expanded_workspace}}

      is_nil(System.find_executable("bash")) ->
        {:error, :bash_not_found}

      true ->
        start_port(expanded_workspace, command, stderr_path, opts)
    end
  rescue
    error in [ArgumentError, ErlangError, File.Error] ->
      {:error, error}
  end

  @spec request(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(%{port: port} = session, type, params \\ %{}, opts \\ [])
      when is_port(port) and is_binary(type) and is_map(params) do
    request_id = "pi-rpc-#{System.unique_integer([:positive])}"

    with {:ok, state, payload} <- prepare_request(session, type, params, opts, request_id),
         :ok <- send_message(port, payload) do
      receive_response(state)
    end
  end

  defp prepare_request(session, type, params, opts, request_id) do
    request = %{
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      first_event_timeout_ms: Keyword.get(opts, :first_event_timeout_ms),
      requested_deadline_ms: Keyword.get(opts, :deadline_ms),
      on_event: Keyword.get(opts, :on_event, &default_on_event/1),
      until: Keyword.get(opts, :until),
      ui_policy: Keyword.get(opts, :ui_policy, :cancel)
    }

    with :ok <- validate_request(type, request) do
      now_ms = monotonic_ms()
      deadline_ms = min(now_ms + request.timeout_ms, request.requested_deadline_ms || now_ms + request.timeout_ms)

      first_event_deadline_ms =
        first_event_deadline(now_ms, request.first_event_timeout_ms, deadline_ms)

      state = %{
        session: session,
        request_id: request_id,
        on_event: request.on_event,
        deadline_ms: deadline_ms,
        first_event_deadline_ms: first_event_deadline_ms,
        first_event_seen?: false,
        pending_line: "",
        response: nil,
        settled?: false,
        until: request.until
      }

      {:ok, state, Map.merge(params, %{"type" => type, "id" => request_id})}
    end
  end

  defp first_event_deadline(now_ms, timeout_ms, deadline_ms) when is_integer(timeout_ms),
    do: min(now_ms + timeout_ms, deadline_ms)

  defp first_event_deadline(_now_ms, _timeout_ms, _deadline_ms), do: nil

  defp validate_request(type, request) do
    with :ok <- validate_request_type(type),
         :ok <- validate_positive_timeout(request.timeout_ms, :invalid_timeout),
         :ok <- validate_optional_positive_timeout(request.first_event_timeout_ms, :invalid_first_event_timeout),
         :ok <- validate_optional_deadline(request.requested_deadline_ms),
         :ok <- validate_handler(request.on_event, :invalid_event_handler),
         :ok <- validate_optional_handler(request.until, :invalid_completion_predicate) do
      validate_ui_policy(request.ui_policy)
    end
  end

  defp validate_request_type(type) do
    if String.trim(type) == "", do: {:error, :empty_request_type}, else: :ok
  end

  defp validate_positive_timeout(value, _error) when is_integer(value) and value > 0, do: :ok
  defp validate_positive_timeout(value, error), do: {:error, {error, value}}

  defp validate_optional_positive_timeout(nil, _error), do: :ok
  defp validate_optional_positive_timeout(value, error), do: validate_positive_timeout(value, error)

  defp validate_optional_deadline(nil), do: :ok
  defp validate_optional_deadline(value) when is_integer(value), do: :ok
  defp validate_optional_deadline(value), do: {:error, {:invalid_deadline, value}}

  defp validate_handler(value, _error) when is_function(value, 1), do: :ok
  defp validate_handler(_value, error), do: {:error, error}

  defp validate_optional_handler(nil, _error), do: :ok
  defp validate_optional_handler(value, error), do: validate_handler(value, error)

  defp validate_ui_policy(:cancel), do: :ok
  defp validate_ui_policy(value), do: {:error, {:invalid_ui_policy, value}}

  @spec close(session()) :: :ok
  def close(%{port: port} = session) when is_port(port) do
    if :erlang.port_info(port) != :undefined do
      close_port(port)
      terminate_process_group(session)
    end

    remove_process_group_file(session)
    release_cleanup_guard(session)
  end

  @spec stderr(session()) :: {:ok, String.t()} | {:error, term()}
  def stderr(%{stderr_path: stderr_path}) when is_binary(stderr_path) do
    File.read(stderr_path)
  end

  defp start_port(workspace, command, stderr_path, opts) do
    with :ok <- File.mkdir_p(Path.dirname(stderr_path)),
         :ok <- File.write(stderr_path, "") do
      process_group_path = Path.join(Path.dirname(stderr_path), "pi-rpc.pgid")
      File.rm(process_group_path)
      launch = build_launch(command, stderr_path, process_group_path)
      port = open_rpc_port(launch, workspace, opts)
      finalize_started_port(port, workspace, command, stderr_path, process_group_path, launch.setsid)
    end
  end

  defp build_launch(command, stderr_path, process_group_path) do
    executable = System.find_executable("bash")
    setsid = System.find_executable("setsid")

    launch_command =
      case setsid do
        path when is_binary(path) ->
          grouped_command =
            "printf '%s' \"$$\" > #{shell_escape(process_group_path)}; exec #{command}"

          "exec #{shell_escape(path)} --wait #{shell_escape(executable)} -lc #{shell_escape(grouped_command)} 2> #{shell_escape(stderr_path)}"

        _ ->
          "exec #{command} 2> #{shell_escape(stderr_path)}"
      end

    %{executable: executable, setsid: setsid, command: launch_command}
  end

  defp open_rpc_port(launch, workspace, opts) do
    Port.open(
      {:spawn_executable, String.to_charlist(launch.executable)},
      [
        :binary,
        :exit_status,
        args: [~c"-lc", String.to_charlist(launch.command)],
        cd: String.to_charlist(workspace),
        env: Keyword.get(opts, :env, []),
        line: @port_line_bytes
      ]
    )
  end

  defp finalize_started_port(port, workspace, command, stderr_path, process_group_path, setsid) do
    process_group_id =
      if is_binary(setsid), do: read_process_group_id(process_group_path), else: nil

    if is_binary(setsid) and is_nil(process_group_id) do
      close_port(port)
      {:error, :process_group_setup_failed}
    else
      session = %{
        port: port,
        workspace: workspace,
        stderr_path: stderr_path,
        command: command,
        os_pid: process_group_id || port_os_pid(port),
        process_group_id: process_group_id,
        process_group_path: if(is_binary(setsid), do: process_group_path),
        cleanup_guard_pid: nil
      }

      {:ok, %{session | cleanup_guard_pid: start_cleanup_guard(self(), session)}}
    end
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid >= 0 -> pid
      _ -> nil
    end
  end

  defp receive_response(%{session: %{port: port}} = state) do
    timeout_ms = remaining_timeout_ms(state)

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = state.pending_line <> to_string(chunk)
        handle_line(%{state | pending_line: ""}, line)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_response(%{state | pending_line: state.pending_line <> to_string(chunk)})

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        timeout_result(state)
    end
  end

  defp handle_line(state, line) do
    normalized_line = String.trim_trailing(line, "\r")

    case Jason.decode(normalized_line) do
      {:ok, message} -> dispatch_message(%{state | first_event_seen?: true}, message)
      {:error, reason} -> malformed_line(normalized_line, reason)
    end
  end

  defp remaining_timeout_ms(state) do
    deadline_ms =
      case {state.first_event_seen?, state.first_event_deadline_ms} do
        {false, first_event_deadline_ms} when is_integer(first_event_deadline_ms) ->
          min(first_event_deadline_ms, state.deadline_ms)

        _ ->
          state.deadline_ms
      end

    max(deadline_ms - monotonic_ms(), 0)
  end

  defp timeout_result(%{first_event_seen?: false, first_event_deadline_ms: deadline_ms})
       when is_integer(deadline_ms) do
    if deadline_ms <= monotonic_ms(), do: {:error, {:timeout, :first_event}}, else: {:error, :timeout}
  end

  defp timeout_result(_state), do: {:error, :timeout}

  defp dispatch_message(state, %{"type" => "response"} = response),
    do: handle_response_message(state, response)

  defp dispatch_message(
         state,
         %{"type" => "extension_ui_request", "id" => ui_id, "method" => method} = request
       )
       when is_binary(ui_id) and method in @dialog_ui_methods do
    result = cancel_dialog_ui_request(state, request)
    continue_after_ui_request(result, state)
  end

  defp dispatch_message(
         %{on_event: on_event} = state,
         %{"type" => "extension_ui_request", "id" => ui_id, "method" => method} = request
       )
       when is_binary(ui_id) and method in @fire_and_forget_ui_methods do
    on_event.(Map.put(request, "handled", "observed"))
    receive_response(state)
  end

  defp dispatch_message(
         _state,
         %{"type" => "extension_ui_request", "method" => method}
       ) do
    {:error, {:unsupported_extension_ui_method, method}}
  end

  defp dispatch_message(state, %{} = event) do
    state.on_event.(event)
    next_state = %{state | settled?: state.settled? or completion_event?(state.until, event)}

    if is_map(state.response) and next_state.settled? do
      {:ok, state.response}
    else
      receive_response(next_state)
    end
  end

  defp dispatch_message(_state, other), do: {:error, {:invalid_protocol_message, other}}

  defp handle_response_message(%{request_id: request_id} = state, %{"id" => request_id} = response) do
    case response_result(response) do
      {:error, reason} ->
        {:error, reason}

      {:ok, response} ->
        if is_nil(state.until) or state.settled? do
          {:ok, response}
        else
          receive_response(%{state | response: response})
        end
    end
  end

  defp handle_response_message(state, response) do
    state.on_event.(response)
    receive_response(state)
  end

  defp malformed_line(normalized_line, reason) do
    Logger.warning("Pi RPC emitted malformed stdout: #{inspect(reason)}")
    {:error, {:malformed_protocol_line, normalized_line}}
  end

  defp response_result(%{"success" => false} = response),
    do: {:error, {:command_failed, response}}

  defp response_result(response), do: {:ok, response}

  defp cancel_dialog_ui_request(
         %{session: %{port: port}, on_event: on_event},
         %{"id" => ui_id} = request
       )
       when is_binary(ui_id) do
    case send_message(port, %{"type" => "extension_ui_response", "id" => ui_id, "cancelled" => true}) do
      :ok ->
        on_event.(Map.put(request, "handled", "cancelled"))
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_after_ui_request(:ok, state), do: receive_response(state)
  defp continue_after_ui_request({:error, reason}, _state), do: {:error, reason}

  defp completion_event?(until, event) when is_function(until, 1), do: until.(event)
  defp completion_event?(_until, _event), do: false

  defp send_message(port, message) when is_port(port) and is_map(message) do
    Port.command(port, Jason.encode!(message) <> "\n")
    :ok
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  defp read_process_group_id(path),
    do: read_process_group_id(path, @process_group_detection_attempts)

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
    case System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(process_group_id)], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) == Integer.to_string(process_group_id)
      _ -> false
    end
  rescue
    _error -> false
  end

  defp signal_process_group(%{process_group_id: process_group_id}, signal)
       when is_integer(process_group_id) and process_group_id > 0 do
    case System.find_executable("kill") do
      path when is_binary(path) ->
        System.cmd(path, ["-#{signal}", "--", "-#{process_group_id}"], stderr_to_stdout: true)
        :ok

      _ ->
        :ok
    end
  rescue
    _error -> :ok
  end

  defp signal_process_group(%{os_pid: os_pid}, signal)
       when is_integer(os_pid) and os_pid > 0 do
    case System.find_executable("kill") do
      path when is_binary(path) ->
        System.cmd(path, ["-#{signal}", "--", Integer.to_string(os_pid)], stderr_to_stdout: true)
        :ok

      _ ->
        :ok
    end
  rescue
    _error -> :ok
  end

  defp signal_process_group(_session, _signal), do: :ok

  defp start_cleanup_guard(owner_pid, session) do
    spawn(fn ->
      owner_ref = Process.monitor(owner_pid)

      receive do
        :rpc_closed ->
          Process.demonitor(owner_ref, [:flush])
          :ok

        {:DOWN, ^owner_ref, :process, ^owner_pid, _reason} ->
          cleanup_orphaned_process_group(session)
      end
    end)
  end

  defp release_cleanup_guard(%{cleanup_guard_pid: guard_pid}) when is_pid(guard_pid) do
    send(guard_pid, :rpc_closed)
    :ok
  end

  defp release_cleanup_guard(_session), do: :ok

  defp cleanup_orphaned_process_group(session) do
    terminate_process_group(session)
    remove_process_group_file(session)
  end

  defp terminate_process_group(session) do
    if wait_for_process_group_exit(session, @graceful_close_ms) do
      :ok
    else
      signal_process_group(session, "TERM")
      force_process_group_exit(session)
    end
  end

  defp force_process_group_exit(session) do
    if wait_for_process_group_exit(session, @forced_close_ms) do
      :ok
    else
      signal_process_group(session, "KILL")
      wait_for_process_group_exit(session, @forced_close_ms)
      :ok
    end
  end

  defp remove_process_group_file(%{process_group_path: path}) when is_binary(path) do
    File.rm(path)
    :ok
  end

  defp remove_process_group_file(_session), do: :ok

  defp wait_for_process_group_exit(session, timeout_ms) when timeout_ms >= 0 do
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
    case System.find_executable("kill") do
      path when is_binary(path) ->
        match?({_output, 0}, System.cmd(path, ["-0", "--", "-#{process_group_id}"], stderr_to_stdout: true))

      _ ->
        false
    end
  rescue
    _error -> false
  end

  defp process_group_alive?(%{os_pid: os_pid}) when is_integer(os_pid) and os_pid > 0 do
    case System.find_executable("kill") do
      path when is_binary(path) ->
        match?({_output, 0}, System.cmd(path, ["-0", "--", Integer.to_string(os_pid)], stderr_to_stdout: true))

      _ ->
        false
    end
  rescue
    _error -> false
  end

  defp process_group_alive?(_session), do: false

  defp close_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_event(_event), do: :ok
end
