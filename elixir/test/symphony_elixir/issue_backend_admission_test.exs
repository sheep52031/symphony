defmodule SymphonyElixir.IssueBackendAdmissionTest do
  use SymphonyElixir.TestSupport

  test "memory tracker issues retain separate backend routes and queue at capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 3,
      issue_backends: %{
        "JARVIS-979-CODEX" => "codex",
        "JARVIS-979-PI" => "pi",
        "JARVIS-979-AGY" => "antigravity"
      },
      accepted_antigravity_issue_identifiers: ["JARVIS-979-AGY"],
      antigravity_executable: "/opt/agy/bin/agy",
      antigravity_profile_root: "/var/lib/agy-profile"
    )

    issues = [
      issue("issue-codex", "JARVIS-979-CODEX", "codex-branch"),
      issue("issue-pi", "JARVIS-979-PI", "pi-branch"),
      issue("issue-agy", "JARVIS-979-AGY", "agy-branch")
    ]

    assert Enum.map(issues, &Config.issue_backend(&1.identifier)) == [
             {:ok, "codex"},
             {:ok, "pi"},
             {:ok, "antigravity"}
           ]

    running =
      issues
      |> Enum.zip(["codex", "pi", "antigravity"])
      |> Map.new(fn {issue, backend} ->
        pid = start_fake_backend()

        {issue.id,
         %{
           pid: pid,
           ref: nil,
           backend: backend,
           issue: issue,
           identifier: issue.identifier,
           workspace_path: "/fake/workspaces/#{issue.identifier}",
           started_at: DateTime.utc_now()
         }}
      end)

    on_exit(fn -> Enum.each(running, fn {_id, entry} -> send(entry.pid, :stop) end) end)

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: running,
      claimed: MapSet.new(Map.keys(running)),
      blocked: %{},
      retry_attempts: %{},
      attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    fourth_issue = issue("issue-fourth", "JARVIS-979-FOURTH", "fourth-branch")
    refute Orchestrator.should_dispatch_issue_for_test(fourth_issue, state)

    duplicate_writer = issue("issue-fourth", "JARVIS-979-FOURTH", "codex-branch")
    refute Orchestrator.should_dispatch_issue_for_test(duplicate_writer, %{state | max_concurrent_agents: 4})
  end

  test "active attempt is stopped and held when its exact backend route is revoked" do
    issue = issue("issue-revoked", "JARVIS-979-REVOKED", "revoked-branch")

    write_workflow_file!(Workflow.workflow_file_path(),
      issue_backends: %{"JARVIS-979-REVOKED" => "pi"}
    )

    assert {:ok, "pi"} = Config.issue_backend(issue.identifier)
    {:ok, pid} = Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn -> fake_backend_loop() end)

    state = %Orchestrator.State{
      max_concurrent_agents: 2,
      running: %{
        issue.id => %{
          pid: pid,
          ref: nil,
          identifier: issue.identifier,
          issue: issue,
          backend: "pi",
          backend_route_explicit?: true,
          workspace_path: "/fake/workspaces/#{issue.identifier}",
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue.id]),
      blocked: %{},
      retry_attempts: %{},
      attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    write_workflow_file!(Workflow.workflow_file_path(), issue_backends: %{})
    assert {:ok, "codex"} = Config.issue_backend(issue.identifier)

    updated = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Process.alive?(pid)
    assert updated.running == %{}
    assert updated.retry_attempts == %{}
    assert MapSet.member?(updated.claimed, issue.id)
    assert %{disposition: :backend_route_revoked, backend: "pi"} = updated.blocked[issue.id]
    refute Orchestrator.should_dispatch_issue_for_test(issue, updated)
  end

  test "retry recovery with unknown route provenance does not rebind to the global default" do
    issue = issue("issue-recovered", "JARVIS-979-RECOVERED", "recovered-branch")
    write_workflow_file!(Workflow.workflow_file_path())

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{},
      blocked: %{},
      attempts: %{}
    }

    recovered =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue.id, 1, %{
        identifier: issue.identifier,
        backend: "codex"
      })

    assert %{disposition: :backend_route_revoked, backend: "codex"} = recovered.blocked[issue.id]
    assert MapSet.member?(recovered.claimed, issue.id)
    refute Map.has_key?(recovered.retry_attempts, issue.id)
    refute Orchestrator.should_dispatch_issue_for_test(issue, recovered)
  end

  test "startup holds an active mapped issue with unknown prior backend until it is requeued" do
    issue = issue("issue-after-restart", "JARVIS-979-RESTART", "restart-branch")

    # The old route may have been removed during an outage. The explicit opt-in
    # keeps startup fail-closed even though this config no longer names the issue.
    write_workflow_file!(Workflow.workflow_file_path(),
      issue_backends: %{},
      issue_backend_routing_enabled: true
    )

    assert Config.settings!().agent.issue_backend_routing_enabled

    state = %Orchestrator.State{
      startup_backend_hold_pending?: true,
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      attempts: %{}
    }

    todo_issue = %{issue | id: "fresh-todo", identifier: "JARVIS-979-FRESH", state: "Todo"}
    held = Orchestrator.hold_unknown_startup_backend_routes_for_test([issue, todo_issue], state)

    assert held.startup_backend_hold_pending? == false
    assert MapSet.member?(held.claimed, issue.id)

    assert %{disposition: :backend_route_unknown_after_restart, backend: nil} =
             held.blocked[issue.id]

    refute Orchestrator.should_dispatch_issue_for_test(issue, held)
    assert Orchestrator.should_dispatch_issue_for_test(todo_issue, held)

    requeued = %{issue | state: "Todo"}
    reconciled = Orchestrator.reconcile_blocked_issue_states_for_test([requeued], held)
    refute MapSet.member?(reconciled.claimed, issue.id)
    refute Map.has_key?(reconciled.blocked, issue.id)

    # The global-default mode has no startup hold and retains normal admission.
    write_workflow_file!(Workflow.workflow_file_path(),
      issue_backends: %{},
      issue_backend_routing_enabled: false
    )

    default_state = %Orchestrator.State{startup_backend_hold_pending?: false, blocked: %{}}
    unchanged = Orchestrator.hold_unknown_startup_backend_routes_for_test([issue], default_state)
    assert unchanged == default_state
    assert Orchestrator.should_dispatch_issue_for_test(issue, default_state)
  end

  defp issue(id, identifier, branch) do
    %Issue{
      id: id,
      identifier: identifier,
      title: identifier,
      state: "In Progress",
      branch_name: branch,
      url: "https://example.invalid/#{identifier}",
      dispatchable: true
    }
  end

  defp start_fake_backend do
    parent = self()

    spawn(fn ->
      send(parent, :fake_backend_started)
      fake_backend_loop()
    end)
  end

  defp fake_backend_loop do
    receive do
      :stop -> :ok
    end
  end
end
