defmodule SymphonyElixir.Pi.BackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentBackend, Config.Schema}
  alias SymphonyElixir.Pi.Backend

  test "resolves the closed backend mapping without changing Pi" do
    assert MapSet.new(AgentBackend.supported_names()) == MapSet.new(["antigravity", "codex", "pi"])
    assert {:ok, :codex, SymphonyElixir.Codex.AppServer} = AgentBackend.resolve("codex")
    assert {:ok, :pi, Backend} = AgentBackend.resolve(:pi)
    assert {:error, {:unsupported_backend, "unknown"}} = AgentBackend.resolve("unknown")
    assert {:error, {:invalid_backend, 123}} = AgentBackend.resolve(123)
  end

  test "closes the Pi child when get_state fails or omits the session id" do
    for {name, response} <- [
          {"failure", ~s("success":false,"error":"fixture startup rejection")},
          {"missing-session", ~s("success":true,"data":{})}
        ] do
      root =
        Path.join(
          System.tmp_dir!(),
          "symphony-pi-startup-#{name}-#{System.unique_integer([:positive])}"
        )

      workspace = Path.join(root, "workspace")
      script = Path.join(root, "fake-pi")
      exit_marker = Path.join(workspace, ".symphony/pi-exited")
      File.mkdir_p!(workspace)
      write_startup_pi!(script, response)

      write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "pi", pi_command: script)

      case name do
        "failure" ->
          assert {:error, {:command_failed, %{"error" => "fixture startup rejection"}}} =
                   Backend.start_session(workspace)

        "missing-session" ->
          assert {:error, {:invalid_session_state, :missing_session_id}} =
                   Backend.start_session(workspace)
      end

      assert_eventually!(fn -> File.exists?(exit_marker) end)
      File.rm_rf!(root)
    end
  end

  test "runs a native Pi turn, scrubs tracker secrets, and emits lifecycle evidence" do
    {root, workspace, script} = setup_fake_pi!()
    previous_secret = System.get_env("PI_TEST_SECRET")
    System.put_env("PI_TEST_SECRET", "secret-that-must-not-reach-pi")

    on_exit(fn -> restore_env("PI_TEST_SECRET", previous_secret) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "pi",
      pi_command: script,
      tracker_api_token: "$PI_TEST_SECRET",
      codex_turn_timeout_ms: 1_000
    )

    issue = %Issue{id: "issue-pi", identifier: "JARVIS-862", title: "Pi backend spike"}

    on_message = fn message ->
      assert :ok = AgentBackend.validate_update(message)
      send(self(), {:pi_message, message})
    end

    assert {:ok, session} = Backend.start_session(workspace)
    assert session.session_id == "pi-session"
    assert {:ok, turn} = Backend.run_turn(session, "Do the spike", issue, on_message: on_message)

    assert turn.session_id == "pi-session"
    assert turn.result["data"] == %{"text" => "done"}
    assert turn.stats["data"] == %{"tokens" => %{"input" => 12, "output" => 7, "total" => 19}}
    assert turn.backend == :pi
    assert turn.model == %{"id" => "gpt-5.6", "name" => "GPT-5.6", "provider" => "openai"}
    assert turn.thinking_level == "xhigh"
    assert is_integer(turn.backend_process_pid)
    assert File.read!(turn.stderr_path) == "fake Pi stderr\n"

    assert_receive {:pi_message, %{event: :session_started, session_id: "pi-session", backend: :pi, model: %{"id" => "gpt-5.6"}}}
    assert_receive {:pi_message, %{event: :agent_started, backend: :pi}}
    assert_receive {:pi_message, %{event: :message_update, backend: :pi}}
    assert_receive {:pi_message, %{event: :agent_settled, backend: :pi}}
    assert_receive {:pi_message, %{event: :usage, usage: %{"total_tokens" => 19}, backend: :pi}}
    assert_receive {:pi_message, %{event: :turn_completed, backend: :pi}}

    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "does not complete on agent_end before authoritative agent_settled" do
    {root, workspace, script} = setup_fake_pi!()
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "pi", pi_command: script)
    issue = %Issue{id: "issue-pi-agent-end", identifier: "JARVIS-END", title: "Agent end"}
    on_message = fn message -> send(self(), {:pi_message, message}) end

    assert {:ok, session} = Backend.start_session(workspace)

    assert {:error, {:turn_timeout, {:absolute_turn_deadline, :abort_acknowledged}}} =
             Backend.run_turn(session, "agent_end_only", issue, timeout_ms: 40, on_message: on_message)

    assert_receive {:pi_message, %{event: :agent_ended, payload: %{"willRetry" => false}}}
    refute_receive {:pi_message, %{event: :turn_completed}}
    assert_receive {:pi_message, %{event: :turn_aborted, payload: %{"abort_outcome" => ":acknowledged"}}}
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "waits through retry events for agent_settled and fails typed assistant errors" do
    {root, workspace, script} = setup_fake_pi!()
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "pi", pi_command: script)
    on_message = fn message -> send(self(), {:pi_message, message}) end
    assert {:ok, session} = Backend.start_session(workspace)

    issue = %Issue{id: "issue-pi-settled", identifier: "JARVIS-SETTLED", title: "Settled"}
    assert {:ok, _turn} = Backend.run_turn(session, "retry_then_settled", issue, on_message: on_message)
    assert_receive {:pi_message, %{event: :agent_ended, payload: %{"willRetry" => true}}}
    assert_receive {:pi_message, %{event: :agent_settled}}
    assert_receive {:pi_message, %{event: :turn_completed}}

    assert {:error, {:pi_assistant_failed, %{"errorMessage" => "subscription quota exhausted"}}} =
             Backend.run_turn(session, "provider_error", issue, on_message: on_message)

    assert_receive {:pi_message, %{event: :turn_ended_with_error, payload: %{"stage" => "provider_turn_failed"}}}
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "inherits the operator profile while isolating the Pi worker session" do
    root = Path.join(System.tmp_dir!(), "symphony-pi-isolation-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    script = Path.join(root, "probe-pi")
    ambient_agent_dir = Path.join(root, "operator-pi-agent")
    File.mkdir_p!(workspace)
    File.mkdir_p!(ambient_agent_dir)

    File.write!(
      Path.join(ambient_agent_dir, "settings.json"),
      Jason.encode!(%{"defaultProvider" => "subscription-provider", "defaultModel" => "operator-default-model", "defaultThinkingLevel" => "high"})
    )

    write_isolation_probe_pi!(script)

    previous_api_key = System.get_env("OPENAI_API_KEY")
    previous_agent_dir = System.get_env("PI_CODING_AGENT_DIR")
    System.put_env("OPENAI_API_KEY", "ambient-secret-that-must-not-reach-pi")
    System.put_env("PI_CODING_AGENT_DIR", ambient_agent_dir)

    on_exit(fn ->
      restore_env("OPENAI_API_KEY", previous_api_key)
      restore_env("PI_CODING_AGENT_DIR", previous_agent_dir)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "pi", pi_command: script)
    assert {:ok, session} = Backend.start_session(workspace)

    command = session.rpc.command
    assert command =~ "--session-dir"
    assert command =~ "--no-extensions"
    assert command =~ "--no-skills"
    assert command =~ "--no-themes"
    assert command =~ "--no-prompt-templates"
    assert command =~ "--no-context-files"
    assert command =~ "--no-approve"
    refute command =~ "--extension"
    refute command =~ "--provider"
    refute command =~ "--model"
    refute command =~ "--thinking"

    session_dir = workspace |> Path.join(".symphony/pi-session") |> Path.expand()
    assert File.read!(Path.join(workspace, ".symphony/pi-agent-dir")) == ambient_agent_dir
    assert File.read!(Path.join(workspace, ".symphony/pi-session-dir")) == session_dir
    assert session.session_state["model"] == %{"id" => "operator-default-model", "provider" => "subscription-provider"}
    assert session.session_state["thinkingLevel"] == "high"
    assert Bitwise.band(File.stat!(session_dir).mode, 0o777) == 0o700

    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "Codex defaults while Pi requires explicit selection and remains local-only" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.agent.backend == "codex"
    assert {:ok, %{agent: %{backend: "pi"}}} = Schema.parse(%{"agent" => %{"backend" => "pi"}})
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(%{"agent" => %{"backend" => "other"}})

    settings = %Schema{
      tracker: %Schema.Tracker{kind: "linear"},
      agent: %Schema.Agent{backend: "pi"},
      worker: %Schema.Worker{ssh_hosts: ["worker-01"]}
    }

    assert {:error, {:unsupported_backend_worker_hosts, :pi}} = Config.validate_settings(settings)

    workspace =
      Path.join(System.tmp_dir!(), "symphony-pi-remote-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    assert {:error, {:unsupported_backend_worker_host, :pi, "worker-01"}} =
             Backend.start_session(workspace, worker_host: "worker-01")

    File.rm_rf!(workspace)
  end

  test "AgentRunner never starts Pi for an identifier outside the configured allowlist" do
    root = Path.join(System.tmp_dir!(), "symphony-pi-allowlist-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    script = Path.join(root, "fake-pi")
    File.mkdir_p!(root)
    write_fake_pi!(script)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "pi",
      pi_command: script,
      workspace_root: workspace_root,
      allowed_issue_identifiers: ["JARVIS-917"]
    )

    denied = %Issue{id: "issue-pi-denied", identifier: "JARVIS-918", title: "Denied Pi run"}

    assert :ok = AgentRunner.run(denied)
    refute File.exists?(Path.join(workspace_root, "JARVIS-918"))
    File.rm_rf!(root)
  end

  test "AgentRunner selects Pi only when the workflow opts in" do
    root = Path.join(System.tmp_dir!(), "symphony-pi-runner-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    script = Path.join(root, "fake-pi")
    File.mkdir_p!(root)
    write_fake_pi!(script)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "pi",
      pi_command: script,
      workspace_root: workspace_root
    )

    issue = %Issue{id: "issue-pi-runner", identifier: "JARVIS-863", title: "Pi runner opt-in"}

    assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: fn _ -> {:ok, []} end)
    assert File.dir?(Path.join(workspace_root, "JARVIS-863"))
    File.rm_rf!(root)
  end

  test "mixed Codex SSH and local Pi routes validate and start Pi without inheriting SSH" do
    root = Path.join(System.tmp_dir!(), "symphony-pi-mixed-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    script = Path.join(root, "fake-pi")
    File.mkdir_p!(root)
    write_fake_pi!(script)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "codex",
      worker_ssh_hosts: ["m2-air"],
      pi_command: script,
      workspace_root: workspace_root,
      issue_backends: %{"JARVIS-988-PI" => "pi"}
    )

    assert :ok = Config.validate!()
    assert Config.worker_hosts_for_backend("codex") == ["m2-air"]
    assert Config.worker_hosts_for_backend("pi") == [nil]

    issue = %Issue{id: "issue-pi-mixed", identifier: "JARVIS-988-PI", title: "Local Pi route"}
    assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: fn _ -> {:ok, []} end)
    assert File.dir?(Path.join(workspace_root, "JARVIS-988-PI"))
    File.rm_rf!(root)
  end

  test "AgentRunner refuses an explicit backend that conflicts with the configured issue route" do
    root = Path.join(System.tmp_dir!(), "symphony-pi-route-mismatch-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    script = Path.join(root, "fake-pi")
    File.mkdir_p!(root)
    write_fake_pi!(script)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "codex",
      pi_command: script,
      workspace_root: workspace_root,
      issue_backends: %{"JARVIS-988-BOUND" => "pi"}
    )

    issue = %Issue{id: "issue-route-mismatch", identifier: "JARVIS-988-BOUND", title: "Bound Pi route"}

    assert_raise RuntimeError, ~r/backend_route_mismatch/, fn ->
      AgentRunner.run(issue, nil,
        backend: "codex",
        issue_state_fetcher: fn _ -> {:ok, []} end
      )
    end

    refute File.exists?(Path.join(workspace_root, issue.identifier))
    File.rm_rf!(root)
  end

  test "aborts a timed-out Pi turn and returns a typed failure" do
    {root, workspace, script} = setup_fake_pi!()
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "pi", pi_command: script)
    issue = %Issue{id: "issue-pi-timeout", identifier: "JARVIS-864", title: "Pi timeout"}
    on_message = fn message -> send(self(), {:pi_message, message}) end
    assert {:ok, session} = Backend.start_session(workspace)

    assert {:error, {:turn_timeout, {:absolute_turn_deadline, :abort_acknowledged}}} =
             Backend.run_turn(session, "hang", issue, timeout_ms: 30, on_message: on_message)

    assert_receive {:pi_message, %{event: :turn_aborted, session_id: "pi-session", backend: :pi}}
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "protocol chatter cannot extend the Pi absolute turn deadline" do
    {root, workspace, script} = setup_fake_pi!()

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "pi",
      pi_command: script,
      pi_request_timeout_ms: 1_000,
      pi_first_event_timeout_ms: 200,
      pi_turn_timeout_ms: 70
    )

    issue = %Issue{id: "issue-pi-chatter", identifier: "JARVIS-CHATTER", title: "Pi chatter"}
    assert {:ok, session} = Backend.start_session(workspace)
    started_at = System.monotonic_time(:millisecond)

    assert {:error, {:turn_timeout, {:absolute_turn_deadline, :abort_acknowledged}}} =
             Backend.run_turn(session, "chatter", issue, [])

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms < 750
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "classifies the Pi first-event deadline and performs bounded abort" do
    {root, workspace, script} = setup_fake_pi!()

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "pi",
      pi_command: script,
      pi_request_timeout_ms: 500,
      pi_first_event_timeout_ms: 30,
      pi_turn_timeout_ms: 1_000
    )

    issue = %Issue{id: "issue-pi-silent", identifier: "JARVIS-SILENT", title: "Pi silent"}
    assert {:ok, session} = Backend.start_session(workspace)

    assert {:error, {:turn_timeout, {:first_event, :abort_acknowledged}}} =
             Backend.run_turn(session, "silent_first_event", issue, [])

    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "post-result reads share one absolute Pi deadline" do
    {root, workspace, script} = setup_fake_pi!()

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "pi",
      pi_command: script,
      pi_post_result_timeout_ms: 40
    )

    issue = %Issue{id: "issue-pi-post-result", identifier: "JARVIS-POST", title: "Pi post result"}
    assert {:ok, session} = Backend.start_session(workspace)

    assert {:error, {:post_result_timeout, :assistant_text}} =
             Backend.run_turn(session, "slow_post_result", issue, [])

    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  defp assert_eventually!(predicate, attempts \\ 50)

  defp assert_eventually!(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually!(predicate, attempts - 1)
    end
  end

  defp assert_eventually!(_predicate, 0), do: flunk("timed out waiting for Pi child to exit")

  defp setup_fake_pi! do
    root = Path.join(System.tmp_dir!(), "symphony-pi-backend-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    script = Path.join(root, "fake-pi")
    File.mkdir_p!(workspace)
    write_fake_pi!(script)
    {root, workspace, script}
  end

  defp write_startup_pi!(path, response) do
    File.write!(path, """
    #!/bin/sh
    cleanup() { trap - EXIT TERM INT; printf exited > "$PWD/.symphony/pi-exited"; exit 0; }
    trap cleanup EXIT TERM INT
    while IFS= read -r line; do
      id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
      case "$line" in
        *'"type":"get_state"'*) printf '{"type":"response","id":"%s",#{response}}\\n' "$id" ;;
        *) exit 9 ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp write_fake_pi!(path) do
    File.write!(path, """
    #!/bin/sh
    if [ -n "${PI_TEST_SECRET:-}" ]; then
      printf '%s\\n' 'Pi received a tracker secret' >&2
      exit 12
    fi
    printf '%s\\n' 'fake Pi stderr' >&2
    slow_post_result=0
    while IFS= read -r line; do
      id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
      case "$line" in
        *'"type":"get_state"'*) printf '{"type":"response","id":"%s","success":true,"data":{"sessionId":"pi-session","sessionFile":"/tmp/pi-session.jsonl","thinkingLevel":"xhigh","model":{"id":"gpt-5.6","name":"GPT-5.6","provider":"openai"}}}\\n' "$id" ;;
        *'"type":"set_session_name"'*) printf '{"type":"response","id":"%s","success":true}\\n' "$id" ;;
        *'"type":"prompt"'*)
          case "$line" in
            *'"message":"hang"'*) printf '%s\\n' '{"type":"agent_start"}' ;;
            *'"message":"agent_end_only"'*) printf '%s\\n' '{"type":"agent_start"}'; printf '%s\\n' '{"type":"agent_end","willRetry":false}'; printf '{"type":"response","id":"%s","success":true}\\n' "$id" ;;
            *'"message":"retry_then_settled"'*) printf '%s\\n' '{"type":"agent_start"}'; printf '%s\\n' '{"type":"message_end","message":{"role":"assistant","stopReason":"error"}}'; printf '%s\\n' '{"type":"agent_end","willRetry":true}'; printf '%s\\n' '{"type":"compaction_start"}'; printf '%s\\n' '{"type":"agent_start"}'; printf '%s\\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"recovered"}]}}'; printf '{"type":"response","id":"%s","success":true}\\n' "$id"; printf '%s\\n' '{"type":"agent_settled"}' ;;
            *'"message":"provider_error"'*) printf '%s\\n' '{"type":"agent_start"}'; printf '%s\\n' '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"subscription quota exhausted"}}'; printf '%s\\n' '{"type":"agent_settled"}'; printf '{"type":"response","id":"%s","success":true}\\n' "$id" ;;
            *'"message":"chatter"'*) i=0; while [ "$i" -lt 25 ]; do printf '%s\\n' '{"type":"heartbeat"}'; sleep 0.01; i=$((i + 1)); done; printf '%s\\n' '{"type":"agent_settled"}'; printf '{"type":"response","id":"%s","success":true}\\n' "$id" ;;
            *'"message":"silent_first_event"'*) sleep 0.15 ;;
            *'"message":"slow_post_result"'*) slow_post_result=1; printf '%s\\n' '{"type":"agent_start"}'; printf '%s\\n' '{"type":"agent_settled"}'; printf '{"type":"response","id":"%s","success":true}\\n' "$id" ;;
            *) printf '%s\\n' '{"type":"agent_start"}'; printf '%s\\n' '{"type":"message_update","message":{"text":"working"}}'; printf '%s\\n' '{"type":"agent_settled"}'; printf '{"type":"response","id":"%s","success":true}\\n' "$id" ;;
          esac ;;
        *'"type":"abort"'*) printf '{"type":"response","id":"%s","success":true}\\n' "$id" ;;
        *'"type":"get_last_assistant_text"'*) if [ "$slow_post_result" -eq 1 ]; then sleep 1; else printf '{"type":"response","id":"%s","success":true,"data":{"text":"done"}}\\n' "$id"; fi ;;
        *'"type":"get_session_stats"'*) printf '{"type":"response","id":"%s","success":true,"data":{"tokens":{"input":12,"output":7,"total":19}}}\\n' "$id" ;;
        *) exit 9 ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp write_isolation_probe_pi!(path) do
    File.write!(path, """
    #!/bin/sh
    for required in --no-extensions --no-skills --no-themes --no-prompt-templates --no-context-files --no-approve; do case " $* " in *" $required "*) ;; *) exit 13 ;; esac; done
    [ -z "${OPENAI_API_KEY:-}" ] || exit 12
    grep -q '"defaultProvider":"subscription-provider"' "$PI_CODING_AGENT_DIR/settings.json" || exit 14
    printf '%s' "${PI_CODING_AGENT_DIR:-}" > "$PWD/.symphony/pi-agent-dir"
    printf '%s' "${PI_CODING_AGENT_SESSION_DIR:-}" > "$PWD/.symphony/pi-session-dir"
    while IFS= read -r line; do
      id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
      case "$line" in *'"type":"get_state"'*) printf '{"type":"response","id":"%s","success":true,"data":{"sessionId":"pi-isolation-session","thinkingLevel":"high","model":{"id":"operator-default-model","provider":"subscription-provider"}}}\\n' "$id" ;; *) exit 9 ;; esac
    done
    """)

    File.chmod!(path, 0o755)
  end
end
