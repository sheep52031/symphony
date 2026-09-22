defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured issue tracker and dispatches repository copies to configured backend workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentBackend, AgentRunner, Config, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Antigravity.Transport
  alias SymphonyElixir.Tracker.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @resume_handoff_timeout_ms 10_000
  @native_cleanup_timeout_ms 2_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @assistant_text_bytes 65_536
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      task_supervisor: SymphonyElixir.TaskSupervisor,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil,
      lifecycle_storage_fault: nil
    ]
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    case Config.settings() do
      {:ok, config} ->
        now_ms = System.monotonic_time(:millisecond)

        state = %State{
          poll_interval_ms: config.polling.interval_ms,
          max_concurrent_agents: config.agent.max_concurrent_agents,
          next_poll_due_at_ms: now_ms,
          poll_check_in_progress: false,
          tick_timer_ref: nil,
          tick_token: nil,
          task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
          codex_totals: @empty_codex_totals,
          codex_rate_limits: nil
        }

        with :ok <- SymphonyElixir.TerminalFailure.storage_ready(),
             :ok <- run_terminal_workspace_cleanup() do
          {:ok, schedule_tick(state, 0)}
        else
          {:error, reason} -> {:stop, {:terminal_lifecycle_storage_unavailable, reason}}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          case verify_resumed_native_cleanup(running_entry, reason) do
            :ok -> handle_agent_down(reason, state, issue_id, running_entry, session_id)
            {:error, cleanup_reason} -> fail_resumed_native_cleanup(state, issue_id, running_entry, cleanup_reason)
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)
          |> then(&%{&1 | running: Map.put(running, issue_id, updated_running_entry)})
          |> maybe_latch_terminal_storage_failure(updated_running_entry)
          |> maybe_complete_resume_handoff(issue_id, update)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:resume_handoff_timeout, issue_id, token}, state) do
    {:noreply, fail_pending_resume(state, issue_id, token, :terminal_resume_writer_not_proven)}
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    cond do
      pending_resume_handoff?(running_entry) ->
        fail_pending_resume_agent_down(state, issue_id, running_entry)

      terminal_storage_failure_blocker?(running_entry) ->
        block_terminal_storage_failure_agent_down(state, issue_id, running_entry, session_id)

      terminal_failure_blocker?(running_entry) ->
        block_terminal_failure_agent_down(state, issue_id, running_entry, session_id)

      input_required_blocker?(running_entry) ->
        block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)

      Config.hold_after_normal_completion?() ->
        Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; holding active issue after normal completion")

        block_issue_from_entry(
          state,
          issue_id,
          running_entry,
          "normal completion held by agent.hold_after_normal_completion",
          :normal_completion_hold
        )

      true ->
        Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

        metadata = retry_metadata_from_entry(running_entry, %{delay_type: :continuation})

        state
        |> complete_issue(issue_id)
        |> schedule_issue_retry(issue_id, 1, metadata)
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    cond do
      pending_resume_handoff?(running_entry) ->
        fail_pending_resume_agent_down(state, issue_id, running_entry)

      terminal_storage_failure_blocker?(running_entry) ->
        block_terminal_storage_failure_agent_down(state, issue_id, running_entry, session_id)

      terminal_failure_blocker?(running_entry) ->
        block_terminal_failure_agent_down(state, issue_id, running_entry, session_id)

      input_required_blocker?(running_entry) ->
        block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)

      resumed_attempt?(running_entry) ->
        settle_resumed_attempt(
          state,
          issue_id,
          running_entry,
          :worker_crashed,
          "resumed writer exited before successful settlement"
        )

      true ->
        retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp block_terminal_storage_failure_agent_down(state, issue_id, running_entry, session_id) do
    failure = Map.fetch!(running_entry, :terminal_storage_failure)

    Logger.error(
      "Agent lifecycle storage failed issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id} code=#{failure.code}; disabling all dispatch until operator restart after storage recovery"
    )

    state =
      block_issue_from_entry(
        state,
        issue_id,
        running_entry,
        "terminal lifecycle storage unavailable: #{failure.code}",
        :terminal_storage_failure
      )

    latch_lifecycle_storage_fault(state, failure)
  end

  defp maybe_latch_terminal_storage_failure(state, running_entry) do
    case Map.get(running_entry, :terminal_storage_failure) do
      %{code: code} = failure when is_atom(code) or is_binary(code) ->
        latch_lifecycle_storage_fault(state, failure)

      _other ->
        state
    end
  end

  defp latch_lifecycle_storage_fault(state, failure) do
    Enum.each(state.retry_attempts, fn {_issue_id, retry} ->
      case Map.get(retry, :timer_ref) do
        timer_ref when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
        _other -> :ok
      end
    end)

    %{state | lifecycle_storage_fault: failure, retry_attempts: %{}}
  end

  defp block_terminal_failure_agent_down(state, issue_id, running_entry, session_id) do
    evidence = Map.fetch!(running_entry, :terminal_failure)

    Logger.warning(
      "Agent attempt settled with terminal failure issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id} terminal_reason=#{evidence.reason} event_id=#{evidence.event_id}; holding for external policy"
    )

    block_issue_from_entry(
      state,
      issue_id,
      running_entry,
      "terminal failure held for external policy: #{evidence.reason}",
      :terminal_failure
    )
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)
    metadata = retry_metadata_from_entry(running_entry, %{error: "agent exited: #{inspect(reason)}"})
    schedule_issue_retry(state, issue_id, next_attempt, metadata)
  end

  defp resumed_attempt?(running_entry) do
    match?(%{status: :proven}, Map.get(running_entry, :resume_handoff)) and
      is_map(Map.get(running_entry, :binding)) and
      is_binary(Map.get(running_entry, :binding_id))
  end

  defp verify_resumed_native_cleanup(running_entry, reason) do
    cond do
      reason == :normal ->
        :ok

      not resumed_attempt?(running_entry) ->
        :ok

      Map.get(running_entry, :backend) in [:antigravity, "antigravity"] ->
        Transport.await_owner_cleanup(Map.fetch!(running_entry, :pid), @native_cleanup_timeout_ms)

      true ->
        :ok
    end
  end

  defp fail_resumed_native_cleanup(state, issue_id, running_entry, cleanup_reason) do
    evidence =
      Map.get(running_entry, :terminal_failure) ||
        get_in(running_entry, [:resume_handoff, :blocked_entry, :terminal_failure])

    failure = %{
      code: :native_process_cleanup_unverified,
      event_id: if(is_map(evidence), do: Map.get(evidence, :event_id)),
      workspace: Map.get(running_entry, :workspace_path)
    }

    if is_map(evidence) and is_binary(failure.workspace) do
      _ =
        SymphonyElixir.TerminalFailure.persist_storage_fault(
          failure.workspace,
          evidence,
          failure.code
        )
    end

    Logger.error(
      "Resumed writer native cleanup could not be verified issue_id=#{issue_id} code=#{stable_terminal_error(cleanup_reason)}; disabling all dispatch until operator restart after cleanup verification"
    )

    running_entry = Map.put(running_entry, :terminal_storage_failure, failure)

    state
    |> block_issue_from_entry(
      issue_id,
      running_entry,
      "native process cleanup unverified: #{stable_terminal_error(cleanup_reason)}",
      :terminal_storage_failure
    )
    |> latch_lifecycle_storage_fault(failure)
  end

  defp retry_metadata_from_entry(running_entry, overrides) do
    Map.merge(
      %{
        identifier: running_entry.identifier,
        issue_url: running_entry.issue.url,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        backend: Map.get(running_entry, :backend),
        session_id: Map.get(running_entry, :session_id),
        binding: Map.get(running_entry, :binding)
      },
      overrides
    )
  end

  defp settle_resumed_attempt(state, issue_id, running_entry, reason, message) do
    evidence =
      SymphonyElixir.TerminalFailure.build(reason, %{}, %{
        backend: Map.get(running_entry, :backend),
        issue_id: issue_id,
        issue_identifier: Map.get(running_entry, :identifier),
        attempt: Map.get(running_entry, :writer_attempt),
        public_attempt: Map.get(running_entry, :retry_attempt),
        writer_id: Map.get(running_entry, :writer_id),
        session_id: Map.get(running_entry, :session_id),
        workspace: Map.get(running_entry, :workspace_path),
        binding_id: Map.get(running_entry, :binding_id),
        predecessor_event_id: get_in(running_entry, [:resume_handoff, :blocked_entry, :terminal_failure, :event_id])
      })

    case SymphonyElixir.TerminalFailure.persist(evidence.workspace, evidence) do
      {:ok, _path} ->
        running_entry = Map.put(running_entry, :terminal_failure, evidence)
        block_issue_from_entry(state, issue_id, running_entry, message, :terminal_failure)

      {:error, persist_reason} ->
        failure = %{
          code: :terminal_failure_persist_failed,
          event_id: evidence.event_id,
          workspace: evidence.workspace
        }

        _ =
          SymphonyElixir.TerminalFailure.persist_storage_fault(
            evidence.workspace,
            evidence,
            failure.code
          )

        running_entry = Map.put(running_entry, :terminal_storage_failure, failure)

        state
        |> block_issue_from_entry(
          issue_id,
          running_entry,
          "terminal lifecycle storage unavailable: #{stable_terminal_error(persist_reason)}",
          :terminal_storage_failure
        )
        |> latch_lifecycle_storage_fault(failure)
    end
  end

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()

    if state.lifecycle_storage_fault do
      Logger.error("Dispatch disabled by terminal lifecycle storage fault code=#{state.lifecycle_storage_fault.code}")
      state
    else
      dispatch_available_issues(state)
    end
  end

  defp dispatch_available_issues(%State{} = state) do
    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_issues_by_states(Config.settings!().tracker.active_states),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Tracker API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Tracker project scope missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from issue tracker: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = Map.keys(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(Issue.t(), term(), String.t(), non_neg_integer(), map()) ::
          term()
  def handle_retry_issue_lookup_for_test(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    {:noreply, updated_state} = handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    updated_state
  end

  @doc false
  @spec schedule_retry_for_test(term(), String.t(), map()) :: term()
  def schedule_retry_for_test(%State{} = state, issue_id, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    schedule_issue_retry(state, issue_id, 1, metadata)
  end

  @doc false
  @spec reserve_issue_attempt_for_test(Issue.t(), term()) :: {:ok | :exhausted, term()}
  def reserve_issue_attempt_for_test(%Issue{} = issue, %State{} = state) do
    case reserve_issue_attempt(state, issue) do
      {:ok, state} -> {:ok, state}
      {:exhausted, state} -> {:exhausted, state}
    end
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true, "terminal_state:#{issue.state}")

      !issue_routable?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false, "routing_revoked")

      !issue_identifier_allowed?(issue.identifier) ->
        Logger.info("Issue identifier is no longer allowed: #{issue_context(issue)}; stopping active agent")

        terminate_running_issue(state, issue.id, false, "identifier_revoked")

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false, "non_active_state:#{issue.state}")
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; settling lifecycle and releasing block")
        blocked_entry = Map.get(state.blocked, issue.id, %{})

        case cleanup_terminal_issue_lifecycle(issue, blocked_entry) do
          :ok ->
            release_issue_claim(state, issue.id)

          {:error, reason} ->
            latch_blocked_cleanup_failure(state, issue.id, blocked_entry, reason)
        end

      !issue_routable?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      !issue_identifier_allowed?(issue.identifier) ->
        Logger.info("Blocked issue is no longer allowed: #{issue_context(issue)}; releasing block")
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false, "issue_missing")
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp latch_blocked_cleanup_failure(state, issue_id, blocked_entry, reason) do
    failure = %{code: :terminal_cleanup_failed, event_id: terminal_event_id(blocked_entry)}

    blocked =
      Map.update!(state.blocked, issue_id, fn entry ->
        Map.put(entry, :reason, "terminal lifecycle cleanup failed: #{stable_terminal_error(reason)}")
      end)

    state
    |> Map.put(:blocked, blocked)
    |> latch_lifecycle_storage_fault(failure)
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(
         %State{} = state,
         issue_id,
         cleanup_workspace,
         cancellation_reason
       ) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        stop_running_task(pid, ref, state.task_supervisor)

        if cleanup_workspace do
          settle_running_terminal_issue(
            state,
            issue_id,
            running_entry,
            Map.get(running_entry, :issue, identifier)
          )
        else
          release_terminated_running_issue(state, issue_id, cancellation_reason)
        end

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp settle_running_terminal_issue(state, issue_id, running_entry, issue) do
    cleanup_result = settle_running_terminal_lifecycle(issue, running_entry)

    case cleanup_result do
      :ok ->
        release_terminated_running_issue(state, issue_id, "terminal_state")

      {:error, reason} ->
        failure = %{
          code: :terminal_cleanup_failed,
          event_id: terminal_event_id(running_entry)
        }

        state =
          block_issue_from_entry(
            state,
            issue_id,
            Map.put(running_entry, :terminal_storage_failure, failure),
            "terminal lifecycle cleanup failed: #{stable_terminal_error(reason)}",
            :terminal_storage_failure
          )

        latch_lifecycle_storage_fault(state, failure)
    end
  end

  defp settle_running_terminal_lifecycle(issue, running_entry) do
    workspace =
      Map.get(running_entry, :workspace_path) ||
        Path.join(Config.local_workspace_root(), Workspace.workspace_key(issue))

    running_entry = Map.put(running_entry, :workspace_path, workspace)

    case SymphonyElixir.TerminalFailure.recovery_state(workspace, issue.id) do
      :none ->
        normalize_workspace_cleanup(cleanup_issue_workspace_strict(issue, running_entry))

      {disposition, evidence} when disposition in [:settled, :ambiguous] ->
        running_entry
        |> Map.put(:terminal_failure, evidence)
        |> then(&cleanup_terminal_issue_lifecycle(issue, &1))

      {:storage_fault, failure} ->
        running_entry
        |> Map.put(:terminal_storage_failure, failure)
        |> then(&cleanup_terminal_issue_lifecycle(issue, &1))

      {:error, reason} ->
        {:error, {:terminal_recovery_read_failed, reason}}
    end
  end

  defp release_terminated_running_issue(state, issue_id, cancellation_reason) do
    %{
      state
      | running: Map.delete(state.running, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        attempts:
          if(cancellation_reason == "stall_timeout",
            do: state.attempts,
            else: Map.delete(state.attempts, issue_id)
          )
    }
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.agent_stall_timeout_ms()

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      if terminal_failure_blocker?(running_entry) do
        state
      else
        restart_or_block_stalled_issue(
          state,
          issue_id,
          running_entry,
          elapsed_ms,
          identifier,
          session_id
        )
      end
    else
      state
    end
  end

  defp restart_or_block_stalled_issue(
         state,
         issue_id,
         running_entry,
         elapsed_ms,
         identifier,
         session_id
       ) do
    cond do
      input_required_blocker?(running_entry) ->
        error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(issue_id, running_entry, error)

      resumed_attempt?(running_entry) ->
        Logger.warning(
          "Resumed writer stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; verifying native cleanup before terminal settlement"
        )

        stop_running_task(running_entry.pid, running_entry.ref, state.task_supervisor)
        state = record_session_completion_totals(state, running_entry)

        case verify_resumed_native_cleanup(running_entry, :worker_stalled) do
          :ok ->
            settle_resumed_attempt(
              state,
              issue_id,
              running_entry,
              :worker_stalled,
              "resumed writer stalled before successful settlement"
            )

          {:error, cleanup_reason} ->
            fail_resumed_native_cleanup(state, issue_id, running_entry, cleanup_reason)
        end

      true ->
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

        next_attempt = next_retry_attempt_from_running(running_entry)

        metadata =
          retry_metadata_from_entry(running_entry, %{
            error: "stalled for #{elapsed_ms}ms without codex activity"
          })

        state
        |> terminate_running_issue(issue_id, false, "stall_timeout")
        |> schedule_issue_retry(issue_id, next_attempt, metadata)
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminal_storage_failure_blocker?(%{terminal_storage_failure: %{code: code}})
       when is_atom(code) or is_binary(code),
       do: true

  defp terminal_storage_failure_blocker?(_running_entry), do: false

  defp terminal_failure_blocker?(%{terminal_failure: evidence}) when is_map(evidence),
    do: SymphonyElixir.TerminalFailure.valid?(evidence)

  defp terminal_failure_blocker?(_running_entry), do: false

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid, task_supervisor) when is_pid(pid) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid, _task_supervisor), do: :ok

  defp stop_running_task(pid, ref, task_supervisor) do
    if is_pid(pid) do
      terminate_task(pid, task_supervisor)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error) do
    stop_running_task(
      Map.get(running_entry, :pid),
      Map.get(running_entry, :ref),
      state.task_supervisor
    )

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp block_issue_from_entry(
         %State{} = state,
         issue_id,
         running_entry,
         reason,
         disposition \\ :input_required
       ) do
    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: running_entry_session_id(running_entry),
      backend: Map.get(running_entry, :backend),
      disposition: disposition,
      recovery_state: if(disposition == :terminal_failure, do: :settled),
      reason: reason,
      error: if(disposition == :input_required, do: reason),
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp),
      terminal_failure: Map.get(running_entry, :terminal_failure),
      terminal_storage_failure: Map.get(running_entry, :terminal_storage_failure),
      binding: Map.get(running_entry, :binding),
      binding_id: Map.get(running_entry, :binding_id),
      retry_attempt: Map.get(running_entry, :retry_attempt, 0)
    }

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp block_issue_from_retry(%State{} = state, issue_id, metadata, :attempt_limit_hold) do
    count = issue_attempt_count(state, issue_id)
    limit = Config.max_attempts_per_issue()

    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(metadata, :identifier, issue_id),
      issue: Map.get(metadata, :issue),
      worker_host: Map.get(metadata, :worker_host),
      workspace_path: Map.get(metadata, :workspace_path),
      session_id: Map.get(metadata, :session_id),
      backend: Map.get(metadata, :backend),
      disposition: :attempt_limit_hold,
      reason: "attempt limit reached (#{count}/#{limit})",
      error: nil,
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil,
      terminal_failure: Map.get(metadata, :terminal_failure),
      binding: Map.get(metadata, :binding),
      binding_id: binding_id(Map.get(metadata, :binding))
    }

    %{
      state
      | retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    Enum.all?([id, identifier, title, state_name], &present_string?/1) and
      issue_identifier_allowed?(identifier) and
      issue_routable?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp issue_identifier_allowed?(identifier), do: Config.issue_identifier_allowed?(identifier)

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(
         %State{} = state,
         issue,
         attempt \\ nil,
         preferred_worker_host \\ nil,
         binding \\ nil,
         workspace_path \\ nil
       ) do
    workspace =
      workspace_path || Path.join(Config.local_workspace_root(), Workspace.workspace_key(issue))

    case SymphonyElixir.TerminalFailure.recovery_state(workspace, issue.id) do
      :none ->
        dispatch_issue_without_terminal_marker(
          state,
          issue,
          attempt,
          preferred_worker_host,
          binding,
          workspace_path
        )

      {:settled, evidence} ->
        recover_terminal_failure(state, issue, workspace, evidence, :settled)

      {:ambiguous, evidence} ->
        recover_terminal_failure(state, issue, workspace, evidence, :ambiguous)

      {:storage_fault, failure} ->
        recover_terminal_storage_fault(state, issue, workspace, failure)

      {:error, reason} ->
        recover_invalid_terminal_failure(state, issue, workspace, reason)
    end
  end

  defp dispatch_issue_without_terminal_marker(
         state,
         issue,
         attempt,
         preferred_worker_host,
         binding,
         workspace_path
       ) do
    case refresh_issue_for_dispatch(issue) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(
          state,
          refreshed_issue,
          attempt,
          preferred_worker_host,
          binding,
          workspace_path
        )

      {:skip, _reason} ->
        state

      {:error, _reason} ->
        state
    end
  end

  defp recover_terminal_failure(state, issue, workspace, evidence, recovery_state) do
    with true <- evidence.issue_id == issue.id,
         true <- evidence.issue_identifier == issue.identifier,
         {:ok, recorded_workspace} <-
           Workspace.open_recorded_for_issue(evidence.workspace, issue, nil) do
      reason =
        case recovery_state do
          :settled -> "recovered settled terminal failure: #{evidence.reason}"
          :ambiguous -> "recovered ambiguous terminal resume; external decision required"
        end

      Logger.warning(
        "Holding recovered terminal attempt issue_id=#{issue.id} issue_identifier=#{issue.identifier} terminal_reason=#{evidence.reason} event_id=#{evidence.event_id} recovery_state=#{recovery_state}"
      )

      blocked_entry = %{
        issue_id: issue.id,
        identifier: issue.identifier,
        issue: issue,
        worker_host: nil,
        workspace_path: recorded_workspace,
        session_id: evidence.session_id,
        backend: evidence.backend,
        disposition: :terminal_failure,
        recovery_state: recovery_state,
        reason: reason,
        error: nil,
        blocked_at: DateTime.utc_now(),
        last_codex_message: nil,
        last_codex_event: :terminal_failure,
        last_codex_timestamp: nil,
        terminal_failure: evidence,
        binding: nil,
        binding_id: evidence.binding_id,
        retry_attempt: Map.get(evidence, :public_attempt, evidence.attempt || 0)
      }

      %{
        state
        | claimed: MapSet.put(state.claimed, issue.id),
          blocked: Map.put(state.blocked, issue.id, blocked_entry),
          attempts: Map.put_new(state.attempts, issue.id, max((evidence.attempt || 0) + 1, 1))
      }
    else
      _reason -> recover_invalid_terminal_failure(state, issue, workspace, :identity_mismatch)
    end
  end

  defp recover_terminal_storage_fault(state, issue, workspace, failure) do
    blocked_entry = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: Map.get(failure, :workspace, workspace),
      session_id: nil,
      backend: Config.settings!().agent.backend,
      disposition: :terminal_storage_failure,
      recovery_state: :storage_fault,
      reason: "terminal lifecycle storage requires operator repair",
      error: nil,
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil,
      terminal_failure: nil,
      terminal_storage_failure: Map.take(failure, [:code, :event_id]),
      binding: nil,
      binding_id: nil
    }

    state = %{
      state
      | claimed: MapSet.put(state.claimed, issue.id),
        blocked: Map.put(state.blocked, issue.id, blocked_entry)
    }

    latch_lifecycle_storage_fault(state, Map.take(failure, [:code, :event_id]))
  end

  defp recover_invalid_terminal_failure(state, issue, workspace, reason) do
    Logger.warning("Holding issue with unreadable terminal receipt issue_id=#{issue.id} issue_identifier=#{issue.identifier} workspace=#{workspace} reason=#{inspect(reason)}")

    blocked_entry = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: workspace,
      session_id: nil,
      backend: Config.settings!().agent.backend,
      disposition: :terminal_failure_recovery,
      recovery_state: :invalid,
      reason: "terminal recovery evidence is invalid or mismatched",
      error: nil,
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil,
      terminal_failure: nil,
      terminal_storage_failure: nil,
      binding: nil,
      binding_id: nil
    }

    %{
      state
      | claimed: MapSet.put(state.claimed, issue.id),
        blocked: Map.put(state.blocked, issue.id, blocked_entry)
    }
  end

  defp refresh_issue_for_dispatch(issue) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issues_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        {:ok, refreshed_issue}

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        {:skip, :missing}

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        {:skip, refreshed_issue}

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_dispatch_issue(
         %State{lifecycle_storage_fault: fault} = state,
         _issue,
         _attempt,
         _preferred_worker_host,
         _binding,
         _workspace_path
       )
       when not is_nil(fault),
       do: state

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, binding, workspace_path) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, binding, workspace_path)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, binding, workspace_path) do
    if issue_identifier_allowed?(issue.identifier) do
      spawn_allowed_issue_on_worker_host(state, issue, attempt, recipient, worker_host, binding, workspace_path)
    else
      Logger.warning("Skipping agent spawn; issue identifier is not allowed: #{issue_context(issue)}")
      state
    end
  end

  defp spawn_allowed_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, binding, workspace_path) do
    case reserve_issue_attempt(state, issue) do
      {:ok, state} ->
        writer_attempt = max(issue_attempt_count(state, issue.id) - 1, 0)

        spawn_reserved_issue_on_worker_host(
          state,
          issue,
          attempt,
          writer_attempt,
          recipient,
          worker_host,
          binding,
          workspace_path
        )

      {:exhausted, state} ->
        block_issue_from_retry(state, issue.id, %{issue: issue, identifier: issue.identifier}, :attempt_limit_hold)
    end
  end

  defp spawn_reserved_issue_on_worker_host(
         %State{} = state,
         issue,
         attempt,
         writer_attempt,
         recipient,
         worker_host,
         binding,
         workspace_path
       ) do
    backend_name = binding_backend_name(binding, Config.settings!().agent.backend)
    writer_id = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           AgentRunner.run(
             issue,
             recipient,
             attempt: attempt,
             writer_attempt: writer_attempt,
             writer_id: writer_id,
             worker_host: worker_host,
             backend: backend_name,
             binding: binding,
             predecessor_event_id: Map.get(binding || %{}, :predecessor_event_id),
             workspace_path: workspace_path
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            backend: backend_name,
            binding: binding,
            binding_id: binding_id(binding),
            worker_host: worker_host,
            workspace_path: workspace_path,
            session_id: nil,
            terminal_failure: nil,
            terminal_storage_failure: nil,
            resume_handoff: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            last_assistant_text: nil,
            codex_app_server_pid: nil,
            backend_command: nil,
            stderr_path: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            writer_attempt: writer_attempt,
            writer_id: writer_id,
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host,
          binding: binding,
          workspace_path: workspace_path
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp reserve_issue_attempt(%State{} = state, %Issue{id: issue_id}) when is_binary(issue_id) do
    if attempt_budget_exhausted?(state, issue_id) do
      {:exhausted, state}
    else
      {:ok, %{state | attempts: Map.update(state.attempts, issue_id, 1, &(&1 + 1))}}
    end
  end

  defp attempt_budget_exhausted?(%State{} = state, issue_id) when is_binary(issue_id) do
    case Config.max_attempts_per_issue() do
      limit when is_integer(limit) -> issue_attempt_count(state, issue_id) >= limit
      nil -> false
    end
  end

  defp issue_attempt_count(%State{} = state, issue_id) do
    Map.get(state.attempts, issue_id, 0)
  end

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    if attempt_budget_exhausted?(state, issue_id) do
      block_issue_from_retry(state, issue_id, metadata, :attempt_limit_hold)
    else
      schedule_unlimited_issue_retry(state, issue_id, attempt, metadata)
    end
  end

  defp schedule_unlimited_issue_retry(%State{} = state, issue_id, attempt, metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    backend = pick_retry_runtime_value(previous_retry, metadata, :backend)
    session_id = pick_retry_runtime_value(previous_retry, metadata, :session_id)
    binding = pick_retry_runtime_value(previous_retry, metadata, :binding)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue_url: issue_url,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            backend: backend,
            session_id: session_id,
            binding: binding,
            binding_id: binding_id(binding)
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          backend: Map.get(retry_entry, :backend),
          session_id: Map.get(retry_entry, :session_id),
          binding: Map.get(retry_entry, :binding)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_issues_by_ids([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue, metadata)
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(issue_or_identifier, metadata) when is_map(metadata) do
    case Map.get(metadata, :workspace_path) do
      workspace_path when is_binary(workspace_path) and workspace_path != "" ->
        Workspace.remove_recorded(workspace_path, Map.get(metadata, :worker_host))

      _ ->
        cleanup_issue_workspace(issue_or_identifier, Map.get(metadata, :worker_host))
    end
  end

  defp cleanup_issue_workspace(%Issue{} = issue, worker_host) do
    Workspace.remove_issue_workspaces(issue, worker_host)
  end

  defp cleanup_issue_workspace_strict(issue_or_identifier, metadata) when is_map(metadata) do
    case Map.get(metadata, :workspace_path) do
      workspace_path when is_binary(workspace_path) and workspace_path != "" ->
        Workspace.remove_recorded_for_issue(
          workspace_path,
          issue_or_identifier,
          Map.get(metadata, :worker_host)
        )

      _other ->
        Workspace.remove_issue_workspaces_strict(
          issue_or_identifier,
          Map.get(metadata, :worker_host)
        )
    end
  end

  defp cleanup_issue_workspace_strict(issue_or_identifier, worker_host),
    do: Workspace.remove_issue_workspaces_strict(issue_or_identifier, worker_host)

  defp cleanup_terminal_issue_lifecycle(%Issue{} = issue, metadata) do
    workspace_path = Map.get(metadata, :workspace_path)
    evidence = Map.get(metadata, :terminal_failure)
    storage_failure = Map.get(metadata, :terminal_storage_failure)

    case normalize_workspace_cleanup(cleanup_issue_workspace_strict(issue, metadata)) do
      :ok ->
        clear_terminal_lifecycle_marker(
          workspace_path,
          issue.id,
          evidence,
          storage_failure
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_workspace_cleanup(:ok), do: :ok
  defp normalize_workspace_cleanup({:ok, _removed}), do: :ok
  defp normalize_workspace_cleanup({:error, _reason, _output} = error), do: {:error, error}

  defp clear_terminal_lifecycle_marker(workspace, issue_id, evidence, storage_failure) do
    event_id =
      case storage_failure do
        %{event_id: event_id} when is_binary(event_id) -> event_id
        _other -> Map.get(evidence || %{}, :event_id)
      end

    if is_binary(event_id) do
      SymphonyElixir.TerminalFailure.settle_lifecycle(workspace, issue_id, event_id)
    else
      :ok
    end
  end

  defp terminal_event_id(metadata) do
    case Map.get(metadata, :terminal_failure) do
      %{event_id: event_id} when is_binary(event_id) -> event_id
      _other -> nil
    end
  end

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        Enum.reduce_while(issues, :ok, &cleanup_startup_terminal_issue_reducer/2)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
        :ok
    end
  end

  defp cleanup_startup_terminal_issue_reducer(%Issue{} = issue, :ok) do
    case cleanup_startup_terminal_issue(issue) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp cleanup_startup_terminal_issue_reducer(_other, :ok), do: {:cont, :ok}

  defp cleanup_startup_terminal_issue(%Issue{} = issue) do
    case SymphonyElixir.TerminalFailure.recovery_state_for_issue(issue.id) do
      :none ->
        normalize_workspace_cleanup(cleanup_issue_workspace_strict(issue, nil))

      {disposition, evidence} when disposition in [:settled, :ambiguous] ->
        cleanup_startup_terminal_evidence(issue, evidence)

      {:storage_fault, failure} ->
        cleanup_startup_storage_fault(issue, failure)

      {:error, reason} ->
        {:error, {:terminal_recovery_read_failed, reason}}
    end
  end

  defp cleanup_startup_storage_fault(issue, failure) do
    workspace = Map.fetch!(failure, :workspace)
    event_id = Map.fetch!(failure, :event_id)

    case normalize_workspace_cleanup(Workspace.remove_recorded_for_issue(workspace, issue, nil)) do
      :ok -> SymphonyElixir.TerminalFailure.settle_lifecycle(workspace, issue.id, event_id)
      {:error, _reason} = error -> error
    end
  end

  defp cleanup_startup_terminal_evidence(issue, evidence) do
    case normalize_workspace_cleanup(Workspace.remove_recorded_for_issue(evidence.workspace, issue, nil)) do
      :ok ->
        clear_startup_terminal_evidence(issue, evidence)

      {:error, _reason} = error ->
        error
    end
  end

  defp clear_startup_terminal_evidence(issue, evidence) do
    case SymphonyElixir.TerminalFailure.settle_lifecycle(
           evidence.workspace,
           issue.id,
           evidence.event_id
         ) do
      :ok -> normalize_workspace_cleanup(cleanup_issue_workspace_strict(issue, nil))
      {:error, _reason} = error -> error
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      case refresh_issue_for_dispatch(issue) do
        {:ok, %Issue{} = refreshed_issue} ->
          {:noreply,
           dispatch_issue(
             state,
             refreshed_issue,
             attempt,
             metadata[:worker_host],
             metadata[:binding],
             metadata[:workspace_path]
           )}

        {:skip, :missing} ->
          {:noreply, release_issue_claim(state, issue.id)}

        {:skip, %Issue{} = refreshed_issue} ->
          handle_retry_issue_lookup(refreshed_issue, state, issue.id, attempt, metadata)

        {:error, reason} ->
          {:noreply,
           schedule_issue_retry(
             state,
             issue.id,
             attempt + 1,
             Map.merge(metadata, %{
               identifier: issue.identifier,
               error: "retry dispatch refresh failed: #{inspect(reason)}"
             })
           )}
      end
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        attempts: Map.delete(state.attempts, issue_id)
    }
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_runtime_value(previous_retry, metadata, key) do
    Map.get(metadata, key) || Map.get(previous_retry, key)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  defp prepare_terminal_resume(%State{} = state, issue_id, binding) do
    with {:ok, blocked_entry} <- fetch_terminal_block(state, issue_id),
         :ok <- validate_terminal_resume_lifecycle(state, issue_id, blocked_entry),
         :ok <- validate_terminal_resume_evidence(blocked_entry),
         {:ok, normalized_binding} <- validate_terminal_resume_binding(blocked_entry, binding) do
      public_attempt = max(Map.get(blocked_entry, :retry_attempt, 0), 0) + 1
      prior_writer_attempt = Map.get(blocked_entry.terminal_failure, :attempt) || 0
      writer_attempt = max(issue_attempt_count(state, issue_id), prior_writer_attempt + 1)

      case validate_terminal_resume_capacity(state, issue_id, blocked_entry, writer_attempt) do
        :ok -> {:ok, blocked_entry, normalized_binding, public_attempt, writer_attempt}
        {:error, _reason} = error -> error
      end
    end
  end

  defp fetch_terminal_block(state, issue_id) do
    case Map.get(state.blocked, issue_id) do
      nil -> {:error, :terminal_resume_not_blocked}
      blocked_entry -> {:ok, blocked_entry}
    end
  end

  defp validate_terminal_resume_lifecycle(state, issue_id, blocked_entry) do
    cond do
      state.lifecycle_storage_fault != nil ->
        {:error, :terminal_resume_lifecycle_storage_unavailable}

      Map.get(blocked_entry, :disposition) != :terminal_failure ->
        {:error, :terminal_resume_wrong_disposition}

      Map.has_key?(state.running, issue_id) ->
        {:error, :terminal_resume_writer_still_running}

      Map.has_key?(state.retry_attempts, issue_id) ->
        {:error, :terminal_resume_retry_already_scheduled}

      Map.get(blocked_entry, :recovery_state) == :ambiguous ->
        {:error, :terminal_resume_recovery_ambiguous}

      true ->
        :ok
    end
  end

  defp validate_terminal_resume_evidence(blocked_entry) do
    cond do
      not match?(%Issue{}, Map.get(blocked_entry, :issue)) ->
        {:error, :terminal_resume_issue_missing}

      not is_binary(Map.get(blocked_entry, :workspace_path)) ->
        {:error, :terminal_resume_workspace_missing}

      not SymphonyElixir.TerminalFailure.valid?(Map.get(blocked_entry, :terminal_failure)) ->
        {:error, :terminal_resume_evidence_invalid}

      not terminal_receipt_matches?(blocked_entry) ->
        {:error, :terminal_resume_receipt_unavailable}

      true ->
        :ok
    end
  end

  defp validate_terminal_resume_capacity(state, issue_id, blocked_entry, writer_attempt) do
    cond do
      terminal_resume_attempt_budget_exhausted?(state, issue_id, writer_attempt) ->
        {:error, :terminal_resume_attempt_budget_exhausted}

      not dispatch_slots_available?(blocked_entry.issue, state) ->
        {:error, :terminal_resume_no_dispatch_capacity}

      not worker_slots_available?(state, Map.get(blocked_entry, :worker_host)) ->
        {:error, :terminal_resume_no_worker_capacity}

      not issue_identifier_allowed?(blocked_entry.issue.identifier) ->
        {:error, :terminal_resume_identifier_revoked}

      true ->
        :ok
    end
  end

  defp terminal_resume_attempt_budget_exhausted?(state, issue_id, writer_attempt) do
    attempt_budget_exhausted?(state, issue_id) or
      case Config.max_attempts_per_issue() do
        limit when is_integer(limit) -> writer_attempt >= limit
        _other -> false
      end
  end

  defp validate_terminal_resume_binding(blocked_entry, binding) do
    case AgentBackend.preflight_launch_binding(
           Map.get(blocked_entry, :backend),
           binding,
           Map.get(blocked_entry, :workspace_path),
           Config.settings!()
         ) do
      {:ok, normalized_binding} -> {:ok, normalized_binding}
      {:error, reason} -> {:error, {:terminal_resume_binding_invalid, reason}}
    end
  end

  defp terminal_receipt_matches?(blocked_entry) do
    expected = Map.get(blocked_entry, :terminal_failure)

    case SymphonyElixir.TerminalFailure.recovery_state(
           Map.get(blocked_entry, :workspace_path),
           expected.issue_id
         ) do
      {:settled, %{event_id: event_id}} -> event_id == expected.event_id
      _ -> false
    end
  end

  defp resume_terminal_issue(
         state,
         issue,
         blocked_entry,
         binding,
         public_attempt,
         writer_attempt,
         from
       ) do
    evidence = Map.fetch!(blocked_entry, :terminal_failure)

    case SymphonyElixir.TerminalFailure.record_resume(
           blocked_entry.workspace_path,
           evidence,
           binding.binding_id,
           writer_attempt
         ) do
      {:ok, receipt_path} ->
        candidate_state = %{
          state
          | blocked: Map.delete(state.blocked, issue.id),
            attempts: Map.put(state.attempts, issue.id, writer_attempt)
        }

        resume_binding = Map.put(binding, :predecessor_event_id, evidence.event_id)

        next_state =
          do_dispatch_issue(
            candidate_state,
            issue,
            public_attempt,
            Map.get(blocked_entry, :worker_host),
            resume_binding,
            blocked_entry.workspace_path
          )

        if Map.has_key?(next_state.running, issue.id) do
          token = make_ref()
          timer_ref = Process.send_after(self(), {:resume_handoff_timeout, issue.id, token}, @resume_handoff_timeout_ms)

          response = %{
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            prior_event_id: evidence.event_id,
            binding_id: binding.binding_id,
            backend: binding.backend,
            workspace_path: blocked_entry.workspace_path,
            attempt: public_attempt,
            writer_attempt: writer_attempt,
            disposition: :running,
            receipt_path: receipt_path
          }

          handoff = %{
            status: :pending,
            from: from,
            token: token,
            timer_ref: timer_ref,
            response: response,
            blocked_entry: blocked_entry
          }

          running_entry =
            next_state.running
            |> Map.fetch!(issue.id)
            |> Map.put(:resume_handoff, handoff)

          Logger.info(
            "Waiting for native writer proof after terminal resume issue_id=#{issue.id} issue_identifier=#{issue.identifier} prior_event_id=#{evidence.event_id} binding_id=#{binding.binding_id} public_attempt=#{public_attempt} writer_attempt=#{writer_attempt}"
          )

          {:noreply, %{next_state | running: Map.put(next_state.running, issue.id, running_entry)}}
        else
          next_state = cancel_issue_retry(next_state, issue.id)
          ambiguous = Map.put(blocked_entry, :recovery_state, :ambiguous)
          blocked = Map.put(next_state.blocked, issue.id, ambiguous)

          {:reply, {:error, :terminal_resume_dispatch_ambiguous}, %{next_state | blocked: blocked, claimed: MapSet.put(next_state.claimed, issue.id)}}
        end

      {:error, reason} ->
        Logger.warning(
          "Rejected terminal resume because authorization receipt was not durable issue_id=#{issue.id} issue_identifier=#{issue.identifier} binding_id=#{binding.binding_id} error=#{inspect(stable_terminal_error(reason))}"
        )

        failed_state = mark_resume_ambiguous_if_durable(state, issue.id, blocked_entry)

        {:reply, {:error, {:terminal_resume_receipt_failed, stable_terminal_error(reason)}}, failed_state}
    end
  end

  defp pending_resume_handoff?(running_entry),
    do: match?(%{status: :pending}, Map.get(running_entry, :resume_handoff))

  defp maybe_complete_resume_handoff(state, issue_id, %{event: :session_started}) do
    case get_in(state.running, [issue_id, :resume_handoff]) do
      %{status: :pending, from: from, timer_ref: timer_ref, response: response} = handoff ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, {:ok, response})

        running_entry =
          state.running
          |> Map.fetch!(issue_id)
          |> Map.put(:resume_handoff, %{handoff | status: :proven})
          |> Map.put(:terminal_failure, nil)

        Logger.info("Proved native writer handoff after terminal resume issue_id=#{issue_id} binding_id=#{response.binding_id} prior_event_id=#{response.prior_event_id}")

        %{state | running: Map.put(state.running, issue_id, running_entry)}

      _other ->
        state
    end
  end

  defp maybe_complete_resume_handoff(state, _issue_id, _update), do: state

  defp fail_pending_resume_agent_down(state, issue_id, running_entry) do
    state =
      if terminal_storage_failure_blocker?(running_entry) do
        latch_lifecycle_storage_fault(state, Map.fetch!(running_entry, :terminal_storage_failure))
      else
        state
      end

    complete_pending_resume_failure(
      state,
      issue_id,
      running_entry,
      :terminal_resume_writer_not_proven
    )
  end

  defp fail_pending_resume(state, issue_id, token, reason) do
    case Map.get(state.running, issue_id) do
      %{resume_handoff: %{status: :pending, token: ^token}, pid: pid, ref: ref} = running_entry ->
        stop_running_task(pid, ref, state.task_supervisor)
        complete_pending_resume_failure(state, issue_id, running_entry, reason)

      _other ->
        state
    end
  end

  defp complete_pending_resume_failure(state, issue_id, running_entry, reason) do
    handoff = Map.fetch!(running_entry, :resume_handoff)
    Process.cancel_timer(handoff.timer_ref)
    GenServer.reply(handoff.from, {:error, reason})

    if terminal_failure_blocker?(running_entry) do
      block_issue_from_entry(
        state,
        issue_id,
        running_entry,
        "resumed native process settled with a terminal failure before writer proof",
        :terminal_failure
      )
    else
      blocked_entry =
        handoff.blocked_entry
        |> Map.put(:recovery_state, :ambiguous)
        |> Map.put(:reason, "terminal resume intent is ambiguous because no native writer was proven")

      %{
        state
        | running: Map.delete(state.running, issue_id),
          retry_attempts: Map.delete(state.retry_attempts, issue_id),
          blocked: Map.put(state.blocked, issue_id, blocked_entry),
          claimed: MapSet.put(state.claimed, issue_id)
      }
    end
  end

  defp cancel_issue_retry(state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{timer_ref: timer_ref} when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      _other -> :ok
    end

    %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
  end

  defp mark_resume_ambiguous_if_durable(state, issue_id, blocked_entry) do
    case SymphonyElixir.TerminalFailure.recovery_state(
           blocked_entry.workspace_path,
           issue_id
         ) do
      {:ambiguous, _evidence} ->
        blocked =
          Map.update!(state.blocked, issue_id, &Map.put(&1, :recovery_state, :ambiguous))

        %{state | blocked: blocked}

      {:storage_fault, failure} ->
        blocked =
          Map.update!(state.blocked, issue_id, fn entry ->
            entry
            |> Map.put(:disposition, :terminal_storage_failure)
            |> Map.put(:recovery_state, :storage_fault)
            |> Map.put(:terminal_storage_failure, Map.take(failure, [:code, :event_id]))
          end)

        state
        |> Map.put(:blocked, blocked)
        |> latch_lifecycle_storage_fault(Map.take(failure, [:code, :event_id]))

      _other ->
        state
    end
  end

  defp stable_terminal_error(reason) when is_atom(reason), do: reason
  defp stable_terminal_error({reason, _details}) when is_atom(reason), do: reason
  defp stable_terminal_error({reason, _first, _second}) when is_atom(reason), do: reason
  defp stable_terminal_error(_reason), do: :terminal_storage_error

  defp binding_backend_name(%{backend: backend}, _default) when is_atom(backend),
    do: Atom.to_string(backend)

  defp binding_backend_name(_binding, default), do: default

  defp binding_id(%{binding_id: binding_id}) when is_binary(binding_id), do: binding_id
  defp binding_id(_binding), do: nil

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec resume_terminal_attempt(String.t(), map(), GenServer.server()) ::
          {:ok, map()} | {:error, term()} | :unavailable
  def resume_terminal_attempt(issue_id, binding, server \\ __MODULE__)
      when is_binary(issue_id) and is_map(binding) do
    GenServer.call(server, {:resume_terminal_attempt, issue_id, binding}, 15_000)
  catch
    :exit, _reason -> :unavailable
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call({:resume_terminal_attempt, issue_id, binding}, from, state) do
    case prepare_terminal_resume(state, issue_id, binding) do
      {:ok, blocked_entry, normalized_binding, public_attempt, writer_attempt} ->
        case refresh_issue_for_dispatch(blocked_entry.issue) do
          {:ok, %Issue{} = issue} ->
            resume_terminal_issue(
              state,
              issue,
              blocked_entry,
              normalized_binding,
              public_attempt,
              writer_attempt,
              from
            )

          {:skip, reason} ->
            {:reply, {:error, {:terminal_resume_issue_not_dispatchable, reason}}, state}

          {:error, reason} ->
            {:reply, {:error, {:terminal_resume_issue_refresh_failed, reason}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
        |> maybe_put_runtime_value(:backend, Map.get(metadata, :backend))
        |> maybe_put_runtime_value(:backend_process_pid, Map.get(metadata, :backend_process_pid))
        |> maybe_put_runtime_value(:model, Map.get(metadata, :model))
        |> maybe_put_runtime_value(:thinking_level, Map.get(metadata, :thinking_level))
        |> maybe_put_runtime_value(:session_file, Map.get(metadata, :session_file))
        |> maybe_put_runtime_value(:backend_command, Map.get(metadata, :backend_command))
        |> maybe_put_runtime_value(:stderr_path, Map.get(metadata, :stderr_path))
        |> maybe_put_runtime_value(:binding_id, Map.get(metadata, :binding_id))
        |> maybe_put_runtime_value(:terminal_failure, Map.get(metadata, :terminal_failure))
        |> maybe_put_runtime_value(:last_assistant_text, Map.get(metadata, :last_assistant_text))
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
        |> maybe_put_runtime_value(:backend, Map.get(retry, :backend))
        |> maybe_put_runtime_value(:session_id, Map.get(retry, :session_id))
        |> maybe_put_runtime_value(:binding_id, Map.get(retry, :binding_id))
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          disposition: Map.get(metadata, :disposition, :input_required),
          recovery_state: Map.get(metadata, :recovery_state),
          reason: Map.get(metadata, :reason),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event)
        }
        |> maybe_put_runtime_value(:backend, Map.get(metadata, :backend))
        |> maybe_put_runtime_value(:binding_id, Map.get(metadata, :binding_id))
        |> maybe_put_runtime_value(:terminal_failure, Map.get(metadata, :terminal_failure))
        |> maybe_put_runtime_value(
          :terminal_storage_failure,
          Map.get(metadata, :terminal_storage_failure)
        )
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       lifecycle_storage_fault: state.lifecycle_storage_fault,
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    backend_process_pid = Map.get(running_entry, :backend_process_pid)
    model = Map.get(running_entry, :model)
    thinking_level = Map.get(running_entry, :thinking_level)
    session_file = Map.get(running_entry, :session_file)
    backend_command = Map.get(running_entry, :backend_command)
    stderr_path = Map.get(running_entry, :stderr_path)
    terminal_failure = terminal_failure_for_update(Map.get(running_entry, :terminal_failure), update)

    terminal_storage_failure =
      terminal_storage_failure_for_update(
        Map.get(running_entry, :terminal_storage_failure),
        update
      )

    last_assistant_text = assistant_text_for_update(Map.get(running_entry, :last_assistant_text), update)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        backend: backend_for_update(Map.get(running_entry, :backend), update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        backend_process_pid: runtime_value_for_update(backend_process_pid, update, :backend_process_pid),
        model: runtime_value_for_update(model, update, :model),
        thinking_level: runtime_value_for_update(thinking_level, update, :thinking_level),
        session_file: runtime_value_for_update(session_file, update, :session_file),
        backend_command: runtime_value_for_update(backend_command, update, :backend_command),
        stderr_path: runtime_value_for_update(stderr_path, update, :stderr_path),
        terminal_failure: terminal_failure,
        terminal_storage_failure: terminal_storage_failure,
        last_assistant_text: last_assistant_text,
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp terminal_failure_for_update(nil, %{
         event: :terminal_failure,
         terminal_failure: evidence,
         terminal_failure_persisted: true
       })
       when is_map(evidence),
       do: evidence

  defp terminal_failure_for_update(existing, _update), do: existing

  defp terminal_storage_failure_for_update(nil, %{
         event: :terminal_storage_failure,
         terminal_storage_failure: %{code: code} = failure
       })
       when is_atom(code) or is_binary(code),
       do: Map.take(failure, [:code, :event_id])

  defp terminal_storage_failure_for_update(existing, _update), do: existing

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp backend_for_update(_existing, %{backend: backend}) when is_atom(backend), do: backend
  defp backend_for_update(existing, _update), do: existing

  defp runtime_value_for_update(existing, update, key) do
    case Map.get(update, key) do
      nil -> existing
      value -> value
    end
  end

  defp assistant_text_for_update(_existing, %{event: :session_started}), do: nil

  defp assistant_text_for_update(_existing, %{assistant_text: text}) when is_binary(text),
    do: bounded_assistant_text(text)

  defp assistant_text_for_update(existing, %{assistant_text_delta: delta}) when is_binary(delta) do
    bounded_assistant_text((existing || "") <> delta)
  end

  defp assistant_text_for_update(existing, _update), do: existing

  defp bounded_assistant_text(text) when is_binary(text) and byte_size(text) > @assistant_text_bytes do
    binary_part(text, byte_size(text) - @assistant_text_bytes, @assistant_text_bytes)
  end

  defp bounded_assistant_text(text) when is_binary(text), do: text
  defp bounded_assistant_text(_text), do: nil

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    state = %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }

    release_config_revoked_holds(state)
  end

  defp release_config_revoked_holds(%State{} = state) do
    state.blocked
    |> Enum.reduce(state, fn {issue_id, blocked_entry}, state_acc ->
      if hold_released_by_config?(state_acc, issue_id, blocked_entry) do
        Logger.info("Releasing hold after config change: issue_id=#{issue_id}")
        release_config_hold(state_acc, issue_id)
      else
        state_acc
      end
    end)
  end

  defp hold_released_by_config?(_state, _issue_id, %{disposition: :normal_completion_hold}) do
    not Config.hold_after_normal_completion?()
  end

  defp hold_released_by_config?(state, issue_id, %{disposition: :attempt_limit_hold}) do
    not attempt_budget_exhausted?(state, issue_id)
  end

  defp hold_released_by_config?(_state, _issue_id, _blocked_entry), do: false

  defp release_config_hold(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &direct_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp direct_token_usage_from_payload(payload) when is_map(payload) do
    if integer_token_map?(payload), do: payload
  end

  defp direct_token_usage_from_payload(_payload), do: nil

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
