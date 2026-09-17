defmodule SymphonyElixir.Pi.BackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentBackend, Config.Schema}
  alias SymphonyElixir.Pi.Backend

  test "resolves known backends and rejects invalid selectors" do
    assert {:ok, SymphonyElixir.Codex.AppServer} = AgentBackend.resolve("codex")
    assert {:ok, Backend} = AgentBackend.resolve(:pi)
    assert {:error, {:unsupported_backend, "unknown"}} = AgentBackend.resolve("unknown")
    assert {:error, {:invalid_backend, 123}} = AgentBackend.resolve(123)
  end

  test "runs a native Pi turn and maps completion and usage events" do
    test_root = Path.join(System.tmp_dir!(), "symphony-pi-backend-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)
    write_fake_pi!(script)

    previous_secret = System.get_env("PI_TEST_SECRET")
    previous_bitwarden_session = System.get_env("BW_SESSION")
    System.put_env("PI_TEST_SECRET", "secret-that-must-not-reach-pi")
    System.put_env("BW_SESSION", "bitwarden-session-that-must-not-reach-pi")

    on_exit(fn ->
      restore_env("PI_TEST_SECRET", previous_secret)
      restore_env("BW_SESSION", previous_bitwarden_session)
    end)

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      agent_backend: "pi",
      pi_command: script,
      tracker_api_token: "$PI_TEST_SECRET",
      tracker_api_key_command_secret_environment_names: ["BW_SESSION"],
      codex_turn_timeout_ms: 1_000
    )

    issue = %Issue{id: "issue-pi", identifier: "JARVIS-862", title: "Pi backend spike"}
    on_message = fn message -> send(self(), {:pi_message, message}) end

    assert {:ok, session} = Backend.start_session(workspace)
    assert session.session_id == "pi-session"

    assert {:ok, turn} =
             Backend.run_turn(session, "Do the spike", issue, on_message: on_message)

    assert turn.session_id == "pi-session"
    assert is_binary(turn.turn_id)
    assert turn.result["success"]
    assert turn.result["data"] == %{"text" => "done"}
    assert turn.stats["success"]
    assert turn.stats["data"] == %{"tokens" => %{"input" => 12, "output" => 7, "total" => 19}}
    assert turn.backend == :pi
    assert turn.model == %{"id" => "gpt-5.6", "name" => "GPT-5.6", "provider" => "openai"}
    assert turn.thinking_level == "xhigh"
    assert is_integer(turn.backend_process_pid)
    assert File.regular?(turn.receipt_path)

    receipt = turn.receipt_path |> File.read!() |> Jason.decode!()
    assert receipt["backend"] == "pi"
    assert receipt["outcome"] == "completed"
    assert receipt["session"]["id"] == "pi-session"
    assert receipt["session"]["model"]["id"] == "gpt-5.6"
    assert receipt["session"]["thinking_level"] == "xhigh"
    assert receipt["details"]["assistant_text"] == "done"
    assert receipt["details"]["stats"]["tokens"]["total"] == 19
    assert receipt["runtime"]["pid"] == turn.backend_process_pid
    assert receipt["stderr_tail"] == "fake Pi stderr\n"
    assert :ok = Backend.stop_session(session)

    assert_receive {:pi_message,
                    %{
                      event: :session_started,
                      session_id: "pi-session",
                      backend: :pi,
                      attempt_receipt_index: 0,
                      turn_receipt_index: 1,
                      model: %{"id" => "gpt-5.6"},
                      thinking_level: "xhigh",
                      backend_process_pid: backend_process_pid
                    }}

    assert is_integer(backend_process_pid)
    assert_receive {:pi_message, %{event: :agent_started, backend: :pi}}
    assert_receive {:pi_message, %{event: :message_update, backend: :pi}}
    assert_receive {:pi_message, %{event: :agent_settled, backend: :pi}}
    assert_receive {:pi_message, %{event: :usage, usage: %{"input_tokens" => 12, "output_tokens" => 7, "total_tokens" => 19}}}
    assert File.read!(turn.stderr_path) == "fake Pi stderr\n"

    File.rm_rf!(test_root)
  end

  test "does not complete on agent_end with willRetry false before agent_settled" do
    test_root = Path.join(System.tmp_dir!(), "symphony-pi-agent-end-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)
    write_fake_pi!(script)

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      agent_backend: "pi",
      pi_command: script
    )

    issue = %Issue{id: "issue-pi-agent-end", identifier: "JARVIS-END", title: "Agent end"}
    on_message = fn message -> send(self(), {:pi_message, message}) end

    assert {:ok, session} = Backend.start_session(workspace)

    assert {:error, {:turn_timeout, :abort_acknowledged}} =
             Backend.run_turn(session, "agent_end_only", issue, timeout_ms: 40, on_message: on_message)

    assert_receive {:pi_message, %{event: :agent_ended, payload: %{"willRetry" => false}}}
    refute_receive {:pi_message, %{event: :turn_completed}}
    assert_receive {:pi_message, %{event: :turn_aborted}}
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(test_root)
  end

  test "waits through retry and compaction events for authoritative agent_settled" do
    test_root = Path.join(System.tmp_dir!(), "symphony-pi-settled-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)
    write_fake_pi!(script)

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      agent_backend: "pi",
      pi_command: script
    )

    issue = %Issue{id: "issue-pi-settled", identifier: "JARVIS-SETTLED", title: "Settled"}
    on_message = fn message -> send(self(), {:pi_message, message}) end

    assert {:ok, session} = Backend.start_session(workspace)
    assert {:ok, turn} = Backend.run_turn(session, "retry_then_settled", issue, on_message: on_message)

    assert turn.result["success"]
    assert_receive {:pi_message, %{event: :agent_ended, payload: %{"willRetry" => false}}}
    assert_receive {:pi_message, %{event: :notification, payload: %{"type" => "compaction_start"}}}
    assert_receive {:pi_message, %{event: :agent_started}}
    assert_receive {:pi_message, %{event: :agent_settled}}
    assert_receive {:pi_message, %{event: :turn_completed}}
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(test_root)
  end

  test "starts Pi inside an explicit extension, package, skill, credential, and session boundary" do
    test_root = Path.join(System.tmp_dir!(), "symphony-pi-isolation-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "probe-pi")
    ambient_agent_dir = Path.join(test_root, "ambient-agent")
    File.mkdir_p!(workspace)
    write_isolation_probe_pi!(script)

    previous_api_key = System.get_env("OPENAI_API_KEY")
    previous_agent_dir = System.get_env("PI_CODING_AGENT_DIR")
    System.put_env("OPENAI_API_KEY", "ambient-secret-that-must-not-reach-pi")
    System.put_env("PI_CODING_AGENT_DIR", ambient_agent_dir)

    on_exit(fn ->
      restore_env("OPENAI_API_KEY", previous_api_key)
      restore_env("PI_CODING_AGENT_DIR", previous_agent_dir)
    end)

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      agent_backend: "pi",
      pi_command: script
    )

    assert {:ok, session} =
             Backend.start_session(workspace, tracker_bridge_opts: [binding: fixture_tracker_binding()])

    command = session.rpc.command
    assert command =~ "--session-dir"
    assert command =~ "--no-extensions"
    assert command =~ "--no-skills"
    assert command =~ "--no-themes"
    assert command =~ "--no-prompt-templates"
    assert command =~ "--no-context-files"
    assert command =~ "--no-approve"
    assert command =~ "--extension"
    assert command =~ session.tracker_bridge.extension_path

    agent_dir = workspace |> Path.join(".symphony/pi-agent") |> Path.expand()
    session_dir = workspace |> Path.join(".symphony/pi-session") |> Path.expand()
    assert File.read!(Path.join(workspace, ".symphony/pi-agent-dir")) == agent_dir
    assert File.read!(Path.join(workspace, ".symphony/pi-session-dir")) == session_dir
    refute File.exists?(ambient_agent_dir)
    assert Bitwise.band(File.stat!(agent_dir).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(session_dir).mode, 0o777) == 0o700

    assert :ok = Backend.stop_session(session)
    File.rm_rf!(test_root)
  end

  test "resolves Codex by default and accepts Pi only as an explicit selector" do
    assert {:ok, SymphonyElixir.Codex.AppServer} = AgentBackend.resolve("codex")
    assert {:ok, SymphonyElixir.Pi.Backend} = AgentBackend.resolve(:pi)
    assert {:error, {:unsupported_backend, "claude"}} = AgentBackend.resolve("claude")

    assert {:ok, settings} = Schema.parse(%{})
    assert settings.agent.backend == "codex"
    assert is_binary(settings.pi.command)
    assert {:ok, %{agent: %{backend: "pi"}}} = Schema.parse(%{"agent" => %{"backend" => "pi"}})
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(%{"agent" => %{"backend" => "other"}})

    settings = %Schema{
      tracker: %Schema.Tracker{kind: "linear"},
      agent: %Schema.Agent{backend: "pi"},
      worker: %Schema.Worker{ssh_hosts: ["worker-01"]}
    }

    assert {:error, {:unsupported_backend_worker_hosts, :pi}} =
             SymphonyElixir.Config.validate_settings(settings)
  end

  test "AgentRunner selects Pi only when the workflow opts in" do
    test_root = Path.join(System.tmp_dir!(), "symphony-pi-runner-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(test_root)
    write_fake_pi!(script)

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      agent_backend: "pi",
      pi_command: script,
      workspace_root: workspace_root
    )

    issue = %Issue{id: "issue-pi-runner", identifier: "JARVIS-863", title: "Pi runner opt-in"}

    assert :ok =
             AgentRunner.run(issue, nil, issue_state_fetcher: fn _issue_ids -> {:ok, []} end)

    workspace = Path.join(workspace_root, "JARVIS-863")
    assert File.dir?(workspace)

    [receipt_path] =
      Path.wildcard(Path.join(workspace, ".symphony/attempt-receipts/attempt-0000-turn-0001-*.json"))

    assert File.regular?(receipt_path)
    assert receipt_path |> File.read!() |> Jason.decode!() |> Map.fetch!("outcome") == "completed"
    File.rm_rf!(test_root)
  end

  test "persists a typed receipt when Pi rejects turn setup" do
    test_root = Path.join(System.tmp_dir!(), "symphony-pi-error-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)
    write_fake_pi!(script)

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      agent_backend: "pi",
      pi_command: script
    )

    issue = %Issue{
      id: "issue-pi-error",
      identifier: "JARVIS-ERR",
      title: "FAIL_SESSION_NAME"
    }

    on_message = fn message -> send(self(), {:pi_message, message}) end
    assert {:ok, session} = Backend.start_session(workspace)

    assert {:error, {:command_failed, %{"error" => "fixture rejection"}}} =
             Backend.run_turn(session, "do not run", issue, on_message: on_message)

    assert_receive {:pi_message,
                    %{
                      event: :turn_ended_with_error,
                      payload: %{
                        "outcome" => "failed",
                        "details" => %{
                          "stage" => "set_session_name_failed",
                          "reason" => reason
                        },
                        "receipt_path" => receipt_path
                      },
                      session_id: "pi-session",
                      backend: :pi
                    }}

    assert reason =~ "fixture rejection"
    assert File.regular?(receipt_path)

    receipt = receipt_path |> File.read!() |> Jason.decode!()
    assert receipt["outcome"] == "failed"
    assert receipt["details"]["stage"] == "set_session_name_failed"
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(test_root)
  end

  test "persists completion before committing a staged tracker handoff" do
    test_root = Path.join(System.tmp_dir!(), "symphony-pi-handoff-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)
    write_fake_pi!(script)

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      agent_backend: "pi",
      pi_command: script
    )

    parent = self()

    executor = fn _binding, target_state, issue ->
      completion_receipts =
        Path.wildcard(Path.join(workspace, ".symphony/attempt-receipts/attempt-0000-turn-0001-*.json"))
        |> Enum.filter(fn path ->
          path |> File.read!() |> Jason.decode!() |> Map.get("outcome") == "completed"
        end)

      send(parent, {:handoff_executor, completion_receipts, target_state, issue})
      tracker_tool_result(true, %{"data" => %{"transition" => "applied"}})
    end

    binding = fixture_tracker_binding()

    issue = %Issue{id: "issue-pi-handoff", identifier: "JARVIS-HANDOFF", title: "STAGE_HANDOFF"}
    on_message = fn message -> send(self(), {:pi_message, message}) end

    assert {:ok, session} =
             Backend.start_session(workspace,
               tracker_bridge_opts: [binding: binding, handoff_executor: executor]
             )

    assert {:ok, turn} =
             Backend.run_turn(session, "stage_handoff", issue,
               on_message: on_message,
               turn_number: 1
             )

    assert File.regular?(turn.receipt_path)
    assert File.regular?(turn.completion_receipt_path)
    assert File.regular?(turn.handoff_receipt_path)

    assert_receive {:handoff_executor, [completion_receipt_path], "Human Review", ^issue}

    assert completion_receipt_path == turn.completion_receipt_path
    assert completion_receipt_path == turn.receipt_path

    handoff_receipt = turn.handoff_receipt_path |> File.read!() |> Jason.decode!()
    assert handoff_receipt["outcome"] == "handoff_completed"
    assert handoff_receipt["details"]["completion_receipt_path"] == completion_receipt_path
    assert handoff_receipt["details"]["handoff"]["request"]["target_state"] == "Human Review"

    assert_receive {:pi_message,
                    %{
                      event: :turn_completed,
                      receipt_path: ^completion_receipt_path
                    }}

    assert_receive {:pi_message,
                    %{
                      event: :handoff_completed,
                      receipt_path: handoff_receipt_path
                    }}

    assert handoff_receipt_path == turn.handoff_receipt_path
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(test_root)
  end

  test "does not commit a staged handoff when completion receipt persistence fails" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-pi-receipt-failure-#{System.unique_integer([:positive])}")

    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)
    write_fake_pi!(script)

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      agent_backend: "pi",
      pi_command: script
    )

    parent = self()

    executor = fn _binding, _target_state, _issue ->
      send(parent, :unexpected_handoff_commit)
      tracker_tool_result(true, %{"data" => %{}})
    end

    issue = %Issue{id: "issue-receipt-failure", identifier: "JARVIS-RECEIPT", title: "FAIL_RECEIPT"}

    assert {:ok, session} =
             Backend.start_session(workspace,
               tracker_bridge_opts: [
                 binding: fixture_tracker_binding(),
                 handoff_executor: executor
               ]
             )

    receipt_root = Path.join(workspace, ".symphony/attempt-receipts")
    File.mkdir_p!(Path.dirname(receipt_root))
    File.write!(receipt_root, "not-a-directory")

    assert {:error, {:receipt_write_failed, _reason}} =
             Backend.run_turn(session, "stage_handoff", issue, turn_number: 1)

    refute_receive :unexpected_handoff_commit
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(test_root)
  end

  test "persists completion and handoff failure evidence when the staged provider call fails" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-pi-handoff-failure-#{System.unique_integer([:positive])}")

    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)
    write_fake_pi!(script)

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      agent_backend: "pi",
      pi_command: script
    )

    parent = self()

    executor = fn _binding, target_state, issue ->
      send(parent, {:failed_handoff_executor, target_state, issue})
      tracker_tool_result(false, %{"error" => %{"message" => "provider rejected transition"}})
    end

    issue = %Issue{id: "issue-handoff-failure", identifier: "JARVIS-FAIL", title: "FAIL_HANDOFF"}

    assert {:ok, session} =
             Backend.start_session(workspace,
               tracker_bridge_opts: [
                 binding: fixture_tracker_binding(),
                 handoff_executor: executor
               ]
             )

    assert {:error, {:tracker_handoff_failed, staged_handoff, failure}} =
             Backend.run_turn(session, "stage_handoff", issue, turn_number: 1)

    assert staged_handoff.target_state == "Human Review"
    assert failure["success"] == false

    assert_receive {:failed_handoff_executor, "Human Review", ^issue}

    receipts =
      Path.wildcard(Path.join(workspace, ".symphony/attempt-receipts/*.json"))
      |> Map.new(fn path ->
        receipt = path |> File.read!() |> Jason.decode!()
        {receipt["outcome"], {path, receipt}}
      end)

    {completion_receipt_path, _completion_receipt} = Map.fetch!(receipts, "completed")
    {handoff_receipt_path, handoff_receipt} = Map.fetch!(receipts, "handoff_failed")
    assert File.regular?(handoff_receipt_path)
    assert handoff_receipt["details"]["completion_receipt_path"] == completion_receipt_path
    assert handoff_receipt["details"]["handoff"]["target_state"] == "Human Review"
    assert handoff_receipt["details"]["tracker_result"]["success"] == false
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(test_root)
  end

  test "fails closed before starting Pi when tracker bridge binding is invalid" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-pi-bridge-start-failure-#{System.unique_integer([:positive])}")

    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.rm_rf!(test_root)
    File.mkdir_p!(workspace)
    write_fake_pi!(script)

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      agent_backend: "pi",
      pi_command: script
    )

    invalid_binding = %{
      tool_specs: [
        %{
          "name" => "fixture_tracker",
          "description" => "Fixture tracker tool",
          "inputSchema" => %{"type" => "object"}
        }
      ]
    }

    assert {:error, :invalid_tracker_bridge_binding} =
             Backend.start_session(workspace, tracker_bridge_opts: [binding: invalid_binding])

    refute File.exists?(Path.join(workspace, ".symphony/pi-rpc.stderr.log"))
    refute File.exists?(Path.join(workspace, ".symphony/pi-tracker-bridge.mjs"))
    File.rm_rf!(test_root)
  end

  test "aborts a timed-out Pi turn and returns a typed failure" do
    test_root = Path.join(System.tmp_dir!(), "symphony-pi-abort-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)
    write_fake_pi!(script)

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      agent_backend: "pi",
      pi_command: script
    )

    issue = %Issue{id: "issue-pi-timeout", identifier: "JARVIS-864", title: "Pi timeout"}
    on_message = fn message -> send(self(), {:pi_message, message}) end
    assert {:ok, session} = Backend.start_session(workspace)

    assert {:error, {:turn_timeout, :abort_acknowledged}} =
             Backend.run_turn(session, "hang", issue, timeout_ms: 30, on_message: on_message)

    assert_receive {:pi_message,
                    %{
                      event: :turn_aborted,
                      payload: %{
                        "outcome" => "aborted",
                        "details" => %{
                          "reason" => "{:turn_timeout, :abort_acknowledged}",
                          "abort_outcome" => ":acknowledged"
                        },
                        "receipt_path" => receipt_path
                      },
                      session_id: "pi-session",
                      backend: :pi
                    }}

    assert File.regular?(receipt_path)
    assert receipt_path |> File.read!() |> Jason.decode!() |> Map.fetch!("outcome") == "aborted"
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(test_root)
  end

  test "rejects remote worker hosts until a Pi remote transport exists" do
    workspace = Path.join(System.tmp_dir!(), "symphony-pi-backend-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    assert {:error, {:unsupported_backend_worker_host, :pi, "worker-01"}} =
             Backend.start_session(workspace, worker_host: "worker-01")

    File.rm_rf!(workspace)
  end

  defp fixture_tracker_binding do
    %{
      adapter: :fixture,
      tracker_settings: %{
        kind: "linear",
        active_states: ["Todo", "In Progress"],
        terminal_states: ["Done"]
      },
      tool_specs: [
        %{
          "name" => "fixture_tracker",
          "description" => "Fixture tracker tool",
          "inputSchema" => %{
            "type" => "object",
            "additionalProperties" => true
          }
        }
      ],
      secret_environment_names: []
    }
  end

  defp tracker_tool_result(success, payload) do
    output = Jason.encode!(payload)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp write_fake_pi!(path) do
    File.write!(path, """
    #!/bin/sh
    if [ -n "${PI_TEST_SECRET:-}" ] || [ -n "${BW_SESSION:-}" ]; then
      printf '%s\\n' 'Pi received a tracker or helper-auth secret' >&2
      exit 12
    fi
    printf '%s\\n' 'fake Pi stderr' >&2
    while IFS= read -r line; do
      id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
      case "$line" in
        *'"type":"get_state"'*)
          printf '{"type":"response","id":"%s","success":true,"data":{"sessionId":"pi-session","sessionFile":"/tmp/pi-session.jsonl","thinkingLevel":"xhigh","model":{"id":"gpt-5.6","name":"GPT-5.6","provider":"openai"}}}\\n' "$id"
          ;;
        *'"type":"set_session_name"'*)
          case "$line" in
            *'FAIL_SESSION_NAME'*)
              printf '{"type":"response","id":"%s","success":false,"error":"fixture rejection"}\\n' "$id"
              ;;
            *)
              printf '{"type":"response","id":"%s","success":true}\\n' "$id"
              ;;
          esac
          ;;
        *'"type":"prompt"'*)
          case "$line" in
            *'"message":"hang"'*)
              printf '%s\\n' '{"type":"agent_start"}'
              ;;
            *'"message":"agent_end_only"'*)
              printf '%s\\n' '{"type":"agent_start"}'
              printf '%s\\n' '{"type":"agent_end","willRetry":false}'
              printf '{"type":"response","id":"%s","success":true}\\n' "$id"
              ;;
            *'"message":"retry_then_settled"'*)
              printf '%s\\n' '{"type":"agent_start"}'
              printf '%s\\n' '{"type":"agent_end","willRetry":false}'
              printf '%s\\n' '{"type":"compaction_start"}'
              printf '%s\\n' '{"type":"agent_start"}'
              printf '{"type":"response","id":"%s","success":true}\\n' "$id"
              printf '%s\\n' '{"type":"agent_settled"}'
              ;;
            *'"message":"stage_handoff"'*)
              response=$(curl --silent --show-error --fail \
                --header "authorization: Bearer $SYMPHONY_PI_TRACKER_BRIDGE_CAPABILITY" \
                --header 'content-type: application/json' \
                --data '{"tool":"symphony_handoff","arguments":{"target_state":"Human Review"}}' \
                "$SYMPHONY_PI_TRACKER_BRIDGE_URL") || exit 14
              printf '%s' "$response" | grep -q '"success":true' || exit 15
              printf '%s\\n' '{"type":"agent_start"}'
              printf '%s\\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"handoff ready"}]}}'
              printf '%s\\n' '{"type":"agent_settled"}'
              printf '{"type":"response","id":"%s","success":true}\\n' "$id"
              ;;
            *)
              printf '%s\\n' '{"type":"agent_start"}'
              printf '%s\\n' '{"type":"message_update","message":{"text":"working"}}'
              printf '%s\\n' '{"type":"agent_settled"}'
              printf '{"type":"response","id":"%s","success":true}\\n' "$id"
              ;;
          esac
          ;;
        *'"type":"abort"'*)
          printf '{"type":"response","id":"%s","success":true}\\n' "$id"
          ;;
        *'"type":"get_last_assistant_text"'*)
          printf '{"type":"response","id":"%s","success":true,"data":{"text":"done"}}\\n' "$id"
          ;;
        *'"type":"get_session_stats"'*)
          printf '{"type":"response","id":"%s","success":true,"data":{"tokens":{"input":12,"output":7,"total":19}}}\\n' "$id"
          ;;
        *) exit 9 ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp write_isolation_probe_pi!(path) do
    File.write!(path, """
    #!/bin/sh
    for required in --no-extensions --no-skills --no-themes --no-prompt-templates --no-context-files --no-approve; do
      case " $* " in
        *" $required "*) ;;
        *) exit 13 ;;
      esac
    done
    if [ -n "${OPENAI_API_KEY:-}" ]; then
      exit 12
    fi
    printf '%s' "${PI_CODING_AGENT_DIR:-}" > "$PWD/.symphony/pi-agent-dir"
    printf '%s' "${PI_CODING_AGENT_SESSION_DIR:-}" > "$PWD/.symphony/pi-session-dir"
    while IFS= read -r line; do
      id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
      case "$line" in
        *'"type":"get_state"'*)
          printf '{"type":"response","id":"%s","success":true,"data":{"sessionId":"pi-isolation-session"}}\\n' "$id"
          ;;
        *) exit 9 ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end
end
