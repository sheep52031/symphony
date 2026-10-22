defmodule SymphonyElixir.StateExtras do
  @moduledoc """
  Optional `/api/v1/state` fields (JARVIS-3796), kept out of the presenter so it only calls two functions.

    * `stopped_fields/0` adds `stopped: true|false` when `agent.stop_file_enabled` is on.
    * `put_attempt_fields/2` adds `last_line` and `diagnostic_tail` (from `VerifyGate.attempt_fields/2`) to an
      attempt entry when `agent.attempt_fields_enabled` is on.

  With both flags off (the default) the payload is unchanged.
  """

  alias SymphonyElixir.{Config, StopFile, VerifyGate}

  @spec stopped_fields() :: %{optional(:stopped) => boolean()}
  def stopped_fields do
    if Config.stop_file_enabled?(), do: %{stopped: StopFile.stopped?()}, else: %{}
  end

  @spec put_attempt_fields(map(), String.t() | nil) :: map()
  def put_attempt_fields(payload, identifier) when is_map(payload) and is_binary(identifier) do
    if Config.attempt_fields_enabled?(), do: Map.merge(payload, VerifyGate.attempt_fields(identifier)), else: payload
  end

  def put_attempt_fields(payload, _identifier) when is_map(payload), do: payload
end
