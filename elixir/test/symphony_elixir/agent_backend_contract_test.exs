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

  test "validates opaque launch bindings without allowing backend mutation" do
    assert {:ok, settings} = Config.Schema.parse(%{"agent" => %{"backend" => "antigravity"}})

    assert {:ok,
            %{
              binding_id: "slot-b-receipt",
              backend: :antigravity,
              options: %{"profile_root" => "/var/lib/agy-profile-b"}
            }} =
             AgentBackend.validate_launch_binding(
               "antigravity",
               %{
                 "binding_id" => "slot-b-receipt",
                 "backend" => "antigravity",
                 "options" => %{"profile_root" => "/var/lib/agy-profile-b"}
               },
               settings
             )

    assert {:error, :launch_binding_backend_mismatch} =
             AgentBackend.validate_launch_binding(
               "antigravity",
               %{binding_id: "wrong-backend", backend: "codex", options: %{}},
               settings
             )

    assert {:error, :invalid_antigravity_launch_binding_options} =
             AgentBackend.validate_launch_binding(
               "antigravity",
               %{
                 binding_id: "provider-switch",
                 backend: "antigravity",
                 options: %{profile_root: "/var/lib/agy-profile-b", model: "different"}
               },
               settings
             )

    assert {:error, :invalid_launch_binding} =
             AgentBackend.validate_launch_binding("antigravity", :not_a_map, settings)

    assert {:error, :launch_binding_backend_missing} =
             AgentBackend.validate_launch_binding(
               "antigravity",
               %{binding_id: "missing-backend", options: %{}},
               settings
             )

    for binding_id <- ["", String.duplicate("x", 257), 42] do
      assert {:error, error} =
               AgentBackend.validate_launch_binding(
                 "antigravity",
                 %{binding_id: binding_id, backend: "antigravity", options: %{}},
                 settings
               )

      assert error in [:launch_binding_id_blank, :launch_binding_id_invalid]
    end

    assert {:error, :launch_binding_options_invalid} =
             AgentBackend.validate_launch_binding(
               "antigravity",
               %{binding_id: "bad-options", backend: "antigravity", options: []},
               settings
             )

    codex_settings = %{settings | agent: %{settings.agent | backend: "codex"}}

    assert {:ok, %{backend: :codex, options: %{}}} =
             AgentBackend.validate_launch_binding(
               "codex",
               %{binding_id: "codex-same-route", backend: "codex", options: %{}},
               codex_settings
             )

    assert {:error, :launch_binding_options_unsupported} =
             AgentBackend.validate_launch_binding(
               "codex",
               %{binding_id: "codex-options", backend: "codex", options: %{model: "other"}},
               codex_settings
             )
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
