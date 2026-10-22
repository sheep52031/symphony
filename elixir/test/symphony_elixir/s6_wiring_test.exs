defmodule SymphonyElixir.S6WiringTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{StateExtras, StopFile, VerifyGateRework}

  @endpoint SymphonyElixirWeb.Endpoint
  @identifier "JARVIS-3796"

  defmodule FakeLinearClient do
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issues_by_ids(_ids), do: {:ok, Application.get_env(:symphony_elixir, :memory_tracker_issues, [])}

    def graphql(query, variables, _opts \\ []) do
      pid = Application.fetch_env!(:symphony_elixir, :s6_wiring_test_pid)
      send(pid, {:graphql, query, variables})

      cond do
        Application.get_env(:symphony_elixir, :s6_wiring_fail_move) && String.contains?(query, "SymphonyGateMoveIssue") ->
          {:error, :boom}

        String.contains?(query, "SymphonyGateStateId") ->
          {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-#{variables[:name]}"}]}}}}}}

        String.contains?(query, "issueUpdate") ->
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}

        true ->
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "s6-wiring-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}")
    File.mkdir_p!(root)
    Application.put_env(:symphony_elixir, :s6_wiring_test_pid, self())
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    on_exit(fn ->
      File.rm_rf(root)
      Application.delete_env(:symphony_elixir, :s6_wiring_test_pid)
      Application.delete_env(:symphony_elixir, :s6_wiring_fail_move)
      Application.delete_env(:symphony_elixir, :linear_client_module)
    end)

    {:ok, root: root}
  end

  defp workflow!(root, extra \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge([tracker_kind: "memory", workspace_root: root, tracker_active_states: ["Todo", "In Progress", "Rework"]], extra)
    )
  end

  defp linear_workflow!(root, extra) do
    workflow!(root, Keyword.merge([tracker_kind: "linear", verify_gate_enabled: true, verify_gate_rework_enabled: true], extra))
  end

  defp write_record!(root, overrides \\ %{}) do
    record =
      Map.merge(
        %{
          "verdict" => "fail",
          "facts" => [%{"name" => "tests", "ok" => false, "detail" => "exit 1"}],
          "dry_run" => false,
          "tests" => %{"tail" => "t1\nt2"},
          "worker_tail" => "w1\nlast worker line\n",
          "checked_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        },
        overrides
      )

    path = Path.join([root, "runs", @identifier, "verify.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(record))
  end

  defp stop!(root), do: File.write!(Path.join(root, "STOP"), "")

  defp issue(id \\ "issue-s6", identifier \\ @identifier) do
    %Issue{id: id, identifier: identifier, title: identifier, state: "In Progress", url: "https://example.org/#{identifier}", dispatchable: true, branch_name: "b-#{id}"}
  end

  defp orchestrator_state do
    %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp start_orchestrator! do
    name = Module.concat(__MODULE__, :"Orchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    {name, pid}
  end

  defp start_endpoint!(orchestrator) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 1_000)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp complete_normally(attempts) do
    {name, pid} = start_orchestrator!()
    issue = issue()
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    ref = make_ref()
    initial = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial
      |> Map.put(:running, %{
        issue.id => %{pid: self(), ref: ref, identifier: issue.identifier, issue: issue, session_id: "s", started_at: DateTime.utc_now() |> DateTime.add(-5)}
      })
      |> Map.put(:claimed, MapSet.put(initial.claimed, issue.id))
      |> Map.put(:attempts, %{issue.id => attempts})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    {name, :sys.get_state(pid), issue.id}
  end

  describe "config" do
    test "all three S6 flags default to off", %{root: root} do
      workflow!(root)
      refute Config.stop_file_enabled?()
      refute Config.attempt_fields_enabled?()
      refute Config.verify_gate_rework_enabled?()

      workflow!(root, stop_file_enabled: true, attempt_fields_enabled: true, verify_gate_rework_enabled: true)
      assert Config.stop_file_enabled?()
      assert Config.attempt_fields_enabled?()
      assert Config.verify_gate_rework_enabled?()
    end
  end

  describe "agent.stop_file_enabled" do
    test "off: a STOP file changes nothing", %{root: root} do
      workflow!(root)
      stop!(root)

      assert StopFile.stopped?()
      refute StopFile.dispatch_blocked?()
      assert Orchestrator.should_dispatch_issue_for_test(issue(), orchestrator_state())
      assert StateExtras.stopped_fields() == %{}
    end

    test "on: dispatch is blocked while STOP exists and resumes when it is removed", %{root: root} do
      workflow!(root, stop_file_enabled: true)

      assert Orchestrator.should_dispatch_issue_for_test(issue(), orchestrator_state())
      assert StateExtras.stopped_fields() == %{stopped: false}

      stop!(root)
      assert StopFile.dispatch_blocked?()
      refute Orchestrator.should_dispatch_issue_for_test(issue(), orchestrator_state())
      assert StateExtras.stopped_fields() == %{stopped: true}

      File.rm!(Path.join(root, "STOP"))
      assert Orchestrator.should_dispatch_issue_for_test(issue(), orchestrator_state())
    end

    test "off: /api/v1/state has no stopped key and the dashboard shows no banner", %{root: root} do
      workflow!(root)
      stop!(root)
      {name, _pid} = start_orchestrator!()
      start_endpoint!(name)

      refute Map.has_key?(json_response(get(build_conn(), "/api/v1/state"), 200), "stopped")
      {:ok, _view, html} = live(build_conn(), "/")
      refute html =~ "STOP file present"
    end

    test "on: /api/v1/state and the dashboard report stopped", %{root: root} do
      workflow!(root, stop_file_enabled: true)
      {name, _pid} = start_orchestrator!()
      start_endpoint!(name)

      assert %{"stopped" => false} = json_response(get(build_conn(), "/api/v1/state"), 200)
      {:ok, _view, html} = live(build_conn(), "/")
      refute html =~ "STOP file present"

      stop!(root)
      assert %{"stopped" => true} = json_response(get(build_conn(), "/api/v1/state"), 200)
      {:ok, _view, html} = live(build_conn(), "/")
      assert html =~ "STOP file present"
    end
  end

  describe "agent.attempt_fields_enabled" do
    defp with_retry_entry(pid) do
      :sys.replace_state(pid, fn state ->
        due_at_ms = System.monotonic_time(:millisecond) + 5_000
        entry = %{attempt: 2, due_at_ms: due_at_ms, identifier: @identifier, error: "boom"}
        %{state | retry_attempts: Map.put(state.retry_attempts, "issue-s6", entry)}
      end)
    end

    test "off: attempt entries keep their old shape", %{root: root} do
      workflow!(root)
      write_record!(root)
      {name, pid} = start_orchestrator!()
      with_retry_entry(pid)
      start_endpoint!(name)

      assert %{"retrying" => [entry]} = json_response(get(build_conn(), "/api/v1/state"), 200)
      refute Map.has_key?(entry, "last_line")
      refute Map.has_key?(entry, "diagnostic_tail")
      assert StateExtras.put_attempt_fields(%{a: 1}, @identifier) == %{a: 1}
    end

    test "on: retrying and held entries carry last_line and diagnostic_tail from verify.json", %{root: root} do
      workflow!(root, attempt_fields_enabled: true)
      write_record!(root)
      {name, pid} = start_orchestrator!()
      with_retry_entry(pid)
      start_endpoint!(name)

      assert %{"retrying" => [entry]} = json_response(get(build_conn(), "/api/v1/state"), 200)
      assert entry["last_line"] == "last worker line"
      assert entry["diagnostic_tail"] == "w1\nlast worker line\n"
    end

    test "on: a missing record gives nil fields and a non-binary identifier is left alone", %{root: root} do
      workflow!(root, attempt_fields_enabled: true)

      assert StateExtras.put_attempt_fields(%{a: 1}, @identifier) == %{a: 1, last_line: nil, diagnostic_tail: nil}
      assert StateExtras.put_attempt_fields(%{a: 1}, nil) == %{a: 1}
    end
  end

  describe "agent.verify_gate_rework_enabled" do
    test "off: a failing gate holds the issue exactly as JARVIS-3792 did, and Linear is not touched", %{root: root} do
      workflow!(root, verify_gate_enabled: true, hold_after_normal_completion: true, max_attempts_per_issue: 3)
      write_record!(root)

      {_name, state, issue_id} = complete_normally(3)

      assert %{disposition: :normal_completion_hold, reason: "normal completion held by agent.verify_gate_enabled: tests (exit 1)"} =
               state.blocked[issue_id]

      refute_received {:graphql, _, _}
    end

    test "on, attempts left: comments, moves the issue to Rework and continues", %{root: root} do
      linear_workflow!(root, max_attempts_per_issue: 3)
      write_record!(root)

      {_name, state, issue_id} = complete_normally(1)

      refute Map.has_key?(state.blocked, issue_id)
      assert %{attempt: 1} = state.retry_attempts[issue_id]
      assert state.attempts[issue_id] == 1

      assert_received {:graphql, "mutation" <> _, %{issueId: "issue-s6", body: body}}
      assert body =~ "轉 Rework（第 1/3 次）"
      assert body =~ "| tests | FAIL | exit 1 |"
      assert String.ends_with?(body, "🤖 Symphony\n")
      assert_received {:graphql, _, %{issueId: "issue-s6", name: "Rework"}}
      assert_received {:graphql, _, %{issueId: "issue-s6", stateId: "state-Rework"}}
    end

    test "on, attempt limit reached: comments, moves to Human Review and holds as attempt_limit_hold", %{root: root} do
      linear_workflow!(root, max_attempts_per_issue: 3)
      write_record!(root)

      {_name, state, issue_id} = complete_normally(3)

      assert %{disposition: :attempt_limit_hold, reason: reason} = state.blocked[issue_id]
      assert reason =~ "attempt limit reached (3/3)"
      refute Map.has_key?(state.retry_attempts, issue_id)

      assert_received {:graphql, "mutation" <> _, %{issueId: "issue-s6", body: body}}
      assert body =~ "已達嘗試上限（3/3），轉 Human Review"
      assert_received {:graphql, _, %{issueId: "issue-s6", name: "Human Review"}}
      assert_received {:graphql, _, %{issueId: "issue-s6", stateId: "state-Human Review"}}
    end

    test "on, passing gate: nothing is posted and the normal flow runs", %{root: root} do
      workflow!(root, tracker_kind: "linear", verify_gate_enabled: true, verify_gate_rework_enabled: true)
      write_record!(root, %{"verdict" => "pass", "facts" => [%{"name" => "tests", "ok" => true, "detail" => "ok"}]})

      {_name, state, issue_id} = complete_normally(1)

      refute Map.has_key?(state.blocked, issue_id)
      assert %{attempt: 1} = state.retry_attempts[issue_id]
      refute_received {:graphql, _, _}
    end

    test "on, tracker is not Linear: fails closed with the JARVIS-3792 hold", %{root: root} do
      workflow!(root, verify_gate_enabled: true, verify_gate_rework_enabled: true, hold_after_normal_completion: true)
      write_record!(root)

      {_name, state, issue_id} = complete_normally(1)

      assert %{disposition: :normal_completion_hold} = state.blocked[issue_id]
      refute_received {:graphql, _, _}
    end

    test "on, the Linear move fails: fails closed with the JARVIS-3792 hold", %{root: root} do
      linear_workflow!(root, hold_after_normal_completion: true)
      write_record!(root)
      Application.put_env(:symphony_elixir, :s6_wiring_fail_move, true)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {_name, state, issue_id} = complete_normally(1)
          assert %{disposition: :normal_completion_hold} = state.blocked[issue_id]
        end)

      assert log =~ "Verify gate rework failed"
    end

    test "attempt_limit_hold is released again when the limit is raised", %{root: root} do
      linear_workflow!(root, max_attempts_per_issue: 3)
      write_record!(root)
      {name, state, issue_id} = complete_normally(3)
      assert state.blocked[issue_id].disposition == :attempt_limit_hold

      linear_workflow!(root, max_attempts_per_issue: 10)
      WorkflowStore.force_reload()
      send(Process.whereis(name), :tick)
      Process.sleep(100)

      refute Map.has_key?(:sys.get_state(name).blocked, issue_id)
    end
  end

  test "comment_body/5 has a fixed format for both outcomes" do
    facts = [%{name: "tests", ok: false, detail: "a|b\nc"}, %{name: "pushed", ok: true, detail: "ok"}]

    rework = VerifyGateRework.comment_body(:rework, facts, "/r/verify.json", 2, nil)
    assert rework =~ "轉 Rework（第 2/∞ 次）"
    assert rework =~ "| tests | FAIL | a b c |"
    assert rework =~ "| pushed | pass | ok |"
    assert rework =~ "紀錄：`/r/verify.json`"

    assert VerifyGateRework.comment_body(:limit, facts, "/r/verify.json", 3, 3) =~ "轉 Human Review"
  end
end
