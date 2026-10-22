# Stored NDJSON follows the MiniMax Code `exec --output-format stream-json` event schema. A fake
# executable replays it; no test reaches the network or reads a credential.
if "minimax" in SymphonyElixir.AgentBackend.supported_names() do
  defmodule SymphonyElixir.MiniMax.BackendTest do
    use SymphonyElixir.TestSupport

    alias SymphonyElixir.{AgentBackend, MiniMax.Backend, Workflow, WorkflowStore}

    @session_id "session-fixture-1"
    @turn_ms 2_000
    @fixture Path.expand("fixtures/run.jsonl", __DIR__)

    setup do
      suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      root = Path.join(System.tmp_dir!(), "symphony-minimax-#{suffix}")
      workspace = Path.join(root, "workspace")
      data_dir = Path.join(root, "minimax-data")
      script = Path.join(root, "mcode")
      File.mkdir_p!(workspace)
      File.mkdir_p!(data_dir)
      write_fake_mcode!(script)
      previous_home = System.get_env("HOME")
      previous_key = System.get_env("MINIMAX_API_KEY")
      System.put_env("HOME", root)
      System.put_env("MINIMAX_API_KEY", "sk-should-never-reach-the-child")

      on_exit(fn ->
        restore_env("HOME", previous_home)
        restore_env("MINIMAX_API_KEY", previous_key)
        File.rm_rf!(root)
      end)

      write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "minimax", workspace_root: root)
      configure_minimax!(%{"command" => script, "data_dir" => data_dir})

      {:ok, root: root, workspace: workspace, data_dir: data_dir, script: script}
    end

    test "registers the backend as local-only and rejects malformed configuration", context do
      assert {:ok, :minimax, Backend} = AgentBackend.resolve("minimax")
      assert AgentBackend.local_only?("minimax")
      refute AgentBackend.worker_host_compatible?("minimax", "remote-host")

      assert {:error, {:unsupported_backend_worker_hosts, :minimax}} =
               Backend.validate_config(%{worker: %{ssh_hosts: ["ssh-worker"]}, minimax: %{}})

      assert {:error, {:unsupported_backend_worker_host, :minimax, "ssh-worker"}} =
               Backend.start_session(context.workspace, worker_host: "ssh-worker")

      for raw <- [nil, "not a map", %{"command" => ""}, %{"data_dir" => " "}, %{"max_steps" => 0}, %{"model" => " "}] do
        assert {:error, {:invalid_minimax_config, _}} = Backend.validate_config(%{minimax: raw})
      end

      missing = Path.join(context.root, "missing-mcode")

      assert {:error, {:backend_executable_not_found, :minimax, ^missing}} =
               Backend.validate_config(%{minimax: %{"command" => missing, "data_dir" => context.data_dir}})

      assert {:error, {:workspace_not_found, _}} = Backend.start_session(Path.join(context.root, "gone"))
    end

    test "normal turn streams events, reports usage and completes with the final text", context do
      assert {:ok, session} = Backend.start_session(context.workspace)

      assert {:ok, %{session_id: @session_id, result: %{"result" => "Done."}, backend: :minimax}} =
               Backend.run_turn(session, "ok", %{}, run_options(self()))

      updates = drain([])
      assert %{event: :session_started, session_id: @session_id} = Enum.find(updates, &(&1.event == :session_started))
      assert Enum.any?(updates, &(&1[:assistant_text_delta] == "I'll create the file."))
      assert Enum.any?(updates, &(&1[:assistant_text] == "I'll create the file."))
      assert %{usage: usage} = updates |> Enum.filter(&(&1.event == :usage)) |> List.last()
      assert usage["totalTokens"] == 8724
      assert %{event: :turn_completed, session_id: @session_id} = List.last(updates)

      assert [first | _] = calls(context.workspace)
      assert first =~ "exec"
      assert first =~ "--output-format stream-json"
      assert first =~ "--permission full"
      assert first =~ "--input -"
      assert first =~ "--max-steps 60"

      assert File.read!(Path.join(context.workspace, ".symphony/minimax/data-dir.txt")) == context.data_dir <> "\n"
      assert :ok = Backend.stop_session(session)
    end

    test "a second turn resumes the first turn's session id", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, %{session_id: @session_id}} = Backend.run_turn(session, "ok", %{}, run_options(self()))
      assert {:ok, %{session_id: @session_id}} = Backend.run_turn(session, "ok", %{}, run_options(self()))

      assert [_, second] = calls(context.workspace)
      assert second =~ "--session #{@session_id}"
      assert :ok = Backend.stop_session(session)
    end

    test "the child environment carries the data directory path and no credential", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, _} = Backend.run_turn(session, "ok", %{}, run_options(self()))

      assert File.read!(Path.join(context.workspace, ".symphony/minimax/api-key.txt")) == "\n"
      assert :ok = Backend.stop_session(session)
    end

    test "non-zero exit fails the turn and reports the error update", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:error, {:minimax_exit, 23}} = Backend.run_turn(session, "exit-nonzero", %{}, run_options(self()))
      assert Enum.any?(drain([]), &(&1.event == :turn_ended_with_error))
      assert :ok = Backend.stop_session(session)
    end

    test "a failed turn reports a typed error", context do
      assert {:ok, session} = Backend.start_session(context.workspace)

      assert {:error, {:minimax_turn_failed, %{"status" => "failed"}}} =
               Backend.run_turn(session, "turn-failed", %{}, run_options(self()))

      assert :ok = Backend.stop_session(session)
    end

    test "a missing sign-in fails with a typed error", context do
      assert {:ok, session} = Backend.start_session(context.workspace)

      assert {:error, :minimax_not_logged_in} =
               Backend.run_turn(session, "not-logged-in", %{}, run_options(self()))

      assert :ok = Backend.stop_session(session)
    end

    test "a usage limit fails with a typed error", context do
      assert {:ok, session} = Backend.start_session(context.workspace)

      assert {:error, :minimax_usage_limit} =
               Backend.run_turn(session, "usage-limit", %{}, run_options(self()))

      assert :ok = Backend.stop_session(session)
    end

    test "a turn without a result fails", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:error, {:minimax_exit, 0}} = Backend.run_turn(session, "no-result", %{}, run_options(self()))
      assert :ok = Backend.stop_session(session)
    end

    test "an oversized stream fails the turn", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:error, :minimax_stream_too_large} = Backend.run_turn(session, "huge", %{}, run_options(self()))
      assert :ok = Backend.stop_session(session)
    end

    test "the turn timeout fails and stops the CLI process group", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:error, :minimax_turn_timeout} = Backend.run_turn(session, "silent", %{}, run_options(self()))
      assert :ok = Backend.stop_session(session)
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
      workspace |> Path.join(".symphony/minimax/calls.txt") |> File.read!() |> String.split("\n", trim: true)
    end

    defp configure_minimax!(config) do
      path = Workflow.workflow_file_path()
      fields = Enum.map_join(config, "\n", fn {key, value} -> "  #{key}: #{Jason.encode!(value)}" end)
      content = File.read!(path) |> String.replace_prefix("---\n", "---\nminimax:\n#{fields}\n")
      File.write!(path, content)
      assert :ok == WorkflowStore.force_reload()
    end

    defp write_fake_mcode!(path) do
      File.write!(
        path,
        ~S"""
        #!/bin/bash
        # Fake MiniMax Code CLI: records argv and the data directory, then replays the stored stream.
        mkdir -p .symphony/minimax
        session=""
        previous=""
        for argument in "$@"; do
          if [ "$previous" = "--session" ]; then session="$argument"; fi
          previous="$argument"
        done
        [ -n "$session" ] || session="session-fixture-1"
        prompt=$(cat)
        printf '%s\n' "$*" >> .symphony/minimax/calls.txt
        printf '%s\n' "$MINIMAX_DATA_DIR" > .symphony/minimax/data-dir.txt
        printf '%s\n' "${MINIMAX_API_KEY-}" > .symphony/minimax/api-key.txt
        case "$prompt" in
          exit-nonzero) exit 23 ;;
          not-logged-in)
            echo "mcode exec failed: Sign in to MiniMax to use Agent features. Run 'mcode login', then retry." >&2
            exit 1
            ;;
          usage-limit)
            echo "mcode exec failed: usage limit reached for this account" >&2
            exit 1
            ;;
          turn-failed)
            printf '{"type":"turn.failed","status":"failed","error":{"category":"runtime","code":"TURN_FAILED","message":"boom"}}\n'
            exit 0
            ;;
          no-result) exit 0 ;;
          huge) head -c 12000000 /dev/zero | tr '\0' a ; sleep 3 ;;
          silent) sleep 60 ;;
        esac
        cat FIXTURE_PATH
        """
        |> String.replace("FIXTURE_PATH", @fixture)
      )

      File.chmod!(path, 0o755)
    end
  end
end
