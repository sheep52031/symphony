defmodule SymphonyElixir.DispatchLint do
  @moduledoc """
  Pre-dispatch lint: an issue is only dispatched when its description carries every section listed in
  `agent.required_sections`. Gated by `agent.dispatch_lint_enabled` (default `false`); with the flag off
  (or no sections configured) `dispatch_allowed?/1` is always `true` and has no side effects.

  A section is matched against whole lines of the description:

    * a section ending in `:` (for example `Why:`) matches any line that starts with it;
    * any other section (for example `Approval: 已核准`) must equal the whole line. Trailing whitespace
      is ignored; leading whitespace is not (the section must be at the start of the line).

  When sections are missing the issue is skipped and one comment (signed `🤖 Symphony`) lists them. The
  comment is sent once per issue id and description hash, so repeated polls stay quiet until the
  description changes. When the lint passes, the sha256 of the description is remembered so the run can
  later be compared against the ticket it was started from (`recorded_body_hash/1`).

  The module keeps its own ETS table; the orchestrator state is not touched. The table is created by the
  first caller and lives as long as that process (the orchestrator in production).
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.Issue

  @table :symphony_dispatch_lint
  @signature "🤖 Symphony"
  @comment_mutation """
  mutation SymphonyDispatchLintComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) { success }
  }
  """

  @spec dispatch_allowed?(Issue.t()) :: boolean()
  def dispatch_allowed?(%Issue{} = issue) do
    case Config.dispatch_lint_required_sections() do
      [] -> true
      sections -> lint_and_record(issue, sections)
    end
  end

  @spec check(Issue.t() | String.t() | nil, [String.t()]) :: :ok | {:missing, [String.t()]}
  def check(%Issue{description: description}, sections), do: check(description, sections)

  def check(description, sections) when is_list(sections) do
    lines = description |> to_string() |> String.split(~r/\R/u) |> Enum.map(&String.trim_trailing/1)

    case Enum.reject(sections, &section_present?(&1, lines)) do
      [] -> :ok
      missing -> {:missing, missing}
    end
  end

  @spec body_hash(Issue.t() | String.t() | nil) :: String.t()
  def body_hash(%Issue{description: description}), do: body_hash(description)
  def body_hash(description), do: :crypto.hash(:sha256, to_string(description)) |> Base.encode16(case: :lower)

  @spec recorded_body_hash(String.t()) :: String.t() | nil
  def recorded_body_hash(issue_id) do
    lookup({:hash, issue_id})
  end

  @spec skip_reason(String.t()) :: {:missing_sections, [String.t()]} | nil
  def skip_reason(issue_id) do
    lookup({:skip, issue_id})
  end

  @spec comment_body([String.t()]) :: String.t()
  def comment_body(missing) do
    items = Enum.map_join(missing, "\n", &"- `#{&1}`")

    "派工前檢查未通過：票 body 缺少下列段落，Symphony 先不派工。補齊後會自動重新檢查。\n\n" <>
      items <> "\n\n" <> @signature
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  defp lint_and_record(%Issue{id: id} = issue, sections) do
    hash = body_hash(issue)

    case check(issue, sections) do
      :ok ->
        insert({{:hash, id}, hash})
        :ets.delete(table(), {:skip, id})
        true

      {:missing, missing} ->
        insert({{:skip, id}, {:missing_sections, missing}})
        comment_once(issue, hash, missing)
        false
    end
  end

  defp comment_once(%Issue{id: id, identifier: identifier}, hash, missing) do
    key = {:commented, id, hash}

    if lookup(key) == nil do
      Logger.info("Dispatch lint skipped issue_id=#{id} issue_identifier=#{identifier} missing=#{inspect(missing)}")

      case client_module().graphql(@comment_mutation, %{"issueId" => id, "body" => comment_body(missing)}) do
        {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}} -> insert({key, true})
        other -> Logger.warning("Dispatch lint comment failed issue_id=#{id} reason=#{inspect(other)}")
      end
    end

    :ok
  end

  defp section_present?(section, lines) do
    if String.ends_with?(section, ":"),
      do: Enum.any?(lines, &String.starts_with?(&1, section)),
      else: Enum.any?(lines, &(&1 == section))
  end

  defp client_module, do: Application.get_env(:symphony_elixir, :linear_client_module, Client)

  defp lookup(key) do
    case :ets.lookup(table(), key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  defp insert(row), do: :ets.insert(table(), row)

  defp table do
    case :ets.whereis(@table) do
      :undefined -> create_table()
      _ref -> @table
    end
  end

  defp create_table, do: :ets.new(@table, [:named_table, :public, :set])
end
