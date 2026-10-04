defmodule SymphonyElixir.AgentBackendContractTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBackend

  test "accepts the shared Codex, Pi, and AntiGravity update and result shapes" do
    now = DateTime.utc_now()

    assert :ok = AgentBackend.validate_update(%{event: :session_started, timestamp: now})
    assert :ok = AgentBackend.validate_update(%{event: :agent_settled, timestamp: now, backend: :pi})
    assert :ok = AgentBackend.validate_update(%{event: :native_result, timestamp: now, backend: :antigravity})
    assert :ok = AgentBackend.validate_turn_result(%{session_id: "codex-thread-turn"})
    assert :ok = AgentBackend.validate_turn_result(%{session_id: "pi-session", backend: :pi})
    assert :ok = AgentBackend.validate_turn_result(%{session_id: "agy-session", backend: :antigravity})
  end

  test "declares backend worker-host compatibility and local-only policy" do
    assert AgentBackend.worker_host_compatible?("codex", nil)
    assert AgentBackend.worker_host_compatible?(:codex, "m2-air")
    refute AgentBackend.worker_host_compatible?("codex", "  ")
    assert AgentBackend.worker_host_compatible?("pi", nil)
    refute AgentBackend.worker_host_compatible?("pi", "m2-air")
    assert AgentBackend.worker_host_compatible?("antigravity", nil)
    refute AgentBackend.worker_host_compatible?("antigravity", "m2-air")
    refute AgentBackend.worker_host_compatible?("unknown", nil)

    refute AgentBackend.local_only?("codex")
    assert AgentBackend.local_only?("pi")
    assert AgentBackend.local_only?("antigravity")
    refute AgentBackend.local_only?("unknown")
  end

  test "rejects malformed adapter updates and turn results" do
    assert {:error, {:invalid_backend_update, %{event: :missing_timestamp}}} =
             AgentBackend.validate_update(%{event: :missing_timestamp})

    invalid_event = %{event: "not-an-atom", timestamp: DateTime.utc_now()}
    assert {:error, {:invalid_backend_update, ^invalid_event}} = AgentBackend.validate_update(invalid_event)

    assert {:error, {:invalid_backend_turn_result, :blank_session_id}} =
             AgentBackend.validate_turn_result(%{session_id: "  "})

    assert {:error, {:invalid_backend_turn_result, %{result: :missing_session}}} =
             AgentBackend.validate_turn_result(%{result: :missing_session})
  end

  test "parses provider-neutral and Pi lifecycle deadlines" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: 321)
    assert Config.agent_stall_timeout_ms() == 321

    assert {:ok, explicit} =
             Config.Schema.parse(%{
               "agent" => %{"backend" => "pi", "stall_timeout_ms" => 123},
               "pi" => %{
                 "request_timeout_ms" => 456,
                 "first_event_timeout_ms" => 78,
                 "turn_timeout_ms" => 910,
                 "post_result_timeout_ms" => 111
               }
             })

    assert explicit.agent.stall_timeout_ms == 123
    assert explicit.pi.request_timeout_ms == 456
    assert explicit.pi.first_event_timeout_ms == 78
    assert explicit.pi.turn_timeout_ms == 910
    assert explicit.pi.post_result_timeout_ms == 111

    assert {:ok, disabled_stall} = Config.Schema.parse(%{"agent" => %{"stall_timeout_ms" => 0}})
    assert disabled_stall.agent.stall_timeout_ms == 0

    assert {:error, {:invalid_workflow_config, "pi.turn_timeout_ms must be greater than 0"}} =
             Config.Schema.parse(%{"pi" => %{"turn_timeout_ms" => 0}})
  end

  test "parses exact per-issue backend bindings and gates AntiGravity candidates" do
    assert {:ok, defaults} = Config.Schema.parse(%{})
    assert defaults.agent.backend == "codex"
    assert defaults.agent.issue_backends == %{}

    assert {:ok, routed} =
             Config.Schema.parse(%{
               "agent" => %{
                 "issue_backends" => %{"JARVIS-979-PI" => "pi"}
               }
             })

    assert routed.agent.issue_backends == %{"JARVIS-979-PI" => "pi"}

    assert {:error, {:invalid_workflow_config, message}} =
             Config.Schema.parse(%{"agent" => %{"issue_backends" => %{"JARVIS-979-X" => "deepseek"}}})

    assert message =~ "issue_backends"

    assert {:error, {:invalid_workflow_config, exact_identifier_message}} =
             Config.Schema.parse(%{"agent" => %{"issue_backends" => %{" JARVIS-979-X " => "pi"}}})

    assert exact_identifier_message =~ "issue_backends"

    agy_route = %{
      "agent" => %{
        "issue_backends" => %{"JARVIS-979-AGY" => "antigravity"}
      }
    }

    assert {:error, {:invalid_workflow_config, gate_message}} = Config.Schema.parse(agy_route)
    assert gate_message =~ "accepted_antigravity_issue_identifiers"

    assert {:ok, accepted} =
             Config.Schema.parse(put_in(agy_route, ["agent", "accepted_antigravity_issue_identifiers"], ["JARVIS-979-AGY"]))

    assert accepted.agent.accepted_antigravity_issue_identifiers == ["JARVIS-979-AGY"]

    assert {:error, {:invalid_workflow_config, extra_gate_message}} =
             Config.Schema.parse(put_in(agy_route, ["agent", "accepted_antigravity_issue_identifiers"], ["JARVIS-979-OTHER"]))

    assert extra_gate_message =~ "accepted_antigravity_issue_identifiers"

    assert {:error, {:invalid_workflow_config, unused_gate_message}} =
             Config.Schema.parse(%{"agent" => %{"accepted_antigravity_issue_identifiers" => ["JARVIS-979-OTHER"]}})

    assert unused_gate_message =~ "accepted_antigravity_issue_identifiers"
  end

  test "validates lifecycle return envelopes and delegates backend-owned config" do
    assert {:ok, :session} = AgentBackend.validate_start_result({:ok, :session})
    assert {:error, :startup_failed} = AgentBackend.validate_start_result({:error, :startup_failed})
    assert {:error, {:invalid_backend_start_result, :ok}} = AgentBackend.validate_start_result(:ok)
    assert :ok = AgentBackend.validate_stop_result(:ok)

    assert {:error, {:invalid_backend_stop_result, :stopped}} =
             AgentBackend.validate_stop_result(:stopped)

    assert {:ok, settings} = Config.Schema.parse(%{"agent" => %{"backend" => "codex"}})
    assert :ok = AgentBackend.validate_config("codex", settings)

    pi_settings = %{settings | agent: %{settings.agent | backend: "pi"}}
    assert :ok = AgentBackend.validate_config("pi", pi_settings)

    remote_pi_settings = %{pi_settings | worker: %{pi_settings.worker | ssh_hosts: ["worker-a"]}}

    assert {:error, {:unsupported_backend_worker_hosts, :pi}} =
             AgentBackend.validate_config("pi", remote_pi_settings)
  end
end
