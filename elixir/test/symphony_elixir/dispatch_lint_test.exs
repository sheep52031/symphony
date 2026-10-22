defmodule SymphonyElixir.DispatchLintTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DispatchLint

  defmodule FakeLinearClient do
    def graphql(query, variables, _opts \\ []) do
      send(Application.fetch_env!(:symphony_elixir, :dispatch_lint_test_pid), {:graphql, query, variables})
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    end
  end

  @sections ["Why:", "Plan:", "Approval: 已核准"]
  @complete "Why: because\nPlan:\n1. do it\n\nApproval: 已核准\n"

  setup do
    DispatchLint.reset()
    Application.put_env(:symphony_elixir, :dispatch_lint_test_pid, self())
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    on_exit(fn ->
      DispatchLint.reset()
      Application.delete_env(:symphony_elixir, :dispatch_lint_test_pid)
      Application.delete_env(:symphony_elixir, :linear_client_module)
    end)
  end

  describe "check/2" do
    test "accepts a description with every section" do
      assert DispatchLint.check(@complete, @sections) == :ok
      assert DispatchLint.check(%Issue{description: @complete}, @sections) == :ok
    end

    test "lists missing sections in configured order" do
      assert DispatchLint.check("Why: x\n", @sections) == {:missing, ["Plan:", "Approval: 已核准"]}
      assert DispatchLint.check(nil, ["Why:"]) == {:missing, ["Why:"]}
    end

    test "section must start the line" do
      assert DispatchLint.check("see Why: here\n  Plan: indented\n", ["Why:", "Plan:"]) ==
               {:missing, ["Why:", "Plan:"]}
    end

    test "non-colon section must be the whole line" do
      assert DispatchLint.check("Approval: 已核准（待確認）", ["Approval: 已核准"]) ==
               {:missing, ["Approval: 已核准"]}

      assert DispatchLint.check("Approval: 已核准  \r\nnext", ["Approval: 已核准"]) == :ok
    end

    test "empty section list checks nothing" do
      assert DispatchLint.check("", []) == :ok
    end
  end

  test "body_hash is the sha256 hex of the description" do
    expected = :crypto.hash(:sha256, "abc") |> Base.encode16(case: :lower)
    assert DispatchLint.body_hash("abc") == expected
    assert DispatchLint.body_hash(%Issue{description: "abc"}) == expected
    assert DispatchLint.body_hash(nil) == DispatchLint.body_hash("")
  end

  describe "dispatch_allowed?/1 through the orchestrator" do
    test "flag off: nothing is checked, nothing is commented" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      assert Orchestrator.should_dispatch_issue_for_test(issue("a", "J-1", "no sections"), state())
      assert DispatchLint.dispatch_allowed?(issue("a", "J-1", "no sections"))
      refute_received {:graphql, _, _}
      assert DispatchLint.recorded_body_hash("a") == nil
    end

    test "flag on with no sections: nothing is checked" do
      enable_lint([])
      assert Orchestrator.should_dispatch_issue_for_test(issue("a", "J-1", ""), state())
      refute_received {:graphql, _, _}
    end

    test "missing sections: not dispatched, one signed comment, skip reason recorded" do
      enable_lint(@sections)
      issue = issue("a", "J-1", "Why: only\n")

      refute Orchestrator.should_dispatch_issue_for_test(issue, state())

      assert_received {:graphql, _query, %{"issueId" => "a", "body" => body}}
      assert body =~ "`Plan:`"
      assert body =~ "`Approval: 已核准`"
      refute body =~ "`Why:`"
      assert String.ends_with?(body, "🤖 Symphony")
      assert DispatchLint.skip_reason("a") == {:missing_sections, ["Plan:", "Approval: 已核准"]}
      assert DispatchLint.recorded_body_hash("a") == nil
    end

    test "repeated candidates do not comment again, an edited body does" do
      enable_lint(@sections)

      for _ <- 1..3, do: refute(Orchestrator.should_dispatch_issue_for_test(issue("a", "J-1", "Why: x"), state()))
      assert_received {:graphql, _, _}
      refute_received {:graphql, _, _}

      refute Orchestrator.should_dispatch_issue_for_test(issue("a", "J-1", "Why: x\nedited"), state())
      assert_received {:graphql, _, _}
    end

    test "complete body is dispatched and its hash recorded" do
      enable_lint(@sections)

      assert Orchestrator.should_dispatch_issue_for_test(issue("a", "J-1", @complete), state())
      refute_received {:graphql, _, _}
      assert DispatchLint.recorded_body_hash("a") == DispatchLint.body_hash(@complete)
      assert DispatchLint.skip_reason("a") == nil
    end

    test "a failed comment is retried on the next poll" do
      enable_lint(@sections)
      Application.put_env(:symphony_elixir, :linear_client_module, __MODULE__.FailingClient)

      refute Orchestrator.should_dispatch_issue_for_test(issue("a", "J-1", "x"), state())
      assert_received {:graphql, _, _}

      Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
      refute Orchestrator.should_dispatch_issue_for_test(issue("a", "J-1", "x"), state())
      assert_received {:graphql, _, _}
    end
  end

  defmodule FailingClient do
    def graphql(query, variables, _opts \\ []) do
      send(Application.fetch_env!(:symphony_elixir, :dispatch_lint_test_pid), {:graphql, query, variables})
      {:error, :boom}
    end
  end

  defp enable_lint(sections) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, tracker_kind: "memory")

    File.write!(
      path,
      String.replace(
        File.read!(path),
        "agent:\n",
        "agent:\n  dispatch_lint_enabled: true\n  required_sections: #{Jason.encode!(sections)}\n",
        global: false
      )
    )

    WorkflowStore.force_reload()
  end

  defp state do
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

  defp issue(id, identifier, description) do
    %Issue{
      id: id,
      identifier: identifier,
      title: identifier,
      description: description,
      state: "In Progress",
      branch_name: "branch-#{id}",
      url: "https://example.invalid/#{identifier}",
      dispatchable: true
    }
  end
end
