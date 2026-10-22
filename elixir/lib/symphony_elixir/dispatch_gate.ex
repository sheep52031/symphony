defmodule SymphonyElixir.DispatchGate do
  @moduledoc """
  Pre-dispatch checks that need no orchestrator state, in one call so the orchestrator's dispatch predicate gains
  a single `and` (JARVIS-3796, `docs/upstream-drift.md` 4.5).

  The STOP file is asked first: while it blocks dispatch, the dispatch lint must not comment on tickets.
  """

  alias SymphonyElixir.{DispatchLint, StopFile}
  alias SymphonyElixir.Tracker.Issue

  @spec allowed?(Issue.t()) :: boolean()
  def allowed?(%Issue{} = issue), do: not StopFile.dispatch_blocked?() and DispatchLint.dispatch_allowed?(issue)
end
