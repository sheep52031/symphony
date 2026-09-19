defmodule SymphonyElixir.AgentBackendContractTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBackend

  test "accepts the shared Codex and Pi update and result shapes" do
    now = DateTime.utc_now()

    assert :ok = AgentBackend.validate_update(%{event: :session_started, timestamp: now})
    assert :ok = AgentBackend.validate_update(%{event: :agent_settled, timestamp: now, backend: :pi})
    assert :ok = AgentBackend.validate_turn_result(%{session_id: "codex-thread-turn"})
    assert :ok = AgentBackend.validate_turn_result(%{session_id: "pi-session", backend: :pi})
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
