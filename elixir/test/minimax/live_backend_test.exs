# Owner-gated real check. Run one genuine MiniMax Code turn through the Symphony backend on a
# host where the operator already completed `mcode login`. No network fixture, no fake CLI, and
# the credential is never read by the test: the backend only passes the data directory path.
#
#   SYMPHONY_RUN_LIVE_MINIMAX=1 mix test test/minimax/live_backend_test.exs
#
# The host must have the MiniMax Code CLI on disk. Set MINIMAX_MCODE_PATH when it is not at the
# default package location.
if System.get_env("SYMPHONY_RUN_LIVE_MINIMAX") == "1" do
  defmodule SymphonyElixir.MiniMax.LiveBackendTest do
    use SymphonyElixir.TestSupport

    alias SymphonyElixir.{MiniMax.Backend, Workflow, WorkflowStore}

    @turn_ms 300_000
    # Captured at compile time: the test harness replaces HOME during setup, but the operator's
    # credential lives in the real profile directory.
    @real_home System.get_env("HOME") || System.user_home!()

    setup do
      suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      root = Path.join(System.tmp_dir!(), "symphony-minimax-live-#{suffix}")
      workspace = Path.join(root, "workspace")
      File.mkdir_p!(workspace)

      command = System.get_env("MINIMAX_MCODE_PATH") || default_command()
      data_dir = System.get_env("MINIMAX_DATA_DIR") || default_data_dir()

      on_exit(fn -> File.rm_rf!(root) end)

      write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "minimax", workspace_root: root)

      path = Workflow.workflow_file_path()
      fields = "  command: #{Jason.encode!(command)}\n  data_dir: #{Jason.encode!(data_dir)}\n"

      File.write!(path, File.read!(path) |> String.replace_prefix("---\n", "---\nminimax:\n#{fields}\n"))
      assert :ok == WorkflowStore.force_reload()

      {:ok, root: root, workspace: workspace, command: command, data_dir: data_dir}
    end

    test "a real MiniMax Code turn completes with the final text", context do
      assert {:ok, session} = Backend.start_session(context.workspace)

      assert {:ok, %{session_id: session_id, result: %{"result" => text}, backend: :minimax}} =
               Backend.run_turn(session, "Reply with exactly: OK", %{}, run_options(self()))

      assert is_binary(session_id) and String.trim(session_id) != ""
      assert is_binary(text) and String.trim(text) != ""
      assert :ok = Backend.stop_session(session)
    end

    test "a second real turn resumes the same MiniMax Code session", context do
      assert {:ok, session} = Backend.start_session(context.workspace)
      assert {:ok, %{session_id: first}} = Backend.run_turn(session, "Reply with exactly: OK", %{}, run_options(self()))
      assert {:ok, %{session_id: second}} = Backend.run_turn(session, "Reply with exactly: OK", %{}, run_options(self()))
      assert first == second
      assert :ok = Backend.stop_session(session)
    end

    test "a real turn whose answer contains braces still completes", context do
      assert {:ok, session} = Backend.start_session(context.workspace)

      prompt = "Reply with exactly this Rust code and nothing else: fn main() { println!(\"hi\"); }"

      assert {:ok, %{session_id: session_id, result: %{"result" => text}}} =
               Backend.run_turn(session, prompt, %{}, run_options(self()))

      assert is_binary(session_id) and String.trim(session_id) != ""
      assert text =~ "{"
      assert :ok = Backend.stop_session(session)
    end

    defp run_options(caller) do
      [timeout_ms: @turn_ms, on_message: fn update -> send(caller, {:update, update}) end]
    end

    defp default_command do
      Path.join(@real_home, ".minimax/packages/app-server-daemon/bin/mcode")
    end

    defp default_data_dir, do: Path.join(@real_home, ".minimax")
  end
end
