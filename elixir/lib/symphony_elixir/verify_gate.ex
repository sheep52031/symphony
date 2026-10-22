defmodule SymphonyElixir.VerifyGate do
  @moduledoc """
  Post-run verification gate (JARVIS-3792).

  `scripts/verify-run.sh` (the `hooks.after_run` hook) writes a `verify.json` record after every attempt. When
  `agent.verify_gate_enabled` is `true` the orchestrator asks this module, on a normal agent exit, whether that
  record allows the issue to complete. Anything but a fresh, real, passing record fails closed.

  The record path is `agent.verify_record_path` with `<issue>` replaced by the issue identifier; a relative path
  is resolved against the local workspace root. The record must have been written by the same
  `VERIFY_RUNS_DIR` the hook uses.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Client}

  @type fact :: %{name: String.t(), ok: boolean(), detail: String.t()}

  @missing_detail "閘門未產出"
  @dry_run_detail "乾跑不算通過"
  @comment_mutation "mutation($issueId: String!, $body: String!) { commentCreate(input: {issueId: $issueId, body: $body}) { success } }"

  @doc """
  Resolves the verify record path for an issue identifier.
  """
  @spec record_path(String.t(), keyword()) :: Path.t()
  def record_path(identifier, opts \\ []) when is_binary(identifier) do
    template = Keyword.get_lazy(opts, :record_path, fn -> Config.settings!().agent.verify_record_path end)
    root = Keyword.get_lazy(opts, :workspace_root, &Config.local_workspace_root/0)
    safe_identifier = String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

    template
    |> String.replace("<issue>", safe_identifier)
    |> Path.expand(root)
  end

  @doc """
  Reads the verify record and decides whether the run may complete.

  Options: `:record_path`, `:workspace_root` (see `record_path/2`) and `:not_before` (a `DateTime`; a record
  checked before it belongs to an earlier attempt and fails).
  """
  @spec check(String.t(), keyword()) :: :pass | {:fail, [fact()]}
  def check(identifier, opts \\ []) when is_binary(identifier) do
    case File.read(record_path(identifier, opts)) do
      {:ok, content} -> content |> Jason.decode() |> evaluate(Keyword.get(opts, :not_before))
      {:error, :enoent} -> {:fail, [fact("verify_json", false, @missing_detail)]}
      {:error, reason} -> {:fail, [fact("verify_json", false, "無法讀取 verify.json: #{:file.format_error(reason)}")]}
    end
  end

  @doc """
  Orchestrator entry point for a normal exit: `nil` lets the run complete, a string is the hold reason.

  A failing gate also posts a fact comment to the issue (Linear trackers only, best effort).
  """
  @spec hold_reason(map(), String.t(), (String.t(), map() -> {:ok, map()} | {:error, term()})) :: String.t() | nil
  def hold_reason(running_entry, issue_id, graphql_fun \\ &Client.graphql/2) when is_map(running_entry) do
    identifier = Map.get(running_entry, :identifier) || issue_id

    case check(identifier, not_before: Map.get(running_entry, :started_at)) do
      :pass ->
        nil

      {:fail, facts} ->
        Logger.warning("Verify gate held normal completion issue_id=#{issue_id} issue_identifier=#{identifier}: #{summary(facts)}")
        notify(issue_id, comment_body(facts, record_path(identifier)), graphql_fun)
        "normal completion held by agent.verify_gate_enabled: #{summary(facts)}"
    end
  end

  @doc """
  Fixed-format fact comment, signed `🤖 Symphony`.
  """
  @spec comment_body([fact()], Path.t()) :: String.t()
  def comment_body(facts, record_path) when is_list(facts) do
    rows = Enum.map_join(facts, "\n", fn fact -> "| #{fact.name} | #{if fact.ok, do: "pass", else: "FAIL"} | #{cell(fact.detail)} |" end)

    """
    ## Symphony verify gate: HELD (normal completion not accepted)

    | Fact | Result | Detail |
    | --- | --- | --- |
    #{rows}

    Record: `#{record_path}`. The runtime read this record after the attempt; the worker's own "done" was not accepted.
    The issue stays held until the operator releases it.

    🤖 Symphony
    """
  end

  @doc """
  Last worker lines recorded by the gate, for the attempt record: `last_line` and `diagnostic_tail`.
  """
  @spec attempt_fields(String.t(), keyword()) :: %{last_line: String.t() | nil, diagnostic_tail: String.t() | nil}
  def attempt_fields(identifier, opts \\ []) when is_binary(identifier) do
    with {:ok, content} <- File.read(record_path(identifier, opts)),
         {:ok, %{} = record} <- Jason.decode(content) do
      tail = nonblank(record["worker_tail"]) || nonblank(get_in(record, ["tests", "tail"]))
      %{last_line: tail && tail |> String.split("\n", trim: true) |> List.last(), diagnostic_tail: tail}
    else
      _ -> %{last_line: nil, diagnostic_tail: nil}
    end
  end

  @doc false
  @spec post_comment(String.t(), String.t(), (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          :ok | {:error, term()}
  def post_comment(issue_id, body, graphql_fun) do
    case graphql_fun.(@comment_mutation, %{issueId: issue_id, body: body}) do
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}} -> :ok
      other -> {:error, other}
    end
  end

  defp evaluate({:ok, %{} = record}, not_before) do
    facts = record |> Map.get("facts") |> normalize_facts()

    problems =
      stale_problem(record, not_before) ++
        dry_run_problem(record) ++
        verdict_problem(record, facts)

    if problems == [] and Enum.all?(facts, & &1.ok), do: :pass, else: {:fail, facts ++ problems}
  end

  defp evaluate({:ok, _other}, _not_before), do: {:fail, [fact("verify_json", false, "verify.json 不是 JSON 物件")]}
  defp evaluate({:error, error}, _not_before), do: {:fail, [fact("verify_json", false, "verify.json 無法解析: #{Exception.message(error)}")]}

  defp stale_problem(_record, nil), do: []

  defp stale_problem(record, %DateTime{} = not_before) do
    with checked_at when is_binary(checked_at) <- record["checked_at"],
         {:ok, checked_at, _offset} <- DateTime.from_iso8601(checked_at) do
      if DateTime.compare(checked_at, DateTime.truncate(not_before, :second)) == :lt,
        do: [fact("fresh", false, "verify.json 早於本次 run（checked_at #{DateTime.to_iso8601(checked_at)}）")],
        else: []
    else
      _ -> [fact("fresh", false, "verify.json 缺少可解析的 checked_at")]
    end
  end

  defp dry_run_problem(%{"dry_run" => true}), do: [fact("dry_run", false, @dry_run_detail)]
  defp dry_run_problem(_record), do: []

  defp verdict_problem(%{"verdict" => "pass"}, []), do: [fact("verdict", false, "verdict pass 但沒有任何事實")]
  defp verdict_problem(%{"verdict" => "pass"}, _facts), do: []

  defp verdict_problem(%{"verdict" => verdict}, facts) do
    if Enum.all?(facts, & &1.ok), do: [fact("verdict", false, "verdict #{inspect(verdict)}")], else: []
  end

  defp verdict_problem(_record, _facts), do: [fact("verdict", false, "缺少 verdict")]

  defp normalize_facts(facts) when is_list(facts) do
    facts
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn item -> fact(to_string(item["name"] || "?"), item["ok"] == true, to_string(item["detail"] || "")) end)
  end

  defp normalize_facts(_facts), do: []

  defp fact(name, ok, detail), do: %{name: name, ok: ok, detail: detail}

  defp summary(facts) do
    facts |> Enum.reject(& &1.ok) |> Enum.map_join("; ", fn fact -> "#{fact.name} (#{fact.detail})" end)
  end

  defp cell(detail), do: detail |> String.replace(["|", "\n"], " ") |> String.slice(0, 200)

  defp nonblank(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp nonblank(_value), do: nil

  defp notify(issue_id, body, graphql_fun) do
    if Config.settings!().tracker.kind == "linear", do: Task.start(fn -> log_comment_failure(issue_id, body, graphql_fun) end)
    :ok
  end

  defp log_comment_failure(issue_id, body, graphql_fun) do
    with {:error, reason} <- post_comment(issue_id, body, graphql_fun) do
      Logger.warning("Verify gate comment failed issue_id=#{issue_id}: #{inspect(reason)}")
    end
  end
end
