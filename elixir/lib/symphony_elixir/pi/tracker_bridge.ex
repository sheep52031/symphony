defmodule SymphonyElixir.Pi.TrackerBridge do
  @moduledoc """
  Per-session loopback bridge for provider-native tracker tools used by Pi.

  The bridge binds one tracker adapter snapshot and one issue context. Pi receives only a
  short-lived capability for this loopback endpoint; the provider credential remains in the
  Symphony host process.
  """

  use GenServer

  alias SymphonyElixir.{Linear.Handoff, Pi.TrackerBridgeExtension, Tracker}

  @capability_bytes 32
  @call_timeout_ms 60_000
  @handoff_tool "symphony_handoff"

  @type session :: %{
          pid: pid(),
          url: String.t(),
          extension_path: Path.t(),
          environment: [{charlist(), charlist()}],
          tool_names: [String.t()]
        }

  @spec start(Path.t(), keyword()) :: {:ok, session() | nil} | {:error, term()}
  def start(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    binding = Keyword.get_lazy(opts, :binding, &Tracker.bind_agent_tools/0)

    with :ok <- validate_binding(binding) do
      maybe_start_bridge(workspace, opts, binding, provider_tool_specs(binding))
    end
  end

  defp maybe_start_bridge(_workspace, _opts, _binding, []), do: {:ok, nil}

  defp maybe_start_bridge(workspace, opts, binding, _tool_specs) do
    with {:ok, extension_path} <- TrackerBridgeExtension.write(workspace),
         {:ok, pid} <- start_link(Keyword.put(opts, :binding, binding)) do
      build_session(pid, extension_path)
    end
  end

  defp build_session(pid, extension_path) do
    case bootstrap(pid) do
      {:ok, bootstrap} ->
        environment = [
          {~c"SYMPHONY_PI_TRACKER_BRIDGE_URL", String.to_charlist(bootstrap.url)},
          {~c"SYMPHONY_PI_TRACKER_BRIDGE_CAPABILITY", String.to_charlist(bootstrap.capability)},
          {~c"SYMPHONY_PI_TRACKER_BRIDGE_TOOL_SPECS", String.to_charlist(bootstrap.encoded_specs)}
        ]

        {:ok,
         %{
           pid: pid,
           url: bootstrap.url,
           extension_path: extension_path,
           environment: environment,
           tool_names: Enum.map(bootstrap.tool_specs, & &1["name"])
         }}

      {:error, reason} ->
        stop(pid)
        {:error, reason}
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec bind_issue(session() | pid() | nil, map()) :: :ok | {:error, term()}
  def bind_issue(nil, _issue), do: :ok

  def bind_issue(%{pid: pid}, issue) when is_pid(pid) and is_map(issue), do: bind_issue(pid, issue)

  def bind_issue(pid, issue) when is_pid(pid) and is_map(issue) do
    safe_call(pid, {:bind_issue, issue})
  end

  @spec execute(pid(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def execute(pid, capability, tool, arguments)
      when is_pid(pid) and is_binary(capability) and is_binary(tool) and is_map(arguments) do
    safe_call(pid, {:execute, capability, tool, arguments})
  end

  @spec commit_handoff(session() | pid() | nil) :: {:ok, map() | nil} | {:error, term()}
  def commit_handoff(nil), do: {:ok, nil}
  def commit_handoff(%{pid: pid}) when is_pid(pid), do: commit_handoff(pid)
  def commit_handoff(pid) when is_pid(pid), do: safe_call(pid, :commit_handoff)

  @spec stop(session() | pid() | nil) :: :ok
  def stop(nil), do: :ok
  def stop(%{pid: pid}) when is_pid(pid), do: stop(pid)

  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    binding = Keyword.fetch!(opts, :binding)
    capability = Base.url_encode64(:crypto.strong_rand_bytes(@capability_bytes), padding: false)
    tool_specs = provider_tool_specs(binding) ++ handoff_tool_specs(binding)
    executor = Keyword.get(opts, :tool_executor, &execute_bound_tool/4)
    handoff_executor = Keyword.get(opts, :handoff_executor, &execute_bound_handoff/3)

    state = %{
      bandit: nil,
      binding: binding,
      capability: capability,
      committed_handoff: nil,
      executor: executor,
      handoff_executor: handoff_executor,
      issue: nil,
      pending_handoff: nil,
      port: nil,
      tool_specs: tool_specs
    }

    case Bandit.start_link(
           plug: {SymphonyElixir.Pi.TrackerBridgePlug, bridge: self()},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           thousand_island_options: [num_acceptors: 1, num_connections: 16]
         ) do
      {:ok, bandit} ->
        case ThousandIsland.listener_info(bandit) do
          {:ok, {{127, 0, 0, 1}, port}} when is_integer(port) ->
            {:ok, %{state | bandit: bandit, port: port}}

          other ->
            Supervisor.stop(bandit)
            {:stop, {:invalid_tracker_bridge_listener, other}}
        end

      {:error, reason} ->
        {:stop, {:tracker_bridge_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:bootstrap, _from, state) do
    encoded_specs = state.tool_specs |> Jason.encode!() |> Base.url_encode64(padding: false)

    {:reply,
     {:ok,
      %{
        capability: state.capability,
        encoded_specs: encoded_specs,
        tool_specs: state.tool_specs,
        url: "http://127.0.0.1:#{state.port}/v1/tool"
      }}, state}
  end

  def handle_call({:bind_issue, issue}, _from, state) do
    case bind_issue_context(state.issue, issue) do
      {:ok, bound_issue} -> {:reply, :ok, %{state | issue: bound_issue}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:execute, capability, tool, arguments}, _from, state) do
    if valid_capability?(capability, state.capability) do
      {result, next_state} = execute_tool(state, tool, arguments)
      {:reply, {:ok, result}, next_state}
    else
      {:reply, {:error, :unauthorized}, state}
    end
  end

  def handle_call(:commit_handoff, _from, %{committed_handoff: committed} = state)
      when is_map(committed) do
    {:reply, {:ok, committed}, state}
  end

  def handle_call(:commit_handoff, _from, %{pending_handoff: nil} = state) do
    {:reply, {:ok, nil}, state}
  end

  def handle_call(:commit_handoff, _from, state) do
    request = state.pending_handoff
    result = safe_execute_handoff(state, request.target_state)

    if successful_tool_result?(result) do
      committed = %{request: handoff_receipt_request(request), result: result}
      {:reply, {:ok, committed}, %{state | committed_handoff: committed}}
    else
      {:reply, {:error, {:tracker_handoff_failed, handoff_receipt_request(request), result}}, state}
    end
  end

  @impl true
  def terminate(_reason, %{bandit: bandit}) when is_pid(bandit) do
    if Process.alive?(bandit), do: Supervisor.stop(bandit)
    :ok
  catch
    :exit, _reason -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp bootstrap(pid), do: safe_call(pid, :bootstrap)

  defp safe_call(pid, message) do
    GenServer.call(pid, message, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :bridge_unavailable}
  end

  defp validate_binding(%{
         adapter: adapter,
         tracker_settings: tracker_settings,
         tool_specs: tool_specs,
         secret_environment_names: secret_environment_names
       })
       when is_atom(adapter) and is_map(tracker_settings) and is_list(tool_specs) and
              is_list(secret_environment_names),
       do: :ok

  defp validate_binding(_binding), do: {:error, :invalid_tracker_bridge_binding}

  defp provider_tool_specs(%{tool_specs: specs}) when is_list(specs) do
    Enum.filter(specs, fn
      %{"name" => name, "inputSchema" => schema} when is_binary(name) and is_map(schema) -> true
      _ -> false
    end)
  end

  defp provider_tool_specs(_binding), do: []

  defp handoff_tool_specs(binding) do
    if handoff_supported?(binding), do: [handoff_tool_spec()], else: []
  end

  defp handoff_tool_spec do
    %{
      "name" => @handoff_tool,
      "description" => "Stage the final provider-native tracker transition until Symphony has persisted the settled Pi turn receipt.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["target_state"],
        "properties" => %{
          "target_state" => %{
            "type" => "string",
            "description" => "Non-active, non-terminal tracker state that will receive the current issue after the turn settles. Symphony resolves and applies this state host-side."
          }
        }
      }
    }
  end

  defp bind_issue_context(nil, issue), do: {:ok, issue}

  defp bind_issue_context(existing, issue) do
    if issue_identity(existing) == issue_identity(issue) do
      {:ok, issue}
    else
      {:error, {:tracker_bridge_issue_mismatch, issue_identity(existing), issue_identity(issue)}}
    end
  end

  defp issue_identity(issue) when is_map(issue), do: Map.get(issue, :id) || Map.get(issue, "id")

  defp execute_tool(%{issue: nil} = state, _tool, _arguments) do
    {failure_result("Symphony tracker bridge has no bound issue context."), state}
  end

  defp execute_tool(state, @handoff_tool, arguments) do
    if handoff_supported?(state.binding) do
      stage_handoff(state, arguments)
    else
      {failure_result("Tracker handoff is not implemented for this provider."), state}
    end
  end

  defp execute_tool(state, tool, arguments) do
    cond do
      tool not in provider_tool_names(state.binding) ->
        {failure_result("Unsupported tracker tool: #{inspect(tool)}."), state}

      direct_linear_state_transition?(state.binding, tool, arguments) ->
        {failure_result(
           "Direct Linear state transitions are disabled for Pi sessions. Use `symphony_handoff` so Symphony can persist the settled turn receipt before the issue leaves its active state."
         ), state}

      true ->
        {safe_execute(state, tool, arguments), state}
    end
  end

  defp stage_handoff(state, arguments) do
    with {:ok, request} <- normalize_handoff_request(state.binding, arguments),
         :ok <- validate_handoff_target(state.binding, request.target_state) do
      put_pending_handoff(state, request)
    else
      {:error, reason} -> {failure_result(handoff_error_message(reason)), state}
    end
  end

  defp put_pending_handoff(%{pending_handoff: nil} = state, request) do
    result =
      success_result("Handoff staged. Finish the turn; Symphony will persist completion evidence before applying the tracker transition.")

    {result, %{state | pending_handoff: request}}
  end

  defp put_pending_handoff(%{pending_handoff: existing} = state, request)
       when is_map(existing) do
    if same_handoff_request?(existing, request) do
      {success_result("The same handoff is already staged."), state}
    else
      conflicting_handoff_result(state)
    end
  end

  defp put_pending_handoff(state, _request), do: conflicting_handoff_result(state)

  defp conflicting_handoff_result(state) do
    {failure_result("A different handoff is already staged for this Pi turn."), state}
  end

  defp normalize_handoff_request(_binding, arguments) do
    target_state = Map.get(arguments, "target_state") || Map.get(arguments, :target_state)
    allowed_keys = ["target_state", :target_state]

    cond do
      not is_map(arguments) or not Enum.all?(Map.keys(arguments), &(&1 in allowed_keys)) ->
        {:error, :invalid_handoff_arguments}

      not present_string?(target_state) ->
        {:error, :invalid_target_state}

      true ->
        {:ok,
         %{
           target_state: String.trim(target_state),
           requested_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }}
    end
  end

  defp validate_handoff_target(binding, target_state) do
    normalized_target = normalize_state(target_state)
    tracker_settings = Map.get(binding, :tracker_settings, %{})
    active_states = Map.get(tracker_settings, :active_states, []) |> normalized_states()
    terminal_states = Map.get(tracker_settings, :terminal_states, []) |> normalized_states()

    cond do
      normalized_target == "" -> {:error, :invalid_target_state}
      normalized_target in active_states -> {:error, :active_handoff_target}
      normalized_target in terminal_states -> {:error, :terminal_handoff_target}
      true -> :ok
    end
  end

  defp normalized_states(states) when is_list(states), do: Enum.map(states, &normalize_state/1)
  defp normalized_states(_states), do: []

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""

  defp provider_tool_names(binding), do: Enum.map(provider_tool_specs(binding), & &1["name"])

  defp handoff_supported?(%{tracker_settings: tracker_settings}) do
    (Map.get(tracker_settings, :kind) || Map.get(tracker_settings, "kind")) == "linear"
  end

  defp handoff_supported?(_binding), do: false

  defp safe_execute(state, tool, arguments) do
    state.executor.(state.binding, tool, arguments, state.issue)
    |> normalize_tool_result()
  rescue
    error -> failure_result("Tracker tool execution failed: #{Exception.message(error)}")
  catch
    :throw, reason -> failure_result("Tracker tool execution failed: #{inspect({:throw, reason})}")
    :exit, reason -> failure_result("Tracker tool execution failed: #{inspect({:exit, reason})}")
  end

  defp safe_execute_handoff(state, target_state) do
    state.handoff_executor.(state.binding, target_state, state.issue)
    |> normalize_tool_result()
  rescue
    error -> failure_result("Tracker handoff failed: #{Exception.message(error)}")
  catch
    :throw, reason -> failure_result("Tracker handoff failed: #{inspect({:throw, reason})}")
    :exit, reason -> failure_result("Tracker handoff failed: #{inspect({:exit, reason})}")
  end

  defp execute_bound_tool(binding, tool, arguments, issue) do
    Tracker.execute_bound_agent_tool(binding, tool, arguments, issue: issue)
  end

  defp execute_bound_handoff(%{tracker_settings: tracker_settings} = binding, target_state, issue) do
    case Map.get(tracker_settings, :kind) || Map.get(tracker_settings, "kind") do
      "linear" -> Handoff.execute(binding, target_state, issue)
      kind -> failure_result("Tracker handoff is not implemented for provider: #{inspect(kind)}.")
    end
  end

  defp normalize_tool_result(%{"success" => success} = result) when is_boolean(success), do: result
  defp normalize_tool_result(other), do: failure_result("Invalid tracker tool result: #{inspect(other)}")

  defp successful_tool_result?(%{"success" => true}), do: true
  defp successful_tool_result?(_result), do: false

  defp success_result(message), do: tool_result(true, %{"message" => message})
  defp failure_result(message), do: tool_result(false, %{"error" => %{"message" => message}})

  defp tool_result(success, payload) do
    output = Jason.encode!(payload, pretty: true)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp direct_linear_state_transition?(binding, "linear_graphql", arguments) do
    tracker_settings = Map.get(binding, :tracker_settings, %{})
    kind = Map.get(tracker_settings, :kind) || Map.get(tracker_settings, "kind")
    query = Map.get(arguments, "query") || Map.get(arguments, :query) || ""
    variables = Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{}

    kind == "linear" and blocked_linear_state_mutation?(query, variables)
  end

  defp direct_linear_state_transition?(_binding, _tool, _arguments), do: false

  defp blocked_linear_state_mutation?(query, variables) do
    mutation_query?(query) and issue_update_query?(query) and state_id_present?(query, variables)
  end

  defp state_id_present?(query, variables) do
    contains_state_id?(variables) or Regex.match?(~r/\bstateId\s*:/i, query)
  end

  defp mutation_query?(query) when is_binary(query), do: Regex.match?(~r/\bmutation\b/i, query)
  defp mutation_query?(_query), do: false

  defp issue_update_query?(query) when is_binary(query) do
    Regex.match?(~r/\bissue(?:Batch)?Update\b/i, query)
  end

  defp issue_update_query?(_query), do: false

  defp contains_state_id?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} ->
      normalize_argument_key(key) == "stateid" or contains_state_id?(nested)
    end)
  end

  defp contains_state_id?(value) when is_list(value), do: Enum.any?(value, &contains_state_id?/1)
  defp contains_state_id?(_value), do: false

  defp normalize_argument_key(key), do: key |> to_string() |> String.downcase()

  defp valid_capability?(candidate, expected)
       when is_binary(candidate) and is_binary(expected) and byte_size(candidate) == byte_size(expected) do
    Plug.Crypto.secure_compare(candidate, expected)
  end

  defp valid_capability?(_candidate, _expected), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp handoff_receipt_request(request) do
    Map.take(request, [:requested_at, :target_state])
  end

  defp same_handoff_request?(left, right) do
    Map.take(left, [:target_state]) == Map.take(right, [:target_state])
  end

  defp handoff_error_message(:invalid_target_state), do: "`target_state` must be a non-empty string."

  defp handoff_error_message(:invalid_handoff_arguments),
    do: "`symphony_handoff` accepts only `target_state`; Symphony constructs the provider mutation host-side."

  defp handoff_error_message(:active_handoff_target),
    do: "The handoff target must not be an active tracker state."

  defp handoff_error_message(:terminal_handoff_target),
    do: "The handoff target must not be a terminal tracker state."
end
