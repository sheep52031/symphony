defmodule SymphonyElixir.StopFile do
  @moduledoc """
  Operator stop switch (JARVIS-3792): a `STOP` file in the local workspace root means "dispatch no new issues".

  Runs already in flight are not touched. The check needs no tracker, so it keeps working when Linear is down.
  Nothing calls it yet; the dispatch and dashboard call sites are left to JARVIS-3793.
  """

  alias SymphonyElixir.Config

  @spec path() :: Path.t()
  def path, do: Path.join(Config.local_workspace_root(), "STOP")

  @spec stopped?() :: boolean()
  def stopped?, do: File.exists?(path())
end
