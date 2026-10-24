defmodule SymphonyElixir.RetrySlotRefusalTest do
  use SymphonyElixir.TestSupport

  # A capacity refusal on a retry is not a failed attempt: it must not grow the
  # retry attempt (which drives exponential backoff and the attempt handed to
  # the next agent run) nor spend the per-issue attempt budget.

  defp issue do
    %Issue{
      id: "issue-slot",
      identifier: "JARVIS-3832",
      title: "slot refusal",
      state: "In Progress",
      branch_name: "slot-branch",
      url: "https://example.invalid/JARVIS-3832",
      dispatchable: true
    }
  end

  defp full_state(issue) do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "codex",
      max_concurrent_agents: 1,
      max_retry_backoff_ms: 300_000,
      max_attempts_per_issue: 3
    )

    %Orchestrator.State{
      max_concurrent_agents: 1,
      claimed: MapSet.new([issue.id]),
      running: %{
        "other" => %{
          identifier: "JARVIS-1",
          issue: %Issue{id: "other", state: "In Progress"},
          pid: self(),
          session_id: nil,
          codex_app_server_pid: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          started_at: DateTime.utc_now(),
          last_codex_timestamp: nil,
          last_codex_message: nil,
          last_codex_event: nil
        }
      },
      retry_attempts: %{},
      attempts: %{issue.id => 1},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  # Feed the stored refusal count back in, as the retry timer does through pop_retry_attempt_state.
  defp next_refusal(state, issue, attempt) do
    entry = state.retry_attempts[issue.id]
    refusals = if entry, do: entry.capacity_refusals, else: 0

    next =
      Orchestrator.dispatch_active_retry_for_test(state, issue, attempt, %{
        identifier: issue.identifier,
        backend: "codex",
        backend_route_explicit?: false,
        capacity_refusals: refusals
      })

    if entry = next.retry_attempts[issue.id], do: Process.cancel_timer(entry.timer_ref)
    next
  end

  defp remaining_ms(state, issue) do
    state.retry_attempts[issue.id].due_at_ms - System.monotonic_time(:millisecond)
  end

  test "slot refusals keep attempt and budget but back off to the cap" do
    issue = issue()

    {_, delays} =
      Enum.reduce(1..8, {full_state(issue), []}, fn _, {st, acc} ->
        next = next_refusal(st, issue, 5)
        assert next.retry_attempts[issue.id].attempt == 5
        assert next.attempts[issue.id] == 1
        {next, [remaining_ms(next, issue) | acc]}
      end)

    expected = [10_000, 20_000, 40_000, 80_000, 160_000, 300_000, 300_000, 300_000]

    delays
    |> Enum.reverse()
    |> Enum.zip(expected)
    |> Enum.each(fn {actual, cap} -> assert actual > cap - 1_000 and actual <= cap end)
  end

  test "a real failure still advances the attempt and resets the refusal count" do
    issue = issue()
    state = full_state(issue)
    state = Enum.reduce(1..3, state, fn _, st -> next_refusal(st, issue, 5) end)
    assert state.retry_attempts[issue.id].capacity_refusals == 3

    {:ok, sleeper} = Agent.start(fn -> :ok end)
    on_exit(fn -> if Process.alive?(sleeper), do: Process.exit(sleeper, :kill) end)

    running_entry = %{
      pid: sleeper,
      ref: nil,
      identifier: issue.identifier,
      issue: issue,
      backend: "codex",
      backend_route_explicit?: false,
      retry_attempt: 5,
      started_at: DateTime.add(DateTime.utc_now(), -60, :second),
      last_codex_timestamp: DateTime.add(DateTime.utc_now(), -60, :second)
    }

    state = %{state | running: Map.put(state.running, issue.id, running_entry), retry_attempts: %{}}

    retried = Orchestrator.restart_stalled_issue_for_test(state, issue.id, running_entry, DateTime.utc_now(), 10)
    entry = retried.retry_attempts[issue.id]
    Process.cancel_timer(entry.timer_ref)

    assert entry.attempt == 6
    assert entry.capacity_refusals == 0
    assert retried.attempts[issue.id] == 1
  end

  test "consecutive slot refusals past the cap hold the issue without spending the budget" do
    issue = issue()
    state = full_state(issue)

    held =
      Orchestrator.dispatch_active_retry_for_test(state, issue, 5, %{
        identifier: issue.identifier,
        backend: "codex",
        backend_route_explicit?: false,
        capacity_refusals: 24
      })

    assert %{disposition: :capacity_refusal_hold} = held.blocked[issue.id]
    refute Map.has_key?(held.retry_attempts, issue.id)
    assert MapSet.member?(held.claimed, issue.id)
    assert held.attempts[issue.id] == 1

    # the 24th refusal is still retried
    still = next_refusal(state, issue, 5)
    assert still.retry_attempts[issue.id].capacity_refusals == 1
  end

  test "the 24th consecutive refusal is still retried" do
    issue = issue()
    state = full_state(issue)

    next =
      Orchestrator.dispatch_active_retry_for_test(state, issue, 5, %{
        identifier: issue.identifier,
        backend: "codex",
        backend_route_explicit?: false,
        capacity_refusals: 23
      })

    entry = next.retry_attempts[issue.id]
    Process.cancel_timer(entry.timer_ref)
    assert entry.capacity_refusals == 24
    refute Map.has_key?(next.blocked, issue.id)
  end

  test "a capacity hold is released by the periodic refresh once a slot frees up" do
    issue = issue()
    saturated = full_state(issue)

    held =
      Orchestrator.dispatch_active_retry_for_test(saturated, issue, 5, %{
        identifier: issue.identifier,
        backend: "codex",
        backend_route_explicit?: false,
        capacity_refusals: 24
      })

    # still saturated: the periodic refresh keeps the hold
    {:reply, _, still_held} = Orchestrator.handle_call(:snapshot, self(), held)
    assert %{disposition: :capacity_refusal_hold} = still_held.blocked[issue.id]

    # the other agent finished: next refresh releases the hold, budget intact
    {:reply, _, released} = Orchestrator.handle_call(:snapshot, self(), %{still_held | running: %{}})
    refute Map.has_key?(released.blocked, issue.id)
    refute MapSet.member?(released.claimed, issue.id)
    assert released.attempts[issue.id] == 1
  end
end
