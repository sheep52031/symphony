# Stored stream-json samples follow the official headless / Agent SDK schema, not a live service capture.
# Removing the optional backend and its registry line also removes its contract participants.
if "claude" in SymphonyElixir.AgentBackend.supported_names() do
  defmodule SymphonyElixir.Claude.BackendTest do
    use SymphonyElixir.TestSupport

    alias SymphonyElixir.{AgentBackend, Claude.Backend, Config.Schema}

    @session_id "d1e57a6f-4207-4f86-8f25-3b51e1a20a85"
    @fixture Path.expand("fixtures/success.jsonl", __DIR__)
    @startup_timeout_ms 5_000

    setup_all do
      {python, 0} = System.cmd("python3", ["-c", "import sys; print(sys.executable)"])
      {:ok, python: String.trim(python)}
    end

    setup %{python: python} do
      suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      root = Path.join(System.tmp_dir!(), "symphony-claude-#{suffix}")
      workspace = Path.join(root, "workspace")
      bin = Path.join(root, "bin")
      File.mkdir_p!(workspace)
      File.mkdir_p!(bin)
      script = Path.join(bin, "claude")
      write_fake_claude!(script, python)
      previous_path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> previous_path)
      write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "claude", workspace_root: root)

      on_exit(fn ->
        restore_env("PATH", previous_path)
        File.rm_rf!(root)
      end)

      {:ok, root: root, workspace: workspace}
    end

    test "configuration resolves Claude, rejects unknown names, missing CLI and remote hosts", context do
      assert {:ok, :claude, Backend} = AgentBackend.resolve("claude")
      assert {:ok, settings} = Schema.parse(%{"agent" => %{"backend" => "claude"}})
      assert :ok = AgentBackend.validate_config("claude", settings)
      assert {:error, {:unsupported_backend, "unknown"}} = AgentBackend.validate_config("unknown", settings)
      remote = %{settings | worker: %{settings.worker | ssh_hosts: ["ssh-worker"]}}
      assert {:error, {:unsupported_backend_worker_hosts, :claude}} = Backend.validate_config(remote)

      assert {:error, {:unsupported_backend_worker_host, :claude, "ssh-worker"}} =
               Backend.start_session(context.workspace, worker_host: "ssh-worker")

      previous_path = System.get_env("PATH")

      try do
        System.put_env("PATH", context.workspace)
        assert {:error, {:backend_executable_not_found, :claude, "claude"}} = AgentBackend.validate_config("claude", settings)
        assert {:error, {:backend_executable_not_found, :claude, "claude"}} = Backend.start_session(context.workspace)
      after
        System.put_env("PATH", previous_path)
      end
    end

    test "configured login directory survives an empty rewritten HOME and completes a turn", context do
      config_dir = Path.join(context.root, "operator-config")
      File.mkdir_p!(config_dir)
      require_config_dir!(context.workspace, config_dir)
      configure_claude!(%{"config_dir" => config_dir})
      previous_home = System.get_env("HOME")
      previous_dir = System.get_env("CLAUDE_CONFIG_DIR")

      on_exit(fn ->
        restore_env("HOME", previous_home)
        restore_env("CLAUDE_CONFIG_DIR", previous_dir)
      end)

      System.put_env("CLAUDE_CONFIG_DIR", Path.join(context.root, "wrong-config"))
      System.put_env("HOME", context.workspace)

      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, _} = Backend.run_turn(session, "review", %{}, timeout_ms: 1_500)

      for phase <- ["auth", "turn"] do
        assert launch_env(context.workspace, phase) == %{"HOME" => context.workspace, "CLAUDE_CONFIG_DIR" => config_dir}
      end

      assert File.ls!(config_dir) == []
      assert :ok = Backend.stop_session(session)
    end

    test "without CLAUDE_CONFIG_DIR the same fake rejects the rewritten HOME before a turn", context do
      config_dir = Path.join(context.root, "operator-config")
      File.mkdir_p!(config_dir)
      require_config_dir!(context.workspace, config_dir)
      wrapper = Path.join(context.root, "without-config-dir")
      fake = Path.join(context.root, "bin/claude")
      File.write!(wrapper, "#!#{System.find_executable("bash")}\nunset CLAUDE_CONFIG_DIR\nexec '#{fake}' \"$@\"\n")
      File.chmod!(wrapper, 0o755)
      configure_claude!(%{"command" => wrapper, "config_dir" => config_dir})
      previous_home = System.get_env("HOME")
      on_exit(fn -> restore_env("HOME", previous_home) end)
      System.put_env("HOME", context.workspace)

      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:error, :claude_not_logged_in} = Backend.run_turn(session, "never dispatched", %{}, timeout_ms: 1_500)
      assert calls(context.workspace) == []
      assert launch_env(context.workspace, "auth")["CLAUDE_CONFIG_DIR"] == nil
      assert :ok = Backend.stop_session(session)
    end

    test "default config directory is captured from the operator HOME before child launch", context do
      operator_home = Path.join(context.root, "operator-home")
      File.mkdir_p!(operator_home)
      require_config_dir!(context.workspace, Path.join(operator_home, ".claude"))
      previous_home = System.get_env("HOME")
      previous_dir = System.get_env("CLAUDE_CONFIG_DIR")

      on_exit(fn ->
        restore_env("HOME", previous_home)
        restore_env("CLAUDE_CONFIG_DIR", previous_dir)
      end)

      System.delete_env("CLAUDE_CONFIG_DIR")
      System.put_env("HOME", operator_home)
      assert {:ok, session} = Backend.start_session(context.workspace)
      System.put_env("HOME", context.workspace)
      assert {:ok, _} = Backend.run_turn(session, "review", %{}, timeout_ms: 1_500)

      for phase <- ["auth", "turn"] do
        assert launch_env(context.workspace, phase)["CLAUDE_CONFIG_DIR"] == Path.join(operator_home, ".claude")
      end

      assert :ok = Backend.stop_session(session)
    end

    test "ambient config directory is passed when workflow does not override it", context do
      config_dir = Path.join(context.root, "ambient-config")
      require_config_dir!(context.workspace, config_dir)
      previous_dir = System.get_env("CLAUDE_CONFIG_DIR")
      previous_home = System.get_env("HOME")

      on_exit(fn ->
        restore_env("CLAUDE_CONFIG_DIR", previous_dir)
        restore_env("HOME", previous_home)
      end)

      System.put_env("CLAUDE_CONFIG_DIR", config_dir)
      System.put_env("HOME", context.workspace)
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, _} = Backend.run_turn(session, "review", %{}, timeout_ms: 1_500)
      assert :ok = Backend.stop_session(session)
    end

    test "rejects malformed Claude configuration without inspecting directories" do
      for raw <- [nil, "not a map", %{"command" => ""}, %{"command" => 12}, %{"config_dir" => nil}, %{"config_dir" => " "}] do
        assert {:error, {:invalid_claude_config, _}} = Backend.validate_config(%{claude: raw})
      end
    end

    test "loggedIn false is rejected even if authMethod claims claude.ai", context do
      File.mkdir_p!(Path.join(context.workspace, ".symphony"))
      File.write!(Path.join(context.workspace, ".symphony/auth-output-mode"), "logged_out")
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:error, :claude_not_logged_in} = Backend.run_turn(session, "never dispatched", %{}, [])
      assert calls(context.workspace) == []
      assert :ok = Backend.stop_session(session)
    end

    test "invalid command reload retains the last known good workflow without deadlock", context do
      executable = Path.join(context.root, "real-claude")
      File.cp!(Path.join(context.root, "bin/claude"), executable)
      File.chmod!(executable, 0o755)
      configure_claude!(%{"command" => executable})
      path = Workflow.workflow_file_path()
      missing = Path.join(context.root, "missing-real-claude")
      File.write!(path, String.replace(File.read!(path), Jason.encode!(executable), Jason.encode!(missing)))

      capture_log(fn ->
        assert {:error, {:backend_executable_not_found, :claude, ^missing}} = WorkflowStore.force_reload()
        assert {:ok, session} = Backend.start_session(context.workspace)
        assert :sys.get_state(session).executable == executable
        assert {:ok, _} = Backend.run_turn(session, "review", %{}, timeout_ms: 1_500)
        assert :ok = Backend.stop_session(session)
      end)
    end

    test "absolute command launches that executable instead of the PATH candidate", context do
      executable = Path.join(context.root, "real claude's binary")
      File.cp!(Path.join(context.root, "bin/claude"), executable)
      File.chmod!(executable, 0o755)
      configure_claude!(%{"command" => executable})
      File.write!(Path.join(context.root, "bin/claude"), "#!/nonexistent-interpreter\n")
      assert :ok = Backend.validate_config(%{})
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert :sys.get_state(session).executable == executable
      assert {:ok, _} = Backend.run_turn(session, "review", %{}, timeout_ms: 1_500)
      assert :ok = Backend.stop_session(session)
    end

    test "unset command retains PATH lookup and missing configured paths are named", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert :sys.get_state(session).executable == System.find_executable("claude")
      assert :ok = Backend.stop_session(session)
      missing = Path.join(context.root, "missing-claude")

      assert {:error, {:backend_executable_not_found, :claude, ^missing}} =
               Backend.validate_config(%{claude: %{"command" => missing}})

      configure_claude!(%{"command" => missing}, reload: false)
      assert {:error, {:backend_executable_not_found, :claude, ^missing}} = Backend.validate_config(%{})
    end

    test "HOME-dependent wrapper fails promptly with a typed error naming the executable", context do
      executable = Path.join(context.root, "home-wrapper")
      fake = Path.join(context.root, "bin/claude")
      File.write!(executable, "#!#{System.find_executable("bash")}\nif [ \"$HOME\" = '#{context.workspace}' ]; then echo 'config files are not trusted' >&2; exit 42; fi\nexec '#{fake}' \"$@\"\n")
      File.chmod!(executable, 0o755)
      configure_claude!(%{"command" => executable})
      previous_home = System.get_env("HOME")
      on_exit(fn -> restore_env("HOME", previous_home) end)
      System.put_env("HOME", context.workspace)
      assert {:ok, session} = Backend.start_session(context.workspace)

      assert {:error, {:claude_preflight_failed, ^executable, 42, hint}} =
               Backend.run_turn(session, "never dispatched", %{}, timeout_ms: 1_500)

      assert hint =~ "claude.command"
      refute File.exists?(Path.join(context.workspace, ".symphony/calls.jsonl"))
      assert :ok = Backend.stop_session(session)
    end

    test "reports deleted workspaces and validates default config envelopes", context do
      assert :ok = Backend.validate_config(%{})
      missing = Path.join(context.root, "missing")
      assert {:error, {:workspace_not_found, ^missing}} = Backend.start_session(missing)
      assert {:ok, session} = Backend.start_session(context.workspace)
      File.rm_rf!(context.workspace)
      assert {:error, {:claude_start_failed, _, {:workspace_not_found, _}}} = Backend.run_turn(session, "review", %{}, [])
      assert :ok = Backend.stop_session(session)
      assert {:error, {:claude_session_exit, _}} = Backend.run_turn(session, "review", %{}, [])
    end

    test "auth preflight and print mode receive stdin EOF without waiting for port closure", context do
      File.mkdir_p!(Path.join(context.workspace, ".symphony"))
      File.write!(Path.join(context.workspace, ".symphony/auth-output-mode"), "stdin_eof")
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, _} = Backend.run_turn(session, "stdin_eof", %{}, timeout_ms: @startup_timeout_ms)
      assert File.read!(Path.join(context.workspace, ".symphony/auth-stdin")) == ""
      assert File.read!(Path.join(context.workspace, ".symphony/turn-stdin")) == ""
      assert :ok = Backend.stop_session(session)
    end

    test "accepts a CLI that emits fixtures and exits immediately", context do
      path = Path.join(context.root, "bin/claude")

      File.write!(path, """
      \#!#{System.find_executable("bash")}
      case "$*" in
        *" auth status --json"*) printf '%s\\n' '{"authMethod":"claude.ai"}' ;;
        *) printf '%s' '#{File.read!(@fixture)}' ;;
      esac
      """)

      File.chmod!(path, 0o755)
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, turn} = Backend.run_turn(session, "review", %{}, timeout_ms: @startup_timeout_ms)
      assert :ok = AgentBackend.validate_turn_result(turn)
      assert :ok = Backend.stop_session(session)
    end

    test "stream fixtures meet the shared lifecycle contract, resume and stop idempotently", context do
      assert {:ok, session} = Backend.start_session(context.workspace)

      on_message = fn message ->
        assert :ok = AgentBackend.validate_update(message)
        send(self(), {:update, message})
      end

      assert {:ok, turn} = Backend.run_turn(session, "review 'this'; $nothing", %{}, on_message: on_message)
      assert :ok = AgentBackend.validate_turn_result(turn)
      assert turn.session_id == @session_id
      assert turn.result["result"] == "No blocking findings."
      assert_receive {:update, %{event: :session_started, session_id: @session_id, backend: :claude}}
      assert_receive {:update, %{event: :message_update, assistant_text_delta: "No blocking findings."}}
      assert_receive {:update, %{event: :message_ended, assistant_text: "No blocking findings."}}
      assert_receive {:update, %{event: :usage, usage: %{"input_tokens" => 12, "output_tokens" => 7}}}
      assert_receive {:update, %{event: :turn_completed, session_id: @session_id}}
      assert {:ok, second} = Backend.run_turn(session, "continue", %{}, [])
      assert second.session_id == turn.session_id
      [first_args, second_args] = calls(context.workspace)
      assert List.last(first_args) == "review 'this'; $nothing"
      refute "--resume" in first_args
      assert Enum.chunk_every(second_args, 2, 1, :discard) |> Enum.member?(["--resume", @session_id])

      for args <- [first_args, second_args] do
        assert "-p" in args
        assert "stream-json" in args
        assert "--verbose" in args
        assert "--include-partial-messages" in args
        assert Enum.chunk_every(args, 2, 1, :discard) |> Enum.member?(["--permission-mode", "dontAsk"])
        refute "--model" in args
        refute "--fallback-model" in args
        refute "--bare" in args
      end

      assert :ok = AgentBackend.validate_stop_result(Backend.stop_session(session))
      assert :ok = Backend.stop_session(session)
    end

    test "AgentRunner dispatches one workflow-selected Claude issue and emits lifecycle updates", context do
      issue = %Issue{id: "claude-issue", identifier: "JARVIS-1198", title: "Independent PR review", state: "In Progress"}
      assert :ok = AgentRunner.run(issue, self(), max_turns: 1, issue_state_fetcher: fn _ -> {:ok, [%{issue | state: "Done"}]} end)
      assert_receive {:codex_worker_update, "claude-issue", %{event: :session_started, backend: :claude}}
      assert_receive {:codex_worker_update, "claude-issue", %{event: :message_update, backend: :claude}}
      assert_receive {:codex_worker_update, "claude-issue", %{event: :turn_completed, session_id: @session_id}}
      assert length(calls(Path.join(context.root, "JARVIS-1198"))) == 1
    end

    test "scrubs ambient secrets and provider routing without reading any credential file", context do
      names = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "ANTHROPIC_BASE_URL", "CLAUDE_TEST_SECRET"]

      # Only inspect variable names. Never fetch/copy an operator's existing auth values.
      inherited_names = System.get_env() |> Map.keys()

      for name <- names, name not in inherited_names do
        System.put_env(name, "fixture-only-not-a-credential")
        on_exit(fn -> System.delete_env(name) end)
      end

      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, _} = Backend.run_turn(session, "probe", %{}, [])
      probe = context.workspace |> Path.join(".symphony/env-presence.json") |> File.read!() |> Jason.decode!()
      assert Enum.all?(probe, fn {_name, present} -> present == false end)
      [args] = calls(context.workspace)
      index = Enum.find_index(args, &(&1 == "--settings"))
      settings = Jason.decode!(Enum.at(args, index + 1))
      assert settings["forceLoginMethod"] == "claudeai"
      assert settings["apiKeyHelper"] == ""
      assert settings["env"]["ANTHROPIC_API_KEY"] == ""
      assert settings["env"]["CLAUDE_CODE_USE_BEDROCK"] == ""
      assert settings["env"]["CLAUDE_CODE_USE_VERTEX"] == ""
      assert settings["env"]["CLAUDE_CODE_USE_FOUNDRY"] == ""
      assert :ok = Backend.stop_session(session)
    end

    for {prompt, reason} <- [
          {"exit_nonzero", {:claude_exit, 23}},
          {"success_nonzero", {:claude_exit, 24}},
          {"not_logged_in", :claude_not_logged_in},
          {"stderr_login", :claude_not_logged_in},
          {"usage_limit", :claude_usage_limit},
          {"assistant_auth", :claude_not_logged_in},
          {"assistant_limit", :claude_usage_limit},
          {"api_key_source", {:claude_subscription_required, "ANTHROPIC_API_KEY"}},
          {"missing_result", :claude_missing_result},
          {"blank_session", :claude_missing_session_id},
          {"malformed", :claude_invalid_stream_json},
          {"oversized_stream", :claude_stream_line_too_large}
        ] do
      test "typed failure without fallback: #{prompt}", context do
        assert {:ok, session} = Backend.start_session(context.workspace)
        on_message = fn message -> send(self(), {:failure_update, message}) end

        assert {:error, unquote(Macro.escape(reason))} =
                 Backend.run_turn(session, unquote(prompt), %{}, on_message: on_message)

        assert_receive {:failure_update, %{event: :turn_ended_with_error, backend: :claude}}
        refute_receive {:failure_update, %{event: :turn_completed}}
        assert length(calls(context.workspace)) == 1
        assert :ok = Backend.stop_session(session)
        assert :ok = Backend.stop_session(session)
      end
    end

    test "AgentRunner records a typed failure and never tries another backend", context do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        workspace_root: context.root,
        prompt: "not_logged_in",
        codex_command: "touch fallback-codex",
        pi_command: "touch fallback-pi"
      )

      issue = %Issue{id: "claude-failure", identifier: "JARVIS-FAIL", title: "Failure", state: "In Progress"}
      assert_raise RuntimeError, ~r/claude_not_logged_in/, fn -> AgentRunner.run(issue, self(), max_turns: 1) end
      assert_receive {:codex_worker_update, "claude-failure", %{event: :turn_ended_with_error, backend: :claude}}
      workspace = Path.join(context.root, "JARVIS-FAIL")
      assert length(calls(workspace)) == 1
      refute File.exists?(Path.join(workspace, "fallback-codex"))
      refute File.exists?(Path.join(workspace, "fallback-pi"))
    end

    for method <- ["none", "api_key", "api_key_helper", "third_party", "oauth_token"] do
      test "auth preflight rejects #{method} before any model request", context do
        File.mkdir_p!(Path.join(context.workspace, ".symphony"))
        File.write!(Path.join(context.workspace, ".symphony/auth-method"), unquote(method))
        assert {:ok, session} = Backend.start_session(context.workspace)
        result = Backend.run_turn(session, "never dispatched", %{}, [])

        expected =
          if unquote(method) == "none",
            do: :claude_not_logged_in,
            else: {:claude_subscription_required, unquote(method)}

        assert result == {:error, expected}
        assert calls(context.workspace) == []
        assert :ok = Backend.stop_session(session)
      end
    end

    for mode <- ["invalid", "oversized", "block_print_start"] do
      test "rejects #{mode} auth output without fallback", context do
        File.mkdir_p!(Path.join(context.workspace, ".symphony"))
        File.write!(Path.join(context.workspace, ".symphony/auth-output-mode"), unquote(mode))
        assert {:ok, session} = Backend.start_session(context.workspace)
        result = Backend.run_turn(session, "review", %{}, [])

        if unquote(mode) == "block_print_start" do
          assert {:error, {:claude_start_failed, _, _}} = result
        else
          assert {:error, :claude_invalid_auth_status} = result
        end

        assert calls(context.workspace) == []
        assert :ok = Backend.stop_session(session)
      end
    end

    test "handles native notifications, non-text blocks and fragmented JSON lines", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, _} = Backend.run_turn(session, "fragmented", %{}, on_message: fn event -> send(self(), {:native, event}) end)
      assert_receive {:native, %{event: :notification, payload: %{"subtype" => "api_retry"}}}
      assert_receive {:native, %{event: :message_ended, assistant_text: text}}
      assert byte_size(text) > 1_048_576
      assert :ok = Backend.stop_session(session)
    end

    test "reports non-auth result failures even when stderr disappears", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:error, {:claude_result_failed, %{"is_error" => true}}} = Backend.run_turn(session, "result_error", %{}, [])
      assert {:ok, _} = Backend.run_turn(session, "missing_stderr", %{}, [])
      assert :ok = Backend.stop_session(session)
    end

    test "rejects concurrent turns while keeping the original turn alive", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      parent = self()
      task = Task.async(fn -> Backend.run_turn(session, "hang", %{}, on_message: fn event -> send(parent, {:busy, event}) end) end)
      assert_receive {:busy, %{event: :session_started}}, @startup_timeout_ms
      assert {:error, :claude_turn_in_progress} = Backend.run_turn(session, "second", %{}, [])
      assert :ok = Backend.stop_session(session)
      assert {:error, {:claude_session_exit, :normal}} = Task.await(task, 2_000)
    end

    test "owner exit terminates the session and active CLI", context do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, session} = Backend.start_session(context.workspace)
          send(parent, {:owned_session, session})
          Backend.run_turn(session, "hang", %{}, on_message: fn event -> send(parent, {:owned, event}) end)
        end)

      on_exit(fn -> Process.exit(owner, :kill) end)
      assert_receive {:owned_session, session}
      monitor = Process.monitor(session)
      assert_receive {:owned, %{event: :session_started}}, @startup_timeout_ms
      child = context.workspace |> Path.join(".symphony/cli-pid") |> File.read!() |> String.trim()
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 2_000
      assert_eventually(fn -> not process_alive?(child) end)
      assert :ok = Backend.stop_session(session)
    end

    test "caller exit cleans the active turn without destroying the reusable session", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      parent = self()

      caller =
        spawn(fn ->
          Backend.run_turn(session, "hang", %{}, on_message: fn event -> send(parent, {:caller, event}) end)
        end)

      on_exit(fn -> Process.exit(caller, :kill) end)
      assert_receive {:caller, %{event: :session_started}}, @startup_timeout_ms
      child = context.workspace |> Path.join(".symphony/cli-pid") |> File.read!() |> String.trim()
      Process.exit(caller, :kill)
      assert_eventually(fn -> :sys.get_state(session).active == nil end)
      assert_eventually(fn -> not process_alive?(child) end)
      send(session, {:deadline, make_ref()})
      assert :sys.get_state(session).active == nil
      assert {:ok, _} = Backend.run_turn(session, "continue", %{}, [])
      assert :ok = Backend.stop_session(session)
    end

    test "can stop normally when setsid is unavailable", context do
      bin = Path.join(context.root, "without-setsid")
      File.mkdir_p!(bin)

      for name <- ["claude", "bash", "kill"] do
        File.ln_s!(System.find_executable(name), Path.join(bin, name))
      end

      previous_path = System.get_env("PATH")

      try do
        System.put_env("PATH", bin)
        assert {:ok, session} = Backend.start_session(context.workspace)
        assert {:ok, _} = Backend.run_turn(session, "review", %{}, [])
        assert :ok = Backend.stop_session(session)
      after
        System.put_env("PATH", previous_path)
      end
    end

    for mode <- ["missing", "broken"] do
      test "cleanup remains idempotent with #{mode} kill executable", context do
        bin = Path.join(context.root, "kill-" <> unquote(mode))
        File.mkdir_p!(bin)

        if unquote(mode) == "broken" do
          path = Path.join(bin, "kill")
          File.write!(path, "#!/nonexistent-interpreter\n")
          File.chmod!(path, 0o755)
        end

        assert {:ok, session} = Backend.start_session(context.workspace)
        previous_path = System.get_env("PATH")

        try do
          on_message = fn
            %{event: :session_started} ->
              System.put_env("PATH", bin)
              File.write!(Path.join(context.workspace, ".symphony/release"), "ready")

            _ ->
              :ok
          end

          assert {:ok, _} = Backend.run_turn(session, "wait_cleanup", %{}, on_message: on_message)
          assert :ok = Backend.stop_session(session)
          assert :ok = Backend.stop_session(session)
        after
          System.put_env("PATH", previous_path)
        end
      end
    end

    test "cleans up descendants after the CLI exits", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, _} = Backend.run_turn(session, "descendant", %{}, [])
      child = context.workspace |> Path.join(".symphony/child-pid") |> File.read!() |> String.trim()
      on_exit(fn -> System.cmd("kill", ["-KILL", child], stderr_to_stdout: true) end)
      assert_eventually(fn -> not process_alive?(child) end)
      assert :ok = Backend.stop_session(session)
    end

    test "absolute timeout stops a streaming child", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      parent = self()

      # The deadline includes auth preflight and two process launches. 250ms can
      # expire before the print CLI even exists on macOS. Wait for observable
      # streaming startup within a bounded budget before checking its cleanup.
      task =
        Task.async(fn ->
          Backend.run_turn(session, "hang", %{},
            timeout_ms: @startup_timeout_ms,
            on_message: fn event -> send(parent, {:streaming, event}) end
          )
        end)

      assert_receive {:streaming, %{event: :session_started}}, @startup_timeout_ms
      child = context.workspace |> Path.join(".symphony/cli-pid") |> File.read!() |> String.trim()
      assert process_alive?(child)
      assert {:error, :claude_turn_timeout} = Task.await(task, @startup_timeout_ms + 1_000)
      assert_eventually(fn -> not process_alive?(child) end)
      assert :ok = Backend.stop_session(session)
    end

    test "stop interrupts an in-flight turn", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      caller = self()
      task = Task.async(fn -> Backend.run_turn(session, "hang", %{}, on_message: fn event -> send(caller, {:inflight, event}) end) end)
      assert_receive {:inflight, %{event: :session_started}}, @startup_timeout_ms
      assert :ok = Backend.stop_session(session)
      assert {:error, {:claude_session_exit, :normal}} = Task.await(task, 2_000)
      assert :ok = Backend.stop_session(session)
    end

    defp configure_claude!(config, opts \\ []) do
      path = Workflow.workflow_file_path()
      fields = Enum.map_join(config, "\n", fn {key, value} -> "  #{key}: #{Jason.encode!(value)}" end)
      content = File.read!(path) |> String.replace_prefix("---\n", "---\nclaude:\n#{fields}\n")
      File.write!(path, content)
      if Keyword.get(opts, :reload, true), do: assert(:ok == WorkflowStore.force_reload())
    end

    defp require_config_dir!(workspace, config_dir) do
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      File.write!(Path.join(workspace, ".symphony/required-config-dir"), config_dir)
    end

    defp launch_env(workspace, phase) do
      workspace |> Path.join(".symphony/#{phase}-env.json") |> File.read!() |> Jason.decode!()
    end

    defp calls(workspace) do
      workspace |> Path.join(".symphony/calls.jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1) |> Enum.filter(&("-p" in &1))
    end

    defp process_alive?(pid) do
      case System.cmd("ps", ["-o", "stat=", "-p", pid], stderr_to_stdout: true) do
        {status, 0} -> String.trim(status) != "" and not String.starts_with?(String.trim(status), "Z")
        _ -> false
      end
    end

    defp assert_eventually(predicate, attempts \\ 100)
    defp assert_eventually(predicate, 0), do: assert(predicate.())

    defp assert_eventually(predicate, attempts) do
      if predicate.() do
        :ok
      else
        Process.sleep(10)
        assert_eventually(predicate, attempts - 1)
      end
    end

    defp write_fake_claude!(path, python) do
      File.write!(path, """
      \#!#{python}
      import json, os, shutil, sys, time
      os.makedirs('.symphony', exist_ok=True)
      with open('.symphony/calls.jsonl', 'a') as f:
          f.write(json.dumps(sys.argv[1:]) + '\\n')
      names = ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'ANTHROPIC_BASE_URL', 'CLAUDE_TEST_SECRET']
      with open('.symphony/env-presence.json', 'w') as f:
          json.dump({name: name in os.environ for name in names}, f)
      phase = 'auth' if 'auth' in sys.argv and 'status' in sys.argv else 'turn'
      with open('.symphony/' + phase + '-env.json', 'w') as f:
          json.dump({name: os.environ.get(name) for name in ['HOME', 'CLAUDE_CONFIG_DIR']}, f)
      if 'auth' in sys.argv and 'status' in sys.argv:
          mode = ''
          if os.path.exists('.symphony/auth-output-mode'):
              with open('.symphony/auth-output-mode') as f: mode = f.read()
          if mode == 'stdin_eof':
              with open('.symphony/auth-stdin', 'w') as f: f.write(sys.stdin.read())
          if mode == 'logged_out':
              print(json.dumps({'loggedIn': False, 'authMethod': 'claude.ai'}), flush=True)
              sys.exit(0)
          if mode == 'invalid':
              print('{}', flush=True)
              sys.exit(0)
          if mode == 'oversized':
              print('a' * 4194305, flush=True)
              sys.exit(0)
          if mode == 'block_print_start':
              shutil.rmtree('.symphony/claude')
              with open('.symphony/claude', 'w') as f: f.write('not a directory')
          method = 'claude.ai'
          if os.path.exists('.symphony/auth-method'):
              with open('.symphony/auth-method') as f: method = f.read()
          if os.path.exists('.symphony/required-config-dir'):
              with open('.symphony/required-config-dir') as f: required = f.read()
              # The workspace is the rewritten HOME. macOS reports the physical cwd
              # (/private/var/...) for a temp path spelled /var/..., so compare real paths.
              home = os.environ.get('HOME')
              if os.environ.get('CLAUDE_CONFIG_DIR') != required or home is None or os.path.realpath(home) != os.path.realpath(os.getcwd()):
                  method = 'none'
          # Simulate a user profile injecting provider/API-key env after process launch.
          settings = json.loads(sys.argv[sys.argv.index('--settings') + 1])
          profile_env = {'CLAUDE_CODE_USE_BEDROCK': '1', 'ANTHROPIC_API_KEY': 'fixture-only'}
          profile_env.update(settings.get('env', {}))
          if profile_env.get('CLAUDE_CODE_USE_BEDROCK'): method = 'third_party'
          if profile_env.get('ANTHROPIC_API_KEY'): method = 'api_key'
          print(json.dumps({'loggedIn': method != 'none', 'authMethod': method}, indent=2), flush=True)
          sys.exit(1 if method == 'none' else 0)
      with open('.symphony/cli-pid', 'w') as f: f.write(str(os.getpid()))
      prompt = sys.argv[-1].strip()
      if prompt == 'stdin_eof':
          with open('.symphony/turn-stdin', 'w') as f: f.write(sys.stdin.read())
      if prompt == 'descendant':
          child = os.fork()
          if child == 0:
              null = os.open('/dev/null', os.O_RDWR)
              for fd in [0, 1, 2]: os.dup2(null, fd)
              time.sleep(30)
              os._exit(0)
          with open('.symphony/child-pid', 'w') as f: f.write(str(child))
      if prompt == 'exit_nonzero': sys.exit(23)
      if prompt == 'not_logged_in':
          print('Not logged in. Please run /login', flush=True)
          sys.exit(1)
      if prompt == 'stderr_login':
          print('Not logged in', file=sys.stderr, flush=True)
          sys.exit(1)
      if prompt == 'usage_limit':
          print(json.dumps({'type': 'result', 'subtype': 'success', 'is_error': True, 'result': "You've hit your limit", 'session_id': '#{@session_id}'}), flush=True)
          sys.exit(1)
      if prompt in ['assistant_auth', 'assistant_limit']:
          print(json.dumps({'type': 'assistant', 'error': 'authentication_failed' if prompt == 'assistant_auth' else 'rate_limit'}), flush=True)
          sys.exit(1)
      if prompt == 'api_key_source':
          print(json.dumps({'type': 'system', 'subtype': 'init', 'apiKeySource': 'ANTHROPIC_API_KEY'}), flush=True)
          time.sleep(10)
      if prompt == 'malformed':
          print('{invalid-json}', flush=True)
          sys.exit(0)
      if prompt == 'oversized_stream':
          print('a' * 4194305, flush=True)
          sys.exit(0)
      if prompt == 'missing_stderr': os.unlink('.symphony/claude/turn.stderr.log')
      with open(#{inspect(@fixture)}) as f:
          events = [json.loads(line) for line in f]
      if prompt == 'result_error': events[-1]['is_error'] = True
      if prompt == 'fragmented':
          events.insert(1, {'type': 'system', 'subtype': 'api_retry', 'error': 'overloaded'})
          events[-2]['message']['content'] = [{'type': 'tool_use', 'id': 'tool_fixture', 'name': 'Read', 'input': {}}, {'type': 'text', 'text': 'a' * 1048577}]
      if prompt == 'blank_session': events[-1]['session_id'] = '  '
      if prompt == 'missing_result': events = events[:-1]
      if prompt == 'hang': events = events[:1]
      for event in events:
          print(json.dumps(event), flush=True)
          if prompt == 'wait_cleanup' and event.get('subtype') == 'init':
              for _ in range(200):
                  if os.path.exists('.symphony/release'): break
                  time.sleep(0.01)
              else: sys.exit(60)
      if prompt == 'hang': time.sleep(10)
      sys.exit(24 if prompt == 'success_nonzero' else 0)
      """)

      File.chmod!(path, 0o755)
    end
  end
end
