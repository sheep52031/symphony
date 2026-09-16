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
    System.put_env("PI_TEST_SECRET", "secret-that-must-not-reach-pi")
    on_exit(fn -> restore_env("PI_TEST_SECRET", previous_secret) end)

    write_workflow_file!(Application.fetch_env!(:symphony_elixir, :workflow_file_path),
      agent_backend: "pi",
      pi_command: script,
      tracker_api_token: "$PI_TEST_SECRET",
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

  defp write_fake_pi!(path) do
    File.write!(path, """
    #!/bin/sh
    if [ -n "${PI_TEST_SECRET:-}" ]; then
      printf '%s\\n' 'Pi received a tracker secret' >&2
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
end
