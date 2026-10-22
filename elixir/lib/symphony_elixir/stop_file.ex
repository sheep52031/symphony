defmodule SymphonyElixir.StopFile do
  @moduledoc """
  Operator stop switch (JARVIS-3792): a `STOP` file in the local workspace root means "dispatch no new issues".

  Runs already in flight are not touched. The check needs no tracker, so it keeps working when Linear is down.
  Wired by JARVIS-3796 behind `agent.stop_file_enabled` (default `false`): the orchestrator's dispatch predicate asks
  `dispatch_blocked?/0`, and `/api/v1/state` plus the dashboard report `stopped`.
  """

  alias SymphonyElixir.Config

  @spec path() :: Path.t()
  def path, do: Path.join(Config.local_workspace_root(), "STOP")

  @spec stopped?() :: boolean()
  def stopped?, do: File.exists?(path())

  @doc """
  Dispatch predicate: `true` only when the flag is on and the STOP file exists.
  """
  @spec dispatch_blocked?() :: boolean()
  def dispatch_blocked?, do: Config.stop_file_enabled?() and stopped?()
end
