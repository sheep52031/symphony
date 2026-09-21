defmodule SymphonyElixir.Antigravity.BackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentBackend, Config.Schema}
  alias SymphonyElixir.Antigravity.{Backend, Launcher}

  test "registers AntiGravity without changing the Codex default or Pi support" do
    assert MapSet.new(AgentBackend.supported_names()) == MapSet.new(["antigravity", "codex", "pi"])
    assert {:ok, :antigravity, Backend} = AgentBackend.resolve("antigravity")
    assert {:ok, :pi, SymphonyElixir.Pi.Backend} = AgentBackend.resolve("pi")

    assert {:ok, settings} = Schema.parse(%{})
    assert settings.agent.backend == "codex"
  end

  test "parses explicit local configuration and rejects missing paths or SSH workers" do
    previous_empty_path = System.get_env("AGY_EMPTY_PATH")
    System.put_env("AGY_EMPTY_PATH", "")
    on_exit(fn -> restore_env("AGY_EMPTY_PATH", previous_empty_path) end)

    assert {:ok, empty_path_settings} =
             Schema.parse(%{"antigravity" => %{"executable" => "$AGY_EMPTY_PATH"}})

    assert is_nil(empty_path_settings.antigravity.executable)

    assert {:ok, settings} =
             Schema.parse(%{
               "agent" => %{"backend" => "antigravity"},
               "antigravity" => %{
                 "executable" => "/opt/agy/bin/agy",
                 "profile_root" => "/var/lib/agy-profile",
                 "first_event_timeout_ms" => 12,
                 "turn_timeout_ms" => 34,
                 "cancel_grace_ms" => 56
               }
             })

    assert settings.antigravity.executable == "/opt/agy/bin/agy"
    assert settings.antigravity.profile_root == "/var/lib/agy-profile"
    assert settings.antigravity.first_event_timeout_ms == 12
    assert settings.antigravity.turn_timeout_ms == 34
    assert settings.antigravity.cancel_grace_ms == 56
    assert :ok = Backend.validate_config(settings)

    assert {:error, :missing_antigravity_executable} =
             Backend.validate_config(%{settings | antigravity: %{settings.antigravity | executable: nil}})

    remote = %{settings | worker: %{settings.worker | ssh_hosts: ["worker-a"]}}

    assert {:error, {:unsupported_backend_worker_hosts, :antigravity}} =
             Backend.validate_config(remote)
  end

  test "builds the mandatory read-only-root Bubblewrap boundary" do
    root = temporary_root("launcher")
    workspace = Path.join(root, "workspace")
    profile = Path.join(root, "profile")
    agy = Path.join(root, "agy")
    bwrap = Path.join(root, "bwrap")
    File.mkdir_p!(workspace)
    File.mkdir_p!(profile)
    write_executable!(agy, "#!/bin/sh\nexit 0\n")
    write_executable!(bwrap, "#!/bin/sh\nexit 0\n")

    assert {:ok, launch} = Launcher.build(workspace, agy, profile, 1_234, bubblewrap_executable: bwrap)
    assert launch.workspace == Path.expand(workspace)
    assert launch.profile_root == Path.expand(profile)
    assert launch.executable == Path.expand(bwrap)
    assert subsequence?(launch.args, ["--unshare-all", "--share-net", "--unshare-user", "--disable-userns"])
    assert subsequence?(launch.args, ["--ro-bind", "/", "/"])
    assert subsequence?(launch.args, ["--bind", Path.expand(workspace), Path.expand(workspace)])

    assert subsequence?(launch.args, [
             "--ro-bind",
             Path.expand(Path.join(workspace, ".symphony")),
             Path.expand(Path.join(workspace, ".symphony"))
           ])

    assert subsequence?(launch.args, ["--bind", Path.expand(profile), Path.expand(profile)])
    assert subsequence?(launch.args, ["--chdir", Path.expand(workspace), "--clearenv"])
    assert subsequence?(launch.args, [agy, "--sandbox", "--mode", "accept-edits"])
    assert List.last(launch.args) == "7s"
    refute "--dangerously-skip-permissions" in launch.args
    refute "--add-dir" in launch.args

    mutable_agy = Path.join(workspace, "agy")
    write_executable!(mutable_agy, "#!/bin/sh\nexit 0\n")

    assert {:error, {:unsafe_antigravity_executable_location, ^mutable_agy}} =
             Launcher.build(workspace, mutable_agy, profile, 1_234, bubblewrap_executable: bwrap)

    File.rm_rf!(root)
  end

  test "rejects an overlapping or whole-home writable profile boundary" do
    root = temporary_root("unsafe-launcher")
    workspace = Path.join(root, "workspace")
    profile = Path.join(workspace, "profile")
    agy = Path.join(root, "agy")
    bwrap = Path.join(root, "bwrap")
    File.mkdir_p!(profile)
    write_executable!(agy, "#!/bin/sh\nexit 0\n")
    write_executable!(bwrap, "#!/bin/sh\nexit 0\n")

    assert {:error, {:overlapping_antigravity_write_roots, _, _}} =
             Launcher.build(workspace, agy, profile, 1_000, bubblewrap_executable: bwrap)

    assert {:error, {:unsafe_antigravity_profile_root, _}} =
             Launcher.build(workspace, agy, System.user_home!(), 1_000, bubblewrap_executable: bwrap)

    File.rm_rf!(root)
  end

  test "runs two native turns with one stable identity and cumulative usage" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    previous_secret = System.get_env("AGY_TEST_SECRET")
    System.put_env("AGY_TEST_SECRET", "must-not-reach-worker")
    on_exit(fn -> restore_env("AGY_TEST_SECRET", previous_secret) end)

    configure_backend!(agy, profile)
    on_message = fn message -> send(self(), {:agy_message, message}) end

    assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)
    issue = %{id: "issue-agy", identifier: "JARVIS-907", title: "AntiGravity adapter"}

    assert {:ok, first} = Backend.run_turn(session, "first", issue, on_message: on_message)
    assert first.session_id == "agy-session"
    assert first.result == "done-1"
    assert first.num_turns == 1
    assert first.usage["total_tokens"] == 15
    assert first.backend == :antigravity

    assert_receive {:agy_message,
                    %{
                      event: :session_started,
                      session_id: "agy-session",
                      permission_mode: "request-review",
                      raw: init_raw
                    }}

    assert_receive {:agy_message, %{event: :step_update, assistant_text_delta: "working-1", raw: step_raw}}
    assert_receive {:agy_message, %{event: :native_result, status: "SUCCESS", raw: result_raw}}
    refute init_raw =~ "account_identifier"
    refute step_raw =~ "private_tool_argument"
    refute result_raw =~ "provider_private_field"
    assert_receive {:agy_message, %{event: :usage, usage: %{"total_tokens" => 15}}}
    assert_receive {:agy_message, %{event: :turn_completed}}

    assert {:ok, second} = Backend.run_turn(session, "second", issue, on_message: on_message)
    assert second.session_id == "agy-session"
    assert second.result == "done-2"
    assert second.num_turns == 2
    assert second.usage["total_tokens"] == 30
    refute_receive {:agy_message, %{event: :session_started}}, 20

    assert File.read!(session.stderr_path) == "fake agy stderr\n"
    assert :ok = Backend.stop_session(session)
    refute File.exists?(session.stderr_path)
    refute File.exists?(session.transport.process_group_path)
    File.rm_rf!(root)
  end

  test "surfaces permission denial instead of silently completing" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    on_message = fn message -> send(self(), {:agy_message, message}) end
    issue = %{id: "issue-denied", identifier: "JARVIS-907", title: "Denied action"}

    assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)

    assert {:error, {:antigravity_input_required, %{status: "SUCCESS", denied_actions_count: 1}}} =
             Backend.run_turn(session, "permission", issue, on_message: on_message)

    assert_receive {:agy_message, %{event: :input_required, payload: %{"denied_actions_count" => 1}}}
    refute_receive {:agy_message, %{event: :turn_completed}}
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "fails closed on a native identity mismatch" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    issue = %{id: "issue-mismatch", identifier: "JARVIS-907", title: "Identity mismatch"}

    assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)

    assert {:error, :antigravity_identity_mismatch} =
             Backend.run_turn(session, "identity_mismatch", issue, [])

    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "rejects unsafe init, duplicate init, and non-cumulative usage" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    issue = %{id: "issue-strict", identifier: "JARVIS-907", title: "Strict protocol"}

    assert {:ok, unsafe_session} = Backend.start_session(workspace, launcher: &direct_launcher/5)

    assert {:error, {:unsafe_antigravity_permission_mode, "always-proceed"}} =
             Backend.run_turn(unsafe_session, "unsafe_permission", issue, [])

    assert :ok = Backend.stop_session(unsafe_session)

    second_workspace = Path.join(root, "workspace-two")
    File.mkdir_p!(second_workspace)
    assert {:ok, duplicate_session} = Backend.start_session(second_workspace, launcher: &direct_launcher/5)
    assert {:ok, _first} = Backend.run_turn(duplicate_session, "first", issue, [])
    assert {:error, :duplicate_antigravity_init} = Backend.run_turn(duplicate_session, "duplicate_init", issue, [])
    assert :ok = Backend.stop_session(duplicate_session)

    third_workspace = Path.join(root, "workspace-three")
    File.mkdir_p!(third_workspace)
    assert {:ok, usage_session} = Backend.start_session(third_workspace, launcher: &direct_launcher/5)
    assert {:ok, _first} = Backend.run_turn(usage_session, "first", issue, [])

    assert {:error, {:noncumulative_antigravity_usage, _previous, _current}} =
             Backend.run_turn(usage_session, "noncumulative", issue, [])

    assert :ok = Backend.stop_session(usage_session)
    File.rm_rf!(root)
  end

  test "rejects malformed and oversized stdout with bounded cleanup" do
    for prompt <- ["malformed", "oversized"] do
      {root, workspace, profile, agy} = setup_fake_agy!()
      configure_backend!(agy, profile)
      issue = %{id: "issue-frame", identifier: "JARVIS-907", title: "Frame bounds"}
      assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)

      case prompt do
        "malformed" ->
          assert {:error, {:malformed_antigravity_protocol_line, :invalid_json}} =
                   Backend.run_turn(session, prompt, issue, [])

        "oversized" ->
          assert {:error, :antigravity_protocol_frame_too_large} =
                   Backend.run_turn(session, prompt, issue, [])
      end

      assert :ok = Backend.stop_session(session)
      File.rm_rf!(root)
    end
  end

  test "normal stop reaps a native descendant in the owned process group" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    issue = %{id: "issue-tree", identifier: "JARVIS-907", title: "Tree cleanup"}
    assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)
    assert {:ok, _turn} = Backend.run_turn(session, "descendant", issue, [])
    child_pid = workspace |> Path.join("child.pid") |> File.read!() |> String.trim()
    assert process_alive?(child_pid)
    assert :ok = Backend.stop_session(session)
    refute process_alive?(child_pid)
    File.rm_rf!(root)
  end

  test "bounds a silent turn, initiates cancellation, and empties the process group" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile, first_event_timeout_ms: 30, turn_timeout_ms: 200, cancel_grace_ms: 100)
    issue = %{id: "issue-timeout", identifier: "JARVIS-907", title: "Timeout"}
    on_message = fn message -> send(self(), {:agy_message, message}) end

    assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)

    assert {:error, {:antigravity_turn_timeout, :first_event, terminal}} =
             Backend.run_turn(session, "silent", issue, on_message: on_message)

    assert is_map(terminal)
    assert_receive {:agy_message, %{event: :turn_aborted, payload: %{"locally_initiated" => true}}}
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "remains local-only at session start" do
    workspace = temporary_root("remote")
    File.mkdir_p!(workspace)

    assert {:error, {:unsupported_backend_worker_host, :antigravity, "worker-a"}} =
             Backend.start_session(workspace, worker_host: "worker-a")

    File.rm_rf!(workspace)
  end

  test "rejects a symlinked host runtime metadata directory" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    metadata_target = Path.join(root, "metadata-target")
    File.mkdir_p!(metadata_target)
    File.ln_s!(metadata_target, Path.join(workspace, ".symphony"))

    assert {:error, {:unsafe_antigravity_runtime_path, runtime_path, :symlink}} =
             Backend.start_session(workspace, launcher: &direct_launcher/5)

    assert runtime_path == Path.join(workspace, ".symphony")
    assert File.ls!(metadata_target) == []
    File.rm_rf!(root)
  end

  defp configure_backend!(agy, profile, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          agent_backend: "antigravity",
          antigravity_executable: agy,
          antigravity_profile_root: profile,
          antigravity_first_event_timeout_ms: 500,
          antigravity_turn_timeout_ms: 1_000,
          antigravity_cancel_grace_ms: 200
        ],
        overrides
      )
    )
  end

  defp setup_fake_agy! do
    root = temporary_root("backend")
    workspace = Path.join(root, "workspace")
    profile = Path.join(root, "profile")
    agy = Path.join(root, "fake-agy")
    File.mkdir_p!(workspace)
    File.mkdir_p!(profile)
    write_fake_agy!(agy)
    {root, workspace, profile, agy}
  end

  defp direct_launcher(workspace, agy, profile, _turn_timeout_ms, _opts) do
    {:ok,
     %{
       executable: Path.expand(agy),
       args: [],
       workspace: Path.expand(workspace),
       profile_root: Path.expand(profile),
       agy_executable: Path.expand(agy)
     }}
  end

  defp write_fake_agy!(path) do
    write_executable!(path, """
    #!/bin/sh
    [ -z "${AGY_TEST_SECRET:-}" ] || exit 12
    [ -z "${LINEAR_API_KEY:-}" ] || exit 13
    printf '%s\n' 'fake agy stderr' >&2
    turn=0
    interrupted=0
    trap 'interrupted=1' INT
    while IFS= read -r line; do
      turn=$((turn + 1))
      if [ "$turn" -eq 1 ]; then
        case "$line" in
          *unsafe_permission*) printf '{"event":"init","conversation_id":"agy-session","init":{"cwd":"%s","permission_mode":"always-proceed"}}\n' "$PWD" ;;
          *workspace_mismatch*) printf '%s\n' '{"event":"init","conversation_id":"agy-session","init":{"cwd":"/wrong","permission_mode":"request-review"}}' ;;
          *) printf '{"event":"init","conversation_id":"agy-session","init":{"cwd":"%s","permission_mode":"request-review","account_identifier":"must-not-forward"}}\n' "$PWD" ;;
        esac
      fi
      case "$line" in
        *identity_mismatch*)
          printf '%s\n' '{"event":"step_update","step_update":{"conversation_id":"other-session","step_type":"text","text_delta":"bad"}}'
          ;;
        *permission*)
          printf '{"event":"step_update","step_update":{"conversation_id":"agy-session","step_type":"tool"}}\n'
          printf '{"event":"result","result":{"conversation_id":"agy-session","status":"SUCCESS","response":"blocked","duration_seconds":1,"num_turns":%s,"usage":{"input_tokens":10,"output_tokens":3,"thinking_tokens":2,"cache_read_tokens":0,"total_tokens":15},"denied_actions":[{"action":"command(test)","display_name":"test"}]}}\n' "$turn"
          ;;
        *duplicate_init*)
          printf '{"event":"init","conversation_id":"agy-session","init":{"cwd":"%s","permission_mode":"request-review"}}\n' "$PWD"
          ;;
        *noncumulative*)
          printf '{"event":"result","result":{"conversation_id":"agy-session","status":"SUCCESS","response":"bad-usage","duration_seconds":1,"num_turns":%s,"usage":{"input_tokens":1,"output_tokens":1,"thinking_tokens":1,"cache_read_tokens":0,"total_tokens":3}}}\n' "$turn"
          ;;
        *malformed*)
          printf '%s\n' 'not-json'
          ;;
        *oversized*)
          head -c 1100000 /dev/zero | tr '\\000' x
          printf '\n'
          ;;
        *descendant*)
          sleep 30 &
          printf '%s' "$!" > "$PWD/child.pid"
          input=$((turn * 10)); output=$((turn * 3)); thinking=$((turn * 2)); total=$((turn * 15))
          printf '{"event":"step_update","step_update":{"conversation_id":"agy-session","step_type":"text","text_delta":"spawned"}}\n'
          printf '{"event":"result","result":{"conversation_id":"agy-session","status":"SUCCESS","response":"descendant","duration_seconds":1,"num_turns":%s,"usage":{"input_tokens":%s,"output_tokens":%s,"thinking_tokens":%s,"cache_read_tokens":0,"total_tokens":%s}}}\n' "$turn" "$input" "$output" "$thinking" "$total"
          ;;
        *silent*)
          sleep 10
          if [ "$interrupted" -eq 1 ]; then
            printf '{"event":"result","result":{"conversation_id":"agy-session","status":"ERROR","response":"","error":"interrupted","duration_seconds":0,"num_turns":%s,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0}}}\n' "$turn"
          fi
          ;;
        *)
          input=$((turn * 10)); output=$((turn * 3)); thinking=$((turn * 2)); total=$((turn * 15))
          printf '{"event":"step_update","step_update":{"conversation_id":"agy-session","step_type":"text","text_delta":"working-%s","private_tool_argument":"must-not-forward"}}\n' "$turn"
          printf '{"event":"result","result":{"conversation_id":"agy-session","status":"SUCCESS","response":"done-%s","duration_seconds":1,"num_turns":%s,"usage":{"input_tokens":%s,"output_tokens":%s,"thinking_tokens":%s,"cache_read_tokens":0,"total_tokens":%s},"provider_private_field":"must-not-forward"}}\n' "$turn" "$turn" "$input" "$output" "$thinking" "$total"
          ;;
      esac
    done
    """)
  end

  defp write_executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp temporary_root(label) do
    Path.join(System.tmp_dir!(), "symphony-antigravity-#{label}-#{System.unique_integer([:positive])}")
  end

  defp process_alive?(pid) do
    match?({_output, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  end

  defp subsequence?(list, expected) do
    expected_length = length(expected)

    Enum.any?(0..max(length(list) - expected_length, 0), fn index ->
      Enum.slice(list, index, expected_length) == expected
    end)
  end
end
