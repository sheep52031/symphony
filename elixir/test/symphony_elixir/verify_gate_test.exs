defmodule SymphonyElixir.VerifyGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{StopFile, VerifyGate}

  @identifier "JARVIS-3792"

  setup do
    root = Path.join(System.tmp_dir!(), "verify-gate-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root)
    {:ok, root: root}
  end

  defp record(overrides \\ %{}) do
    Map.merge(
      %{
        "verdict" => "pass",
        "issue" => @identifier,
        "facts" => [%{"name" => "clean_tree", "ok" => true, "detail" => "clean"}, %{"name" => "tests", "ok" => true, "detail" => "exit 0"}],
        "dry_run" => false,
        "tests" => %{"tail" => "..."},
        "worker_tail" => "first\nlast worker line\n",
        "checked_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      },
      overrides
    )
  end

  defp write_record!(root, map_or_text, identifier \\ @identifier) do
    path = Path.join([root, "runs", identifier, "verify.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, if(is_binary(map_or_text), do: map_or_text, else: Jason.encode!(map_or_text)))
    path
  end

  defp failing_facts, do: [%{"name" => "tests", "ok" => false, "detail" => "exit 1"}]

  describe "check/2" do
    test "a fresh real passing record lets the run complete", %{root: root} do
      write_record!(root, record())
      assert VerifyGate.check(@identifier) == :pass
    end

    test "a failing record blocks and carries the facts", %{root: root} do
      write_record!(root, record(%{"verdict" => "fail", "facts" => failing_facts()}))
      assert {:fail, facts} = VerifyGate.check(@identifier)
      assert %{name: "tests", ok: false, detail: "exit 1"} in facts
    end

    test "an unreadable record blocks with the reason", %{root: root} do
      root |> Path.join("runs/#{@identifier}/verify.json") |> File.mkdir_p!()
      assert {:fail, [%{name: "verify_json", detail: "無法讀取 verify.json: " <> _}]} = VerifyGate.check(@identifier)
    end

    test "facts that are not a list count as no facts", %{root: root} do
      write_record!(root, record(%{"facts" => "oops"}))
      assert {:fail, [%{name: "verdict"}]} = VerifyGate.check(@identifier)
    end

    test "a missing record blocks", %{root: _root} do
      assert {:fail, [%{name: "verify_json", ok: false, detail: "閘門未產出"}]} = VerifyGate.check(@identifier)
    end

    test "a dry run never counts as a pass", %{root: root} do
      write_record!(root, record(%{"dry_run" => true}))
      assert {:fail, facts} = VerifyGate.check(@identifier)
      assert %{name: "dry_run", ok: false, detail: "乾跑不算通過"} in facts
    end

    test "broken JSON and non-object JSON block with a reason", %{root: root} do
      write_record!(root, "{not json")
      assert {:fail, [%{name: "verify_json", detail: "verify.json 無法解析: " <> _}]} = VerifyGate.check(@identifier)

      write_record!(root, "[1, 2]")
      assert {:fail, [%{name: "verify_json", detail: "verify.json 不是 JSON 物件"}]} = VerifyGate.check(@identifier)
    end

    test "a pass verdict with a failing or missing fact blocks", %{root: root} do
      write_record!(root, record(%{"facts" => failing_facts()}))
      assert {:fail, [%{name: "tests", ok: false}]} = VerifyGate.check(@identifier)

      write_record!(root, record(%{"facts" => []}))
      assert {:fail, [%{name: "verdict"}]} = VerifyGate.check(@identifier)

      write_record!(root, Map.delete(record(), "verdict"))
      assert {:fail, facts} = VerifyGate.check(@identifier)
      assert Enum.any?(facts, &(&1.name == "verdict"))
    end

    test "a record older than the run is stale and blocks", %{root: root} do
      write_record!(root, record(%{"checked_at" => "2020-01-01T00:00:00Z"}))
      assert :pass = VerifyGate.check(@identifier)
      assert {:fail, facts} = VerifyGate.check(@identifier, not_before: DateTime.utc_now())
      assert Enum.any?(facts, &(&1.name == "fresh" and not &1.ok))

      write_record!(root, Map.delete(record(), "checked_at"))
      assert {:fail, facts} = VerifyGate.check(@identifier, not_before: DateTime.utc_now())
      assert Enum.any?(facts, &(&1.name == "fresh" and not &1.ok))
    end
  end

  describe "record_path/2" do
    test "fills the template and resolves relative paths against the workspace root", %{root: root} do
      assert VerifyGate.record_path("A-1") == Path.join([root, "runs", "A-1", "verify.json"])
      assert VerifyGate.record_path("A-1", record_path: "x/<issue>/v.json") == Path.join([root, "x", "A-1", "v.json"])
    end

    test "keeps absolute templates and sanitizes the identifier" do
      assert VerifyGate.record_path("A-1", record_path: "/srv/runs/<issue>/verify.json") == "/srv/runs/A-1/verify.json"
      assert VerifyGate.record_path("../x/y", record_path: "/srv/<issue>/v.json") == "/srv/.._x_y/v.json"
    end

    test "agent.verify_record_path is configurable", %{root: root} do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: root,
        verify_record_path: "gate/<issue>.json"
      )

      assert VerifyGate.record_path("A-1") == Path.join([root, "gate", "A-1.json"])
    end
  end

  describe "config" do
    test "the gate is off by default and the record path has a default", %{root: root} do
      refute Config.verify_gate_enabled?()
      assert Config.settings!().agent.verify_record_path == "runs/<issue>/verify.json"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: root,
        verify_gate_enabled: true
      )

      assert Config.verify_gate_enabled?()
    end
  end

  describe "comment_body/2" do
    test "has a fixed format and the signature" do
      body = VerifyGate.comment_body([%{name: "tests", ok: false, detail: "exit 1 | a\nb"}, %{name: "pushed", ok: true, detail: "ok"}], "/r/verify.json")

      assert body =~ "## Symphony verify gate: HELD (normal completion not accepted)"
      assert body =~ "| tests | FAIL | exit 1   a b |"
      assert body =~ "| pushed | pass | ok |"
      assert body =~ "Record: `/r/verify.json`"
      assert String.ends_with?(body, "🤖 Symphony\n")
    end

    test "post_comment/3 sends the issue id and the body" do
      test_pid = self()

      fake = fn query, vars ->
        send(test_pid, {:graphql, query, vars})
        {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
      end

      assert :ok = VerifyGate.post_comment("uuid-1", "body", fake)
      assert_received {:graphql, "mutation" <> _, %{issueId: "uuid-1", body: "body"}}
      assert {:error, _} = VerifyGate.post_comment("uuid-1", "body", fn _, _ -> {:error, :boom} end)
    end
  end

  describe "hold_reason/3" do
    test "posts the fact comment to a linear tracker and logs a failed post", %{root: root} do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", workspace_root: root)
      test_pid = self()

      fake = fn _query, vars ->
        send(test_pid, {:comment, vars})
        {:error, :boom}
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert "normal completion held by agent.verify_gate_enabled: verify_json (閘門未產出)" =
                   VerifyGate.hold_reason(%{identifier: @identifier}, "issue-uuid", fake)

          assert_receive {:comment, %{issueId: "issue-uuid", body: "## Symphony verify gate: HELD" <> _}}
          Process.sleep(100)
        end)

      assert log =~ "Verify gate comment failed issue_id=issue-uuid"
    end

    test "returns nil for a passing record", %{root: root} do
      write_record!(root, record())
      assert VerifyGate.hold_reason(%{identifier: @identifier}, "issue-uuid") == nil
    end
  end

  describe "attempt_fields/2" do
    test "returns the worker tail and its last line", %{root: root} do
      write_record!(root, record())
      assert %{last_line: "last worker line", diagnostic_tail: "first\nlast worker line\n"} = VerifyGate.attempt_fields(@identifier)
    end

    test "falls back to the test tail and tolerates a missing record", %{root: root} do
      assert %{last_line: nil, diagnostic_tail: nil} = VerifyGate.attempt_fields(@identifier)
      write_record!(root, record(%{"worker_tail" => "", "tests" => %{"tail" => "a\nb"}}))
      assert %{last_line: "b", diagnostic_tail: "a\nb"} = VerifyGate.attempt_fields(@identifier)
      write_record!(root, record() |> Map.delete("worker_tail") |> Map.put("tests", %{"tail" => "t"}))
      assert %{last_line: "t", diagnostic_tail: "t"} = VerifyGate.attempt_fields(@identifier)
    end
  end

  describe "StopFile" do
    test "is stopped only while STOP exists in the workspace root", %{root: root} do
      refute StopFile.stopped?()
      File.write!(Path.join(root, "STOP"), "")
      assert StopFile.path() == Path.join(root, "STOP")
      assert StopFile.stopped?()
      File.rm!(Path.join(root, "STOP"))
      refute StopFile.stopped?()
    end
  end

  describe "orchestrator normal completion" do
    defp complete_normally(identifier, started_at \\ DateTime.utc_now()) do
      issue_id = "issue-#{identifier}"
      name = Module.concat(__MODULE__, :"Orchestrator#{System.unique_integer([:positive])}")
      {:ok, pid} = Orchestrator.start_link(name: name)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

      issue = %Issue{id: issue_id, identifier: identifier, state: "In Progress", url: "https://example.org/#{identifier}", dispatchable: true}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      ref = make_ref()
      initial = :sys.get_state(pid)

      :sys.replace_state(pid, fn _ ->
        initial
        |> Map.put(:running, %{
          issue_id => %{
            pid: self(),
            ref: ref,
            identifier: identifier,
            issue: issue,
            session_id: "s",
            started_at: started_at
          }
        })
        |> Map.put(:claimed, MapSet.put(initial.claimed, issue_id))
      end)

      send(pid, {:DOWN, ref, :process, self(), :normal})
      Process.sleep(50)
      {:sys.get_state(pid), issue_id}
    end

    defp gate_on(root, extra \\ []) do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge([tracker_kind: "memory", workspace_root: root, verify_gate_enabled: true, hold_after_normal_completion: true], extra)
      )
    end

    test "gate off: a failing record is ignored and the old path runs", %{root: root} do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root)
      write_record!(root, record(%{"verdict" => "fail", "facts" => failing_facts()}))

      {state, issue_id} = complete_normally(@identifier)

      refute Map.has_key?(state.blocked, issue_id)
      assert %{attempt: 1} = state.retry_attempts[issue_id]
    end

    test "gate off with hold: still the plain normal-completion hold", %{root: root} do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: root,
        hold_after_normal_completion: true
      )

      {state, issue_id} = complete_normally(@identifier)

      assert state.blocked[issue_id].reason == "normal completion held by agent.hold_after_normal_completion"
    end

    test "gate on: a failing record holds the issue with the facts as reason", %{root: root} do
      gate_on(root)
      write_record!(root, record(%{"verdict" => "fail", "facts" => failing_facts()}))

      {state, issue_id} = complete_normally(@identifier)

      assert %{disposition: :normal_completion_hold, reason: reason} = state.blocked[issue_id]
      assert reason == "normal completion held by agent.verify_gate_enabled: tests (exit 1)"
      refute Map.has_key?(state.retry_attempts, issue_id)
      assert MapSet.member?(state.claimed, issue_id)
    end

    test "gate on: a missing record holds the issue", %{root: root} do
      gate_on(root)
      {state, issue_id} = complete_normally(@identifier)
      assert state.blocked[issue_id].reason =~ "閘門未產出"
    end

    test "gate on: a dry run holds the issue", %{root: root} do
      gate_on(root)
      write_record!(root, record(%{"dry_run" => true}))
      {state, issue_id} = complete_normally(@identifier)
      assert state.blocked[issue_id].reason =~ "乾跑不算通過"
    end

    test "gate on: a record from before this run holds the issue", %{root: root} do
      gate_on(root)
      write_record!(root, record(%{"checked_at" => "2020-01-01T00:00:00Z"}))
      {state, issue_id} = complete_normally(@identifier)
      assert state.blocked[issue_id].reason =~ "早於本次 run"
    end

    test "gate on: a passing record falls through to the existing flow", %{root: root} do
      gate_on(root, hold_after_normal_completion: false)
      write_record!(root, record())

      {state, issue_id} = complete_normally(@identifier)

      refute Map.has_key?(state.blocked, issue_id)
      assert %{attempt: 1} = state.retry_attempts[issue_id]
    end

    test "gate on with hold: a passing record is still held by the existing hold", %{root: root} do
      gate_on(root)
      write_record!(root, record())

      {state, issue_id} = complete_normally(@identifier)

      assert state.blocked[issue_id].reason == "normal completion held by agent.hold_after_normal_completion"
    end
  end
end
