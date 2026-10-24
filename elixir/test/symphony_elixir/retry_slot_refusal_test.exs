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
      running: %{"other" => %{identifier: "JARVIS-1", issue: %Issue{id: "other", state: "In Progress"}, pid: self()}},
      retry_attempts: %{},
      attempts: %{issue.id => 1}
    }
  end

  defp refuse(state, issue, attempt) do
    Orchestrator.dispatch_active_retry_for_test(state, issue, attempt, %{
      identifier: issue.identifier,
      backend: "codex",
      backend_route_explicit?: false
    })
  end

  test "slot refusals keep the retry attempt and never spend the attempt budget" do
    issue = issue()
    state = full_state(issue)

    final =
      Enum.reduce(1..30, state, fn _, acc ->
        next = refuse(acc, issue, acc.retry_attempts[issue.id][:attempt] || 2)
        Process.cancel_timer(next.retry_attempts[issue.id].timer_ref)
        next
      end)

    assert final.retry_attempts[issue.id].attempt == 2
    assert final.retry_attempts[issue.id].error == "no available orchestrator slots"
    assert final.attempts[issue.id] == 1
  end

  test "slot refusal delay stays at the attempt's backoff instead of climbing to the cap" do
    issue = issue()
    state = full_state(issue)

    after_many =
      Enum.reduce(1..10, state, fn _, acc ->
        next = refuse(acc, issue, acc.retry_attempts[issue.id][:attempt] || 2)
        Process.cancel_timer(next.retry_attempts[issue.id].timer_ref)
        next
      end)

    entry = after_many.retry_attempts[issue.id]
    remaining = entry.due_at_ms - System.monotonic_time(:millisecond)
    # attempt 2 => 10s * 2^1 = 20s; before the fix the 10th refusal was capped at 300s
    assert remaining > 0 and remaining <= 20_000
  end

  test "failure backoff doubles per attempt and caps at max_retry_backoff_ms past the boundary" do
    write_workflow_file!(Workflow.workflow_file_path(), max_retry_backoff_ms: 300_000)

    delays = Enum.map(1..8, &Orchestrator.failure_retry_delay_for_test/1)
    assert delays == [10_000, 20_000, 40_000, 80_000, 160_000, 300_000, 300_000, 300_000]
    # the exponent saturates at 2^10, far past the cap, without overflow
    assert Orchestrator.failure_retry_delay_for_test(500) == 300_000
  end
end
