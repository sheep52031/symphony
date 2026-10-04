defmodule SymphonyElixir.Claude.Stream do
  @moduledoc """
  Local Claude print-mode session owner. Each turn starts the official executable and resumes
  the previous CLI session. Only the existing Pi transport's process launch/cleanup primitives
  are reused; no Pi RPC messages are sent. The caller receives native stream-json events.
  """

  use GenServer

  alias SymphonyElixir.Pi.Rpc

  @max_line_bytes 4_194_304
  @secret_name ~r/(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE[_-]?KEY)/i
  @provider_environment [
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_API_KEY_HELPER",
    "CLAUDE_CODE_BARE",
    "CLAUDE_CODE_SIMPLE"
  ]

  @spec start(Path.t(), Path.t()) :: GenServer.on_start()
  def start(workspace, executable), do: GenServer.start(__MODULE__, {self(), workspace, executable})

  @spec turn(pid(), String.t(), pos_integer()) :: {:ok, reference()} | {:error, term()}
  def turn(pid, prompt, timeout_ms), do: GenServer.call(pid, {:turn, self(), prompt, timeout_ms}, :infinity)

  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.stop(pid, :normal, :infinity)
    :ok
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end

  @impl true
  def init({owner, workspace, executable}) do
    {:ok, %{owner: Process.monitor(owner), workspace: workspace, executable: executable, session_id: nil, active: nil}}
  end

  @impl true
  def handle_call({:turn, caller, prompt, timeout_ms}, _from, %{active: nil} = state) do
    stderr_path = Path.join(state.workspace, ".symphony/claude/turn.stderr.log")
    # Check the CLI's public auth metadata, never the credentials backing it. This also rejects
    # provider selection restored by managed/user settings before any print-mode model request.
    command = shell_command([state.executable | isolation_args() ++ ["auth", "status", "--json"]])

    case start_transport(state.workspace, command, stderr_path) do
      {:ok, transport} ->
        ref = make_ref()
        timer = Process.send_after(self(), {:deadline, ref}, timeout_ms)

        active = %{
          caller: caller,
          caller_monitor: Process.monitor(caller),
          ref: ref,
          timer: timer,
          transport: transport,
          pending: "",
          result: nil,
          phase: :auth,
          prompt: prompt
        }

        {:reply, {:ok, ref}, %{state | active: active}}

      {:error, reason} ->
        {:reply, {:error, {:claude_start_failed, reason}}, state}
    end
  end

  def handle_call({:turn, _, _, _}, _from, state), do: {:reply, {:error, :claude_turn_in_progress}, state}

  @impl true
  def handle_info({port, {:data, {kind, chunk}}}, %{active: %{phase: :auth, transport: %{port: port}} = active} = state) do
    output = active.pending <> chunk <> if(kind == :eol, do: "\n", else: "")

    if byte_size(output) > @max_line_bytes do
      finish(state, {:error, :claude_invalid_auth_status})
    else
      {:noreply, %{state | active: %{active | pending: output}}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{active: %{phase: :auth, transport: %{port: port}}} = state),
    do: handle_auth_exit(state, status)

  def handle_info({port, {:data, {kind, chunk}}}, %{active: %{transport: %{port: port}} = active} = state) do
    line = active.pending <> chunk

    cond do
      byte_size(line) > @max_line_bytes ->
        finish(state, {:error, :claude_stream_line_too_large})

      kind == :noeol ->
        {:noreply, %{state | active: %{active | pending: line}}}

      true ->
        handle_line(%{state | active: %{active | pending: ""}}, line)
    end
  end

  def handle_info({port, {:exit_status, status}}, %{active: %{transport: %{port: port}} = active} = state) do
    outcome = exit_outcome(status, active.result, active.transport.stderr_path)
    finish(state, outcome)
  end

  def handle_info({:deadline, ref}, %{active: %{ref: ref}} = state),
    do: finish(state, {:error, :claude_turn_timeout})

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner: ref} = state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active: %{caller_monitor: ref}} = state),
    do: finish(state, {:error, :claude_caller_exited})

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{active: active}) do
    if active, do: close_transport(active.transport)
    :ok
  end

  defp handle_auth_exit(state, status) do
    active = state.active

    case {status, Jason.decode(active.pending)} do
      {0, {:ok, %{"authMethod" => "claude.ai"}}} ->
        close_transport(active.transport)

        case start_transport(state.workspace, command(state, active.prompt), active.transport.stderr_path) do
          {:ok, transport} ->
            {:noreply, %{state | active: %{active | phase: :stream, transport: transport, pending: ""}}}

          {:error, reason} ->
            finish(state, {:error, {:claude_start_failed, reason}})
        end

      {_, {:ok, %{"authMethod" => "none"}}} ->
        finish(state, {:error, :claude_not_logged_in})

      {_, {:ok, %{"authMethod" => method}}} ->
        finish(state, {:error, {:claude_subscription_required, method}})

      {_, _} ->
        finish(state, {:error, :claude_invalid_auth_status})
    end
  end

  defp handle_line(state, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = event} when is_binary(type) -> handle_event(state, event)
      _ -> finish(state, {:error, message_failure(line) || :claude_invalid_stream_json})
    end
  end

  defp handle_event(state, event) do
    case event_failure(event) do
      nil ->
        active = state.active
        send(active.caller, {:claude_stream, active.ref, {:event, event}})
        result = if event["type"] == "result", do: event, else: active.result
        session_id = event["session_id"] || state.session_id
        {:noreply, %{state | session_id: session_id, active: %{active | result: result}}}

      reason ->
        finish(state, {:error, reason})
    end
  end

  defp finish(%{active: active} = state, outcome) do
    Process.cancel_timer(active.timer)
    Process.demonitor(active.caller_monitor, [:flush])
    close_transport(active.transport)
    send(active.caller, {:claude_stream, active.ref, {:done, outcome}})
    {:noreply, %{state | active: nil}}
  end

  defp exit_outcome(status, result, stderr_path) do
    stderr =
      case File.read(stderr_path) do
        {:ok, text} -> text
        _ -> ""
      end

    case message_failure(stderr) do
      nil -> result_outcome(status, result)
      reason -> {:error, reason}
    end
  end

  defp result_outcome(status, _result) when status != 0, do: {:error, {:claude_exit, status}}
  defp result_outcome(0, nil), do: {:error, :claude_missing_result}

  defp result_outcome(0, result) do
    cond do
      not valid_session_id?(result["session_id"]) ->
        {:error, :claude_missing_session_id}

      result["subtype"] != "success" or result["is_error"] != false ->
        {:error, {:claude_result_failed, Map.take(result, ["subtype", "is_error", "errors", "result"])}}

      true ->
        {:ok, result}
    end
  end

  defp valid_session_id?(id), do: is_binary(id) and String.trim(id) != ""

  defp event_failure(%{"type" => "system", "subtype" => "init", "apiKeySource" => source})
       when source not in ["none", "oauth"], do: {:claude_subscription_required, source}

  defp event_failure(%{"error" => "authentication_failed"}), do: :claude_not_logged_in
  defp event_failure(%{"error" => error}) when error in ["rate_limit", "billing_error"], do: :claude_usage_limit
  defp event_failure(%{"type" => "result", "is_error" => true} = event), do: message_failure(Jason.encode!(event))
  defp event_failure(_event), do: nil

  defp message_failure(text) do
    cond do
      Regex.match?(~r/not logged in|please (?:run .*login|log in)|authentication_failed|authentication required/i, text) ->
        :claude_not_logged_in

      Regex.match?(~r/usage.?limit|rate.?limit|quota|you.ve hit your limit|credit balance|out of extra usage/i, text) ->
        :claude_usage_limit

      true ->
        nil
    end
  end

  defp command(state, prompt) do
    args = [
      "-p",
      "--output-format",
      "stream-json",
      "--verbose",
      "--include-partial-messages",
      "--permission-mode",
      "dontAsk",
      "--strict-mcp-config"
    ]

    resume = if state.session_id, do: ["--resume", state.session_id], else: []
    shell_command([state.executable | isolation_args() ++ args ++ resume ++ ["--", prompt]])
  end

  defp isolation_args do
    # An empty object would merge with the profile's env; override each billing selector instead.
    env = Map.new(@provider_environment, &{&1, ""})
    settings = %{"forceLoginMethod" => "claudeai", "apiKeyHelper" => "", "env" => env}
    ["--safe-mode", "--setting-sources", "user", "--settings", Jason.encode!(settings)]
  end

  defp start_transport(workspace, command, stderr_path) do
    # Rpc startup verifies a live process-group leader. Hold short-lived print/status commands
    # until that verification completes, then release the shell gate (not a Pi RPC request).
    launch = "IFS= read -r _symphony_ready && exec " <> command

    with {:ok, transport} <- Rpc.start(workspace, launch, stderr_path: stderr_path, env: child_environment()) do
      Port.command(transport.port, "\n")
      {:ok, transport}
    end
  end

  defp shell_command(args) do
    # The complete prompt is in argv. Unlike Pi RPC, print mode must not wait on an open input pipe.
    Enum.map_join(args, " ", &shell_escape/1) <> " < /dev/null"
  end

  defp close_transport(transport) do
    # Rpc.close only signals the group while the port is alive. Claude can exit before its tool
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
    _ -> :ok
  end

  defp signal_group(_transport, _signal), do: :ok

  defp child_environment do
    names = System.get_env() |> Map.keys() |> Enum.filter(&Regex.match?(@secret_name, &1))
    tracker_names = SymphonyElixir.Config.settings!().tracker.secret_environment_names || []

    (names ++ @provider_environment ++ tracker_names)
    |> Enum.uniq()
    |> Enum.map(&{String.to_charlist(&1), false})
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
