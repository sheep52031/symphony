# Stored NDJSON follows the DeepSeek Harness headless event schema. A fake executable replays it;
# no test reaches the network or reads a credential.
if "deepseek" in SymphonyElixir.AgentBackend.supported_names() do
  defmodule SymphonyElixir.Deepseek.BackendTest do
    use SymphonyElixir.TestSupport

    alias SymphonyElixir.{AgentBackend, Deepseek.Backend, Workflow, WorkflowStore}

    @session_id "session-fixture-1"
    @turn_ms 2_000
    @fixture Path.expand("fixtures/run.jsonl", __DIR__)

    setup do
      suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      root = Path.join(System.tmp_dir!(), "symphony-deepseek-#{suffix}")
      workspace = Path.join(root, "workspace")
      dsh_home = Path.join(root, "dsh-home")
      script = Path.join(root, "dsh")
      File.mkdir_p!(workspace)
      File.mkdir_p!(dsh_home)
      write_fake_dsh!(script)
      previous_home = System.get_env("HOME")
      System.put_env("HOME", root)

      on_exit(fn ->
        restore_env("HOME", previous_home)
        File.rm_rf!(root)
      end)

      write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "deepseek", workspace_root: root)
      configure_deepseek!(%{"command" => script, "dsh_home" => dsh_home})

      {:ok, root: root, workspace: workspace, dsh_home: dsh_home, script: script}
    end

    test "registers the backend as local-only and rejects malformed or reserved configuration", context do
      assert {:ok, :deepseek, Backend} = AgentBackend.resolve("deepseek")
      assert AgentBackend.local_only?("deepseek")
      refute AgentBackend.worker_host_compatible?("deepseek", "remote-host")

      assert {:error, {:unsupported_backend_worker_hosts, :deepseek}} =
               Backend.validate_config(%{worker: %{ssh_hosts: ["ssh-worker"]}, deepseek: %{}})

      assert {:error, {:unsupported_backend_worker_host, :deepseek, "ssh-worker"}} =
               Backend.start_session(context.workspace, worker_host: "ssh-worker")

      for raw <- [nil, "not a map", %{"command" => ""}, %{"dsh_home" => nil}, %{"dsh_home" => " "}] do
        assert {:error, {:invalid_deepseek_config, _}} = Backend.validate_config(%{deepseek: raw})
      end

      reserved = Path.join(context.root, ".dsh")

      for home <- [reserved, Path.join(reserved, "sub")] do
        assert {:error, {:invalid_deepseek_config, _}} =
                 Backend.validate_config(%{deepseek: %{"command" => context.script, "dsh_home" => home}})
      end

      missing = Path.join(context.root, "missing-dsh")

      assert {:error, {:backend_executable_not_found, :deepseek, ^missing}} =
               Backend.validate_config(%{deepseek: %{"command" => missing, "dsh_home" => context.dsh_home}})

      assert {:error, {:workspace_not_found, _}} = Backend.start_session(Path.join(context.root, "gone"))
    end

    test "normal turn streams events, sums usage and completes with the final text", context do
      assert {:ok, session} = Backend.start_session(context.workspace)

      assert {:ok, %{session_id: @session_id, result: %{"result" => "Done."}, backend: :deepseek}} =
               Backend.run_turn(session, "ok", %{}, run_options(self()))

      updates = drain([])
      assert %{event: :session_started, session_id: @session_id} = Enum.find(updates, &(&1.event == :session_started))
      assert Enum.any?(updates, &(&1[:assistant_text_delta] == "I'll create the file."))
      assert Enum.count(updates, &(&1.event == :notification)) >= 2
      assert %{event: :turn_completed, session_id: @session_id} = List.last(updates)

      # Per-step usage is summed across the session: cached context counts on every step.
      assert %{usage: usage} = updates |> Enum.filter(&(&1.event == :usage)) |> List.last()
      assert usage == %{"input_tokens" => 17_420, "output_tokens" => 79, "total_tokens" => 17_499}

      assert [first | _] = calls(context.workspace)
      assert first == "--profile headless --json -"
      assert File.read!(Path.join(context.workspace, ".symphony/deepseek/dsh-home.txt")) == context.dsh_home <> "\n"
      assert :ok = Backend.stop_session(session)
    end

    test "a second turn resumes the first turn's session id", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, %{session_id: @session_id}} = Backend.run_turn(session, "ok", %{}, run_options(self()))
      assert {:ok, %{session_id: @session_id}} = Backend.run_turn(session, "ok", %{}, run_options(self()))

      assert [_, second] = calls(context.workspace)
      assert second == "--profile headless --json --session-id #{@session_id} -"
      assert :ok = Backend.stop_session(session)
    end

    test "a resumed session the harness does not know fails with a typed error", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, _} = Backend.run_turn(session, "ok", %{}, run_options(self()))

      assert {:error, {:deepseek_unknown_session, @session_id}} =
               Backend.run_turn(session, "unknown", %{}, run_options(self()))

      assert :ok = Backend.stop_session(session)
    end

    test "non-zero exit fails the turn and reports the error update", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:error, {:deepseek_exit, 23}} = Backend.run_turn(session, "exit-nonzero", %{}, run_options(self()))
      assert Enum.any?(drain([]), &(&1.event == :turn_ended_with_error))
      assert :ok = Backend.stop_session(session)
    end

    test "a turn that ends with a non-completed reason fails", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:error, {:deepseek_turn_failed, "error"}} = Backend.run_turn(session, "turn-error", %{}, run_options(self()))
      assert :ok = Backend.stop_session(session)
    end

    test "a malformed stdout line fails the turn", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:error, :deepseek_invalid_stream_json} = Backend.run_turn(session, "bad-json", %{}, run_options(self()))
      assert :ok = Backend.stop_session(session)
    end

    test "turn timeout fails the turn and terminates the harness process", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:error, :deepseek_turn_timeout} = Backend.run_turn(session, "hang", %{}, timeout_ms: 300)
      pid = context.workspace |> Path.join(".symphony/deepseek/pid") |> File.read!() |> String.trim()
      assert_eventually(fn -> not process_alive?(pid) end)
      assert :ok = Backend.stop_session(session)
    end

    test "silence longer than the stall timeout fails the turn", context do
      assert {:ok, session} = Backend.start_session(context.workspace)

      assert {:error, :deepseek_stall_timeout} =
               Backend.run_turn(session, "silent", %{}, timeout_ms: 5_000, stall_timeout_ms: 200)

      pid = context.workspace |> Path.join(".symphony/deepseek/pid") |> File.read!() |> String.trim()
      assert_eventually(fn -> not process_alive?(pid) end)
      assert :ok = Backend.stop_session(session)
    end

    test "a stalled turn also terminates grandchild processes of the harness", context do
      assert {:ok, session} = Backend.start_session(context.workspace)

      assert {:error, :deepseek_stall_timeout} =
               Backend.run_turn(session, "grandchild", %{}, timeout_ms: 5_000, stall_timeout_ms: 400)

      pid = context.workspace |> Path.join(".symphony/deepseek/grandchild-pid") |> File.read!() |> String.trim()
      assert_eventually(fn -> not process_alive?(pid) end)
      assert :ok = Backend.stop_session(session)
    end

    test "a zero stall timeout disables the silence watchdog", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, _} = Backend.run_turn(session, "ok", %{}, run_options(self(), stall_timeout_ms: 0))
      assert :ok = Backend.stop_session(session)
    end

    test "a workspace removed after start fails the turn before the harness runs", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      File.rm_rf!(context.workspace)

      assert {:error, {:deepseek_start_failed, _, {:workspace_not_found, _}}} =
               Backend.run_turn(session, "ok", %{}, run_options(self()))

      assert :ok = Backend.stop_session(session)
    end

    test "a turn on a stopped session fails instead of crashing the caller", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert :ok = Backend.stop_session(session)
      assert {:error, {:deepseek_session_exit, _}} = Backend.run_turn(session, "ok", %{}, run_options(self()))
      assert :ok = Backend.stop_session(session)
    end

    test "the harness stops when the session owner exits", context do
      session =
        Task.async(fn ->
          assert {:ok, session} = Backend.start_session(context.workspace)
          session
        end)
        |> Task.await()

      assert_eventually(fn -> not Process.alive?(session) end)
    end

    test "a harness session killed mid-turn fails the waiting caller", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      parent = self()

      spawn(fn ->
        send(parent, {:killed, Backend.run_turn(session, "silent", %{}, run_options(parent, timeout_ms: 5_000))})
      end)

      assert_eventually(fn -> harness_pid(context.workspace) != "" end)
      Process.exit(session, :kill)
      assert_receive {:killed, {:error, {:deepseek_session_exit, :killed}}}, 2_000
      kill_group(harness_pid(context.workspace))
    end

    test "a busy session refuses a second turn and an abandoned caller ends the first", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      parent = self()

      caller =
        spawn(fn -> send(parent, {:first, Backend.run_turn(session, "silent", %{}, run_options(parent))}) end)

      assert_eventually(fn -> harness_pid(context.workspace) != "" end)
      assert {:error, :deepseek_turn_in_progress} = Backend.run_turn(session, "ok", %{}, run_options(self()))

      pid = harness_pid(context.workspace)
      Process.exit(caller, :kill)
      assert_eventually(fn -> not process_alive?(pid) end)

      assert {:ok, _} = Backend.run_turn(session, "ok", %{}, run_options(self()))
      assert :ok = Backend.stop_session(session)
    end

    test "a stdout line over 4 MB fails the turn", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:error, :deepseek_stream_line_too_large} = Backend.run_turn(session, "huge", %{}, run_options(self()))
      assert :ok = Backend.stop_session(session)
    end

    test "usage with non-numeric fields counts as zero", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, _} = Backend.run_turn(session, "partial-usage", %{}, run_options(self()))

      assert %{usage: usage} = drain([]) |> Enum.filter(&(&1.event == :usage)) |> List.last()
      assert usage == %{"input_tokens" => 0, "output_tokens" => 4, "total_tokens" => 4}
      assert :ok = Backend.stop_session(session)
    end

    test "malformed or incomplete harness output fails with a typed reason", context do
      for {prompt, reason} <- [
            {"turn-no-reason", {:deepseek_turn_failed, "unknown"}},
            {"error-first", :deepseek_error_event},
            {"no-session", :deepseek_missing_session_id},
            {"no-final", :deepseek_missing_final}
          ] do
        assert {:ok, session} = Backend.start_session(context.workspace)
        assert {:error, ^reason} = Backend.run_turn(session, prompt, %{}, run_options(self()))
        assert :ok = Backend.stop_session(session)
      end
    end

    defp harness_pid(workspace) do
      case File.read(Path.join(workspace, ".symphony/deepseek/pid")) do
        {:ok, text} -> String.trim(text)
        {:error, _} -> ""
      end
    end

    defp kill_group(pid) do
      System.cmd("kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
      :ok
    end

    defp run_options(caller, extra \\ []) do
      Keyword.merge([timeout_ms: @turn_ms, on_message: fn update -> send(caller, {:update, update}) end], extra)
    end

    defp drain(acc) do
      receive do
        {:update, update} -> drain([update | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp calls(workspace) do
      workspace |> Path.join(".symphony/deepseek/calls.txt") |> File.read!() |> String.split("\n", trim: true)
    end

    defp configure_deepseek!(config) do
      path = Workflow.workflow_file_path()
      fields = Enum.map_join(config, "\n", fn {key, value} -> "  #{key}: #{Jason.encode!(value)}" end)
      content = File.read!(path) |> String.replace_prefix("---\n", "---\ndeepseek:\n#{fields}\n")
      File.write!(path, content)
      assert :ok == WorkflowStore.force_reload()
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

    defp write_fake_dsh!(path) do
      File.write!(
        path,
        ~S"""
        #!/bin/bash
        # Fake DeepSeek Harness: records argv and DSH_HOME, then replays the stored NDJSON per prompt.
        mkdir -p .symphony/deepseek
        session=""
        previous=""
        for argument in "$@"; do
          if [ "$previous" = "--session-id" ]; then session="$argument"; fi
          previous="$argument"
        done
        [ -n "$session" ] || session="session-fixture-1"
        prompt=$(cat)
        printf '%s\n' "$*" >> .symphony/deepseek/calls.txt
        printf '%s\n' "$DSH_HOME" > .symphony/deepseek/dsh-home.txt
        case "$prompt" in
          unknown)
            printf '{"type":"error","message":"session \\"%s\\" does not exist; omit --session-id to start a new Session"}\n' "$session"
            exit 1
            ;;
          exit-nonzero) exit 23 ;;
          bad-json) printf '%s\n' '{invalid-json'; exit 0 ;;
          turn-error)
            printf '{"type":"session","sessionId":"%s","cwd":"%s"}\n' "$session" "$PWD"
            printf '{"type":"status","phase":"turn_end","turn":1,"reason":{"kind":"error"}}\n'
            exit 0
            ;;
          hang)
            printf '{"type":"session","sessionId":"%s","cwd":"%s"}\n' "$session" "$PWD"
            echo $$ > .symphony/deepseek/pid
            sleep 60
            ;;
          grandchild)
            printf '{"type":"session","sessionId":"%s","cwd":"%s"}\n' "$session" "$PWD"
            (sleep 300 </dev/null >/dev/null 2>&1 & echo $! > .symphony/deepseek/grandchild-pid)
            sleep 60
            ;;
          partial-usage)
            printf '{"type":"session","sessionId":"%s","cwd":"%s"}\n' "$session" "$PWD"
            printf '{"type":"status","phase":"step_end","usage":{"inputTokens":"x","outputTokens":4}}\n'
            printf '{"type":"status","phase":"turn_end","reason":{"kind":"completed"}}\n'
            printf '{"type":"final","text":"Done."}\n'
            exit 0
            ;;
          turn-no-reason)
            printf '{"type":"session","sessionId":"%s","cwd":"%s"}\n' "$session" "$PWD"
            printf '{"type":"status","phase":"turn_end"}\n'
            exit 0
            ;;
          error-first)
            printf '{"type":"error","message":"model unavailable"}\n'
            exit 1
            ;;
          no-session)
            printf '{"type":"status","phase":"turn_end","reason":{"kind":"completed"}}\n'
            printf '{"type":"final","text":"Done."}\n'
            exit 0
            ;;
          no-final)
            printf '{"type":"session","sessionId":"%s","cwd":"%s"}\n' "$session" "$PWD"
            printf '{"type":"status","phase":"turn_end","reason":{"kind":"completed"}}\n'
            exit 0
            ;;
          huge)
            printf '{"type":"session","sessionId":"%s","cwd":"%s"}\n' "$session" "$PWD"
            head -c 4300000 /dev/zero | tr '\0' a
            exit 0
            ;;
          silent)
            echo $$ > .symphony/deepseek/pid
            sleep 60
            ;;
        esac
        printf '{"type":"session","sessionId":"%s","cwd":"%s"}\n' "$session" "$PWD"
        cat FIXTURE_PATH
        """
        |> String.replace("FIXTURE_PATH", @fixture)
      )

      File.chmod!(path, 0o755)
    end
  end
end
