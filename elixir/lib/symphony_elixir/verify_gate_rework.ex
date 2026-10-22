defmodule SymphonyElixir.VerifyGateRework do
  @moduledoc """
  Gate fail → Rework (JARVIS-3796), gated by `agent.verify_gate_rework_enabled` (default `false`).

  `hold/3` is the orchestrator's single call on a normal exit while `agent.verify_gate_enabled` is on. It returns
  `nil` (let the run complete) or `{reason, disposition}` (hold the issue):

    * flag off: exactly the JARVIS-3792 behaviour, `{reason, :normal_completion_hold}` on a failing gate;
    * flag on, gate passes: `nil`;
    * flag on, gate fails, attempts left: a fact comment is posted, the Linear issue moves to `Rework` and `nil`
      is returned, so the orchestrator takes its normal continuation path and the next poll re-dispatches the
      issue (that dispatch counts as the next attempt in `State.attempts`, the same counter
      `agent.max_attempts_per_issue` uses). `Rework` must be listed in `tracker.active_states`;
    * flag on, gate fails, `agent.max_attempts_per_issue` reached: a comment is posted, the issue moves to
      `Human Review` and the hold is `{reason, :attempt_limit_hold}` (released by config when the limit is raised);
    * flag on but the tracker is not Linear, or a Linear call fails: fail closed with the JARVIS-3792 hold.

  Linear calls go through `Application.get_env(:symphony_elixir, :linear_client_module)` like `DispatchLint`.
  """

  require Logger

  alias SymphonyElixir.{Config, VerifyGate}
  alias SymphonyElixir.Linear.Client

  @rework_state "Rework"
  @review_state "Human Review"
  @signature "🤖 Symphony"
  @state_query """
  query SymphonyGateStateId($issueId: String!, $name: String!) {
    issue(id: $issueId) { team { states(filter: {name: {eq: $name}}, first: 1) { nodes { id } } } }
  }
  """
  @update_mutation """
  mutation SymphonyGateMoveIssue($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) { success }
  }
  """

  @spec hold(map(), String.t(), non_neg_integer()) :: {String.t(), atom()} | nil
  def hold(running_entry, issue_id, attempt_count) when is_map(running_entry) do
    if Config.verify_gate_rework_enabled?() do
      identifier = Map.get(running_entry, :identifier) || issue_id

      case VerifyGate.check(identifier, not_before: Map.get(running_entry, :started_at)) do
        :pass -> nil
        {:fail, facts} -> on_fail(facts, running_entry, issue_id, identifier, attempt_count)
      end
    else
      with reason when is_binary(reason) <- VerifyGate.hold_reason(running_entry, issue_id),
           do: {reason, :normal_completion_hold}
    end
  end

  @spec comment_body(:rework | :limit, [VerifyGate.fact()], Path.t(), non_neg_integer(), pos_integer() | nil) :: String.t()
  def comment_body(kind, facts, record_path, attempt_count, limit) do
    rows = Enum.map_join(facts, "\n", fn fact -> "| #{fact.name} | #{if fact.ok, do: "pass", else: "FAIL"} | #{cell(fact.detail)} |" end)

    """
    ## #{headline(kind, attempt_count, limit)}

    | 事實 | 結果 | 說明 |
    | --- | --- | --- |
    #{rows}

    紀錄：`#{record_path}`。worker 自報完成未被接受。#{outcome(kind)}

    #{@signature}
    """
  end

  defp on_fail(facts, running_entry, issue_id, identifier, attempt_count) do
    limit = Config.max_attempts_per_issue()
    kind = if is_integer(limit) and attempt_count >= limit, do: :limit, else: :rework
    target = if kind == :limit, do: @review_state, else: @rework_state
    body = comment_body(kind, facts, VerifyGate.record_path(identifier), attempt_count, limit)

    Logger.warning("Verify gate failed issue_id=#{issue_id} issue_identifier=#{identifier}: moving to #{target} (attempt #{attempt_count}/#{limit || "unlimited"})")

    with true <- Config.settings!().tracker.kind == "linear",
         :ok <- VerifyGate.post_comment(issue_id, body, &graphql/2),
         :ok <- move_issue(issue_id, target) do
      if kind == :limit, do: {"attempt limit reached (#{attempt_count}/#{limit}) after failed verify gate: #{summary(facts)}", :attempt_limit_hold}
    else
      reason ->
        Logger.warning("Verify gate rework failed issue_id=#{issue_id}: #{inspect(reason)}; falling back to a hold")

        with fallback when is_binary(fallback) <- VerifyGate.hold_reason(running_entry, issue_id, &graphql/2),
             do: {fallback, :normal_completion_hold}
    end
  end

  defp move_issue(issue_id, state_name) do
    with {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => state_id} | _]}}}}}} <-
           graphql(@state_query, %{issueId: issue_id, name: state_name}),
         {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}} <-
           graphql(@update_mutation, %{issueId: issue_id, stateId: state_id}) do
      :ok
    else
      other -> {:error, {:move_failed, state_name, other}}
    end
  end

  defp graphql(query, variables), do: client_module().graphql(query, variables)

  defp client_module, do: Application.get_env(:symphony_elixir, :linear_client_module, Client)

  defp headline(:rework, count, limit), do: "Symphony 驗證閘門未通過：轉 Rework（第 #{count}/#{limit || "∞"} 次）"
  defp headline(:limit, count, limit), do: "Symphony 驗證閘門未通過：已達嘗試上限（#{count}/#{limit}），轉 Human Review"

  defp outcome(:rework), do: "票已移到 Rework，由下一次嘗試重做。"
  defp outcome(:limit), do: "票已移到 Human Review，Symphony 不再自動重做，等業主處理。"

  defp summary(facts) do
    facts |> Enum.reject(& &1.ok) |> Enum.map_join("; ", fn fact -> "#{fact.name} (#{fact.detail})" end)
  end

  defp cell(detail), do: detail |> String.replace(["|", "\n"], " ") |> String.slice(0, 200)
end
