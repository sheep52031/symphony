defmodule SymphonyElixir.Pi.Rpc do
  @moduledoc """
  Pi-native RPC transport for the local thin execution adapter.

  Pi RPC is a strict JSONL protocol on stdout. The client deliberately keeps stderr in a
  separate file and does not try to normalize Pi messages into the Codex protocol.
  """

  require Logger

  @port_line_bytes 1_048_576
  @default_timeout_ms 5_000
  @dialog_ui_methods ["select", "confirm", "input", "editor"]
  @fire_and_forget_ui_methods ["notify", "setStatus", "setWidget", "setTitle", "set_editor_text"]

  @type session :: %{
          port: port(),
          workspace: Path.t(),
          stderr_path: Path.t(),
          command: String.t(),
          os_pid: non_neg_integer() | nil
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
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    on_event = Keyword.get(opts, :on_event, &default_on_event/1)
    until = Keyword.get(opts, :until)

    case validate_request(type, timeout_ms, on_event, until, Keyword.get(opts, :ui_policy, :cancel)) do
      :ok ->
        payload = Map.merge(params, %{"type" => type, "id" => request_id})

        case send_message(port, payload) do
          :ok ->
            receive_response(%{
              session: session,
              request_id: request_id,
              on_event: on_event,
              timeout_ms: timeout_ms,
              pending_line: "",
              response: nil,
              settled?: false,
              until: until
            })

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_request(type, timeout_ms, on_event, until, ui_policy) do
    cond do
      String.trim(type) == "" -> {:error, :empty_request_type}
      not is_integer(timeout_ms) or timeout_ms <= 0 -> {:error, {:invalid_timeout, timeout_ms}}
      not is_function(on_event, 1) -> {:error, :invalid_event_handler}
      not is_nil(until) and not is_function(until, 1) -> {:error, :invalid_completion_predicate}
      ui_policy != :cancel -> {:error, {:invalid_ui_policy, ui_policy}}
      true -> :ok
    end
  end

  @spec close(session()) :: :ok
  def close(%{port: port}) when is_port(port) do
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

  @spec stderr(session()) :: {:ok, String.t()} | {:error, term()}
  def stderr(%{stderr_path: stderr_path}) when is_binary(stderr_path) do
    File.read(stderr_path)
  end

  defp start_port(workspace, command, stderr_path, opts) do
    with :ok <- File.mkdir_p(Path.dirname(stderr_path)),
         :ok <- File.write(stderr_path, "") do
      executable = System.find_executable("bash")
      launch_command = "exec #{command} 2> #{shell_escape(stderr_path)}"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            args: [~c"-lc", String.to_charlist(launch_command)],
            cd: String.to_charlist(workspace),
            env: Keyword.get(opts, :env, []),
            line: @port_line_bytes
          ]
        )

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} when is_integer(pid) and pid >= 0 -> pid
          _ -> nil
        end

      {:ok,
       %{
         port: port,
         workspace: workspace,
         stderr_path: stderr_path,
         command: command,
         os_pid: os_pid
       }}
    end
  end

  defp receive_response(%{session: %{port: port}} = state) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = state.pending_line <> to_string(chunk)
        handle_line(%{state | pending_line: ""}, line)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_response(%{state | pending_line: state.pending_line <> to_string(chunk)})

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      state.timeout_ms ->
        {:error, :timeout}
    end
  end

  defp handle_line(state, line) do
    normalized_line = String.trim_trailing(line, "\r")

    case Jason.decode(normalized_line) do
      {:ok, message} -> dispatch_message(state, message)
      {:error, reason} -> malformed_line(normalized_line, reason)
    end
  end

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

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_event(_event), do: :ok
end
