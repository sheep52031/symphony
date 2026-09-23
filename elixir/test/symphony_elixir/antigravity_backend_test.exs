defmodule SymphonyElixir.Antigravity.BackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentBackend, Config.Schema, TerminalFailure}
  alias SymphonyElixir.Antigravity.{Backend, CleanupRegistry, Launcher, Transport}

  setup do
    case System.get_env("HOME") do
      home when is_binary(home) and home != "" -> File.mkdir_p!(home)
      _ -> :ok
    end

    :ok
  end

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
    previous_runtime = System.get_env("XDG_RUNTIME_DIR")
    previous_dbus = System.get_env("DBUS_SESSION_BUS_ADDRESS")
    System.put_env("XDG_RUNTIME_DIR", "/run/user/1000")
    System.put_env("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/user/1000/bus")

    on_exit(fn ->
      restore_env("XDG_RUNTIME_DIR", previous_runtime)
      restore_env("DBUS_SESSION_BUS_ADDRESS", previous_dbus)
    end)

    assert {:ok, launch} = Launcher.build(workspace, agy, profile, 1_234, bubblewrap_executable: bwrap)
    assert launch.workspace == Path.expand(workspace)
    assert launch.profile_root == Path.expand(profile)
    assert launch.executable == Path.expand(bwrap)
    assert subsequence?(launch.args, ["--unshare-all", "--share-net", "--unshare-user", "--disable-userns"])
    assert subsequence?(launch.args, ["--ro-bind", "/", "/"])
    assert subsequence?(launch.args, ["--tmpfs", "/run/user"])
    assert subsequence?(launch.args, ["--tmpfs", "/tmp"])
    assert_home_masked_or_private(launch.args, Path.expand(System.user_home!()))
    assert subsequence?(launch.args, ["--dir", Path.expand(workspace)])
    assert subsequence?(launch.args, ["--dir", Path.expand(profile)])
    assert subsequence?(launch.args, ["--dir", "/tmp/symphony-antigravity-runtime", "--chmod", "0700", "/tmp/symphony-antigravity-runtime"])
    assert subsequence?(launch.args, ["--bind", Path.expand(workspace), Path.expand(workspace)])

    assert subsequence?(launch.args, [
             "--ro-bind",
             Path.expand(Path.join(workspace, ".symphony")),
             Path.expand(Path.join(workspace, ".symphony"))
           ])

    assert subsequence?(launch.args, ["--bind", Path.expand(profile), Path.expand(profile)])
    assert subsequence?(launch.args, ["--ro-bind", Path.expand(agy), "/tmp/symphony-antigravity-agy"])
    assert subsequence?(launch.args, ["--chdir", Path.expand(workspace), "--clearenv"])
    assert subsequence?(launch.args, ["--setenv", "XDG_RUNTIME_DIR", "/tmp/symphony-antigravity-runtime"])
    refute "DBUS_SESSION_BUS_ADDRESS" in launch.args
    refute Enum.any?(launch.args, &(&1 == "/run/user/1000"))
    refute Enum.any?(launch.args, &(&1 == "unix:path=/run/user/1000/bus"))
    assert subsequence?(launch.args, ["/tmp/symphony-antigravity-agy", "--sandbox", "--mode", "accept-edits"])
    refute subsequence?(launch.args, ["--bind", Path.expand(System.user_home!()), Path.expand(System.user_home!())])
    assert List.last(launch.args) == "7s"
    refute "--dangerously-skip-permissions" in launch.args
    refute "--add-dir" in launch.args

    mutable_agy = Path.join(workspace, "agy")
    write_executable!(mutable_agy, "#!/bin/sh\nexit 0\n")

    assert {:error, {:unsafe_antigravity_executable_location, ^mutable_agy}} =
             Launcher.build(workspace, mutable_agy, profile, 1_234, bubblewrap_executable: bwrap)

    File.rm_rf!(root)
  end

  test "rejects unsafe writable roots at both workspace and profile boundaries" do
    root = temporary_root("unsafe-launcher")
    home = Path.expand(System.user_home!())
    home_parent = Path.dirname(home)
    workspace = Path.join(root, "workspace")
    workspace_two = Path.join(System.tmp_dir!(), "symphony-antigravity-workspace-two-#{System.unique_integer([:positive])}")
    profile = Path.join(workspace, "profile")
    profile_two = Path.join(root, "profile-two")
    agy = Path.join(root, "agy")
    bwrap = Path.join(root, "bwrap")
    File.mkdir_p!(workspace)
    File.mkdir_p!(profile)
    File.mkdir_p!(workspace_two)
    File.mkdir_p!(profile_two)
    write_executable!(agy, "#!/bin/sh\nexit 0\n")
    write_executable!(bwrap, "#!/bin/sh\nexit 0\n")

    assert {:error, {:overlapping_antigravity_write_roots, _, _}} =
             Launcher.build(workspace, agy, profile, 1_000, bubblewrap_executable: bwrap)

    assert {:error, {:unsafe_antigravity_profile_root, ^home_parent}} =
             Launcher.build(workspace_two, agy, home_parent, 1_000, bubblewrap_executable: bwrap)

    assert {:error, {:unsafe_antigravity_workspace, ^home_parent}} =
             Launcher.build(home_parent, agy, profile_two, 1_000, bubblewrap_executable: bwrap)

    assert {:error, {:unsafe_antigravity_workspace, ^home}} =
             Launcher.build(home, agy, profile_two, 1_000, bubblewrap_executable: bwrap)

    unsafe_roots = [
      "/",
      "/bin",
      "/boot",
      "/dev",
      "/etc",
      "/etc/agy",
      "/lib",
      "/lib64",
      "/proc",
      "/root",
      "/run",
      "/run/user",
      "/sbin",
      "/sys",
      "/usr",
      "/home",
      "/home/other",
      "/media",
      "/mnt",
      "/opt",
      "/srv",
      "/tmp",
      "/var",
      "/var/lib",
      "/var/log",
      "/var/tmp"
    ]

    for unsafe_root <- unsafe_roots do
      assert {:ok, expected_root} = SymphonyElixir.PathSafety.canonicalize(unsafe_root)

      assert {:error, {:unsafe_antigravity_profile_root, ^expected_root}} =
               Launcher.build(workspace_two, agy, unsafe_root, 1_000, bubblewrap_executable: bwrap)

      assert {:error, {:unsafe_antigravity_workspace, ^expected_root}} =
               Launcher.build(unsafe_root, agy, profile_two, 1_000, bubblewrap_executable: bwrap)
    end

    assert {:error, {:antigravity_directory_not_found, :profile_root, "/var/lib/agy-profile"}} =
             Launcher.build(workspace_two, agy, "/var/lib/agy-profile", 1_000, bubblewrap_executable: bwrap)

    File.rm_rf!(root)
    File.rm_rf!(workspace_two)
  end

  test "requires dedicated home descendants and protects credential roots" do
    root = temporary_root("home-policy")
    home = Path.join(root, "home")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(root) end)

    home_suffix = System.unique_integer([:positive])
    workspace = Path.join(root, "workspace")
    profile = Path.join(root, "profile")
    home_workspace = Path.join(home, "issues/symphony-antigravity-#{home_suffix}")
    home_profile = Path.join(home, ".agy-profiles/slot-#{home_suffix}")
    agy = Path.join(root, "agy")
    bwrap = Path.join(root, "bwrap")
    launcher_opts = [bubblewrap_executable: bwrap, user_home: home]
    File.mkdir_p!(workspace)
    File.mkdir_p!(profile)
    File.mkdir_p!(home_workspace)
    File.mkdir_p!(home_profile)
    write_executable!(agy, "#!/bin/sh\nexit 0\n")
    write_executable!(bwrap, "#!/bin/sh\nexit 0\n")

    assert {:ok, workspace_launch} =
             Launcher.build(home_workspace, agy, profile, 1_000, launcher_opts)

    assert workspace_launch.workspace == home_workspace

    assert {:ok, profile_launch} =
             Launcher.build(workspace, agy, home_profile, 1_000, launcher_opts)

    assert profile_launch.profile_root == home_profile

    assert {:error, {:unsafe_antigravity_workspace, ^home_profile}} =
             Launcher.build(home_profile, agy, profile, 1_000, launcher_opts)

    assert {:error, {:unsafe_antigravity_profile_root, ^home_workspace}} =
             Launcher.build(workspace, agy, home_workspace, 1_000, launcher_opts)

    for unsafe_root <- [
          Path.join(home, "issues"),
          Path.join(home, ".agy-profiles"),
          Path.join(home, ".ssh"),
          Path.join(home, ".config/gh"),
          Path.join(home, ".config/environment.d"),
          Path.join(home, ".gnupg"),
          Path.join(home, ".aws"),
          Path.join(home, ".azure"),
          Path.join(home, ".kube"),
          Path.join(home, ".docker"),
          Path.join(home, ".local/share"),
          Path.join(home, ".cache/tool"),
          Path.join(home, ".password-store")
        ] do
      assert {:error, {:unsafe_antigravity_profile_root, ^unsafe_root}} =
               Launcher.build(profile, agy, unsafe_root, 1_000, launcher_opts)

      assert {:error, {:unsafe_antigravity_workspace, ^unsafe_root}} =
               Launcher.build(unsafe_root, agy, profile, 1_000, launcher_opts)
    end
  end

  test "masks the real home and projects only the canonical writable roots and AGY file" do
    root = Path.join("/var/tmp", "symphony-antigravity-topology-#{System.unique_integer([:positive])}")
    home = Path.expand(System.user_home!())
    workspace = Path.join(root, "workspace")
    profile = Path.join(root, "profile")
    agy = Path.join(root, "bin/agy")
    bwrap = Path.join(root, "bin/bwrap")
    File.mkdir_p!(workspace)
    File.mkdir_p!(profile)
    File.mkdir_p!(Path.dirname(agy))
    write_executable!(agy, "#!/bin/sh\nexit 0\n")
    write_executable!(bwrap, "#!/bin/sh\nexit 0\n")
    assert {:ok, launch} = Launcher.build(workspace, agy, profile, 1_234, bubblewrap_executable: bwrap)

    assert subsequence?(launch.args, ["--ro-bind", "/", "/"])
    assert subsequence?(launch.args, ["--tmpfs", "/tmp"])
    assert_home_masked_or_private(launch.args, home)
    refute subsequence?(launch.args, ["--dir", workspace])
    refute subsequence?(launch.args, ["--dir", profile])
    assert subsequence?(launch.args, ["--bind", workspace, workspace])
    assert subsequence?(launch.args, ["--bind", profile, profile])
    assert subsequence?(launch.args, ["--ro-bind", agy, "/tmp/symphony-antigravity-agy"])
    assert subsequence?(launch.args, ["--", "/tmp/symphony-antigravity-agy"])
    assert launch.agy_executable == agy

    refute subsequence?(launch.args, ["--bind", home, home])
    refute Enum.any?(launch.args, &(&1 == Path.dirname(agy)))
    assert 2 == Enum.count(launch.args, &(&1 == "--bind"))

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

    assert_receive {:agy_message, %{event: :turn_input_required, payload: %{"denied_actions_count" => 1}}}
    refute_receive {:agy_message, %{event: :turn_completed}}
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "maps WAITING to the neutral input-required event" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    on_message = fn message -> send(self(), {:agy_message, message}) end
    issue = %{id: "issue-waiting", identifier: "JARVIS-907", title: "Waiting"}

    assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)

    assert {:error, {:antigravity_input_required, %{status: "WAITING"}}} =
             Backend.run_turn(session, "waiting", issue, on_message: on_message)

    assert_receive {:agy_message, %{event: :turn_input_required, payload: %{"status" => "WAITING"}}}
    refute_receive {:agy_message, %{event: :turn_completed}}
    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "accepts native system messages without treating them as protocol failures" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    on_message = fn message -> send(self(), {:agy_message, message}) end
    issue = %{id: "issue-system-message", identifier: "JARVIS-907", title: "System message"}

    assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)
    assert {:ok, result} = Backend.run_turn(session, "system_message", issue, on_message: on_message)
    assert result.result == "system-message-done"

    assert_receive {:agy_message,
                    %{
                      event: :step_update,
                      payload: %{
                        "step_update" => %{"step_type" => "system_message"}
                      }
                    }}

    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "classifies native terminal errors without leaking account or credential values" do
    cases = [
      {"quota_error", :provider_quota_exhausted, "RESOURCE_EXHAUSTED", 429},
      {"auth_error", :provider_auth_failed, "UNAUTHENTICATED", 401},
      {"network_error", :provider_network_unreachable, nil, nil},
      {"provider_permission_error", :permission_denied, "PERMISSION_DENIED", 403},
      {"unknown_error", :unknown_terminal_failure, nil, nil},
      {"crash", :worker_crashed, nil, nil}
    ]

    for {prompt, reason, provider_code, http_status} <- cases do
      {root, workspace, profile, agy} = setup_fake_agy!()
      configure_backend!(agy, profile)
      on_message = fn message -> send(self(), {:agy_message, message}) end
      issue = %{id: "issue-terminal", identifier: "JARVIS-936", title: "Terminal classification"}
      assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)

      evidence =
        Backend.run_turn(session, prompt, issue,
          on_message: on_message,
          attempt: 7,
          writer_attempt: 2,
          writer_id: String.duplicate("c", 64)
        )
        |> assert_terminal_failure(reason)

      assert evidence.issue_id == issue.id
      assert evidence.issue_identifier == issue.identifier
      assert evidence.attempt == 2
      assert evidence.public_attempt == 7
      assert evidence.writer_id == String.duplicate("c", 64)
      assert evidence.session_id == "agy-session"
      assert Map.get(evidence, :provider_code) == provider_code
      assert Map.get(evidence, :http_status) == http_status
      refute inspect(evidence) =~ "owner@example.com"
      refute inspect(evidence) =~ "secret-refresh-value"
      assert_receive {:agy_message, %{event: :terminal_failure, terminal_failure: ^evidence}}

      receipt = Path.join(workspace, ".symphony/terminal-events/#{evidence.event_id}.json")
      assert File.regular?(receipt)
      assert Jason.decode!(File.read!(receipt))["reason"] == Atom.to_string(reason)
      assert :ok = Backend.stop_session(session)
      File.rm_rf!(root)
    end
  end

  test "rejects malformed step updates without retaining native values" do
    secret = "STEP_SECRET_907"

    for prompt <- ["bad_step_type", "bad_step_shape", "bad_text_delta", "oversized_delta"] do
      {root, workspace, profile, agy} = setup_fake_agy!()
      configure_backend!(agy, profile)
      on_message = fn message -> send(self(), {:agy_message, message}) end
      issue = %{id: "issue-step", identifier: "JARVIS-907", title: "Step validation"}
      assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)

      result = Backend.run_turn(session, prompt, issue, on_message: on_message)

      evidence = assert_terminal_failure(result, :provider_protocol_error)
      assert evidence.category == "protocol"

      messages = receive_messages([])
      refute Enum.any?(messages, &(inspect(&1) =~ secret))
      assert :ok = Backend.stop_session(session)
      File.rm_rf!(root)
    end
  end

  test "redacts rejected native values from callback errors and cancellation summaries" do
    cases = [
      {"unsafe_permission_secret", :unsafe_antigravity_permission_mode, "PERMISSION_SECRET_907"},
      {"invalid_status", :invalid_antigravity_terminal_status, "STATUS_SECRET_907"},
      {"invalid_turn_count", :invalid_antigravity_turn_count, "TURN_SECRET_907"},
      {"invalid_usage_secret", :invalid_antigravity_usage, "USAGE_SECRET_907"},
      {"silent_secret", :timeout, "CANCEL_SECRET_907"}
    ]

    for {prompt, expected, secret} <- cases do
      {root, workspace, profile, agy} = setup_fake_agy!()
      configure_backend!(agy, profile, first_event_timeout_ms: 30, turn_timeout_ms: 200, cancel_grace_ms: 100)
      on_message = fn message -> send(self(), {:agy_message, message}) end
      issue = %{id: "issue-redaction", identifier: "JARVIS-907", title: "Redaction"}
      assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)

      result = Backend.run_turn(session, prompt, issue, on_message: on_message)
      assert_redacted_result(result, expected)
      refute inspect(result) =~ secret
      messages = receive_messages([])
      refute Enum.any?(messages, &(inspect(&1) =~ secret))
      assert :ok = Backend.stop_session(session)
      File.rm_rf!(root)
    end
  end

  test "fails closed on a native identity mismatch" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    issue = %{id: "issue-mismatch", identifier: "JARVIS-907", title: "Identity mismatch"}

    assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)

    Backend.run_turn(session, "identity_mismatch", issue, [])
    |> assert_terminal_failure(:provider_protocol_error)

    assert :ok = Backend.stop_session(session)
    File.rm_rf!(root)
  end

  test "rejects unsafe init, duplicate init, and non-cumulative usage" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    issue = %{id: "issue-strict", identifier: "JARVIS-907", title: "Strict protocol"}

    assert {:ok, unsafe_session} = Backend.start_session(workspace, launcher: &direct_launcher/5)

    Backend.run_turn(unsafe_session, "unsafe_permission", issue, [])
    |> assert_terminal_failure(:provider_protocol_error)

    assert :ok = Backend.stop_session(unsafe_session)

    second_workspace = Path.join(root, "workspace-two")
    File.mkdir_p!(second_workspace)
    assert {:ok, duplicate_session} = Backend.start_session(second_workspace, launcher: &direct_launcher/5)
    assert {:ok, _first} = Backend.run_turn(duplicate_session, "first", issue, [])

    Backend.run_turn(duplicate_session, "duplicate_init", issue, [])
    |> assert_terminal_failure(:provider_protocol_error)

    assert :ok = Backend.stop_session(duplicate_session)

    third_workspace = Path.join(root, "workspace-three")
    File.mkdir_p!(third_workspace)
    assert {:ok, usage_session} = Backend.start_session(third_workspace, launcher: &direct_launcher/5)
    assert {:ok, _first} = Backend.run_turn(usage_session, "first", issue, [])

    Backend.run_turn(usage_session, "noncumulative", issue, [])
    |> assert_terminal_failure(:provider_protocol_error)

    assert :ok = Backend.stop_session(usage_session)
    File.rm_rf!(root)
  end

  test "rejects malformed and oversized stdout with bounded cleanup" do
    for prompt <- ["malformed", "oversized"] do
      {root, workspace, profile, agy} = setup_fake_agy!()
      configure_backend!(agy, profile)
      issue = %{id: "issue-frame", identifier: "JARVIS-907", title: "Frame bounds"}
      assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)

      Backend.run_turn(session, prompt, issue, [])
      |> assert_terminal_failure(:provider_protocol_error)

      assert :ok = Backend.stop_session(session)
      File.rm_rf!(root)
    end
  end

  test "pre-port launch failure positively clears its durable cleanup fence" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)

    assert {:error, %ErlangError{original: :forced_port_open}} =
             Transport.with_port_open_override_for_test(
               fn _port_name, _port_options -> :erlang.error(:forced_port_open) end,
               fn ->
                 Transport.start(workspace, agy, profile, 1_000, launcher: &direct_launcher/5)
               end
             )

    state_root = Application.fetch_env!(:symphony_elixir, :terminal_state_root)
    assert File.ls!(Path.join(state_root, "cleanups")) == []
    File.rm_rf!(root)
  end

  test "normal stop reaps a native descendant in the owned process group" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    issue = %{id: "issue-tree", identifier: "JARVIS-907", title: "Tree cleanup"}
    assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)
    state_root = Application.fetch_env!(:symphony_elixir, :terminal_state_root)

    cleanup_fence =
      Path.join([
        state_root,
        "cleanups",
        "#{session.transport.cleanup_fence_id}.json"
      ])

    assert File.regular?(cleanup_fence)
    assert {:ok, _turn} = Backend.run_turn(session, "descendant", issue, [])
    child_pid = workspace |> Path.join("child.pid") |> File.read!() |> String.trim()
    assert process_alive?(child_pid)
    assert :ok = Backend.stop_session(session)
    refute process_alive?(child_pid)
    refute File.exists?(cleanup_fence)
    File.rm_rf!(root)
  end

  test "cleanup acknowledgement registry fails closed and preserves completed results" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    other_guard = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      Process.exit(owner, :kill)
      Process.exit(other_guard, :kill)
    end)

    assert :ok = CleanupRegistry.require_ack(owner)
    assert :ok = CleanupRegistry.register(owner, self())
    assert :ok = CleanupRegistry.register(owner, self())
    assert {:error, :cleanup_owner_already_registered} = CleanupRegistry.register(owner, other_guard)
    assert {:error, :cleanup_ack_timeout} = CleanupRegistry.await(owner, 10)
    assert :ok = CleanupRegistry.complete(owner, self(), :ok)
    assert {:error, :cleanup_not_registered} = CleanupRegistry.await(owner, 10)

    completed_owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(completed_owner, :kill) end)
    assert :ok = CleanupRegistry.register(completed_owner, self())
    assert :ok = CleanupRegistry.require_ack(completed_owner)
    assert :ok = CleanupRegistry.complete(completed_owner, self(), {:error, :cleanup_failed})
    assert {:error, :cleanup_failed} = CleanupRegistry.await(completed_owner, 10)

    failed_guard_owner = spawn(fn -> Process.sleep(:infinity) end)
    failed_guard = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(failed_guard_owner, :kill) end)
    assert :ok = CleanupRegistry.require_ack(failed_guard_owner)
    assert :ok = CleanupRegistry.register(failed_guard_owner, failed_guard)
    Process.exit(failed_guard, :kill)
    assert {:error, :cleanup_guard_failed} = CleanupRegistry.await(failed_guard_owner, 1_000)

    reserved_owner = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = CleanupRegistry.require_ack(reserved_owner)
    reserved_ref = Process.monitor(reserved_owner)
    Process.exit(reserved_owner, :kill)
    assert_receive {:DOWN, ^reserved_ref, :process, ^reserved_owner, :killed}, 1_000
    assert :ok = CleanupRegistry.await(reserved_owner, 1_000)
  end

  test "owner death acknowledges native process-group cleanup before resume can proceed" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    parent = self()
    issue = %{id: "issue-owner-death", identifier: "JARVIS-907", title: "Owner cleanup"}

    owner =
      spawn(fn ->
        {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)
        {:ok, _turn} = Backend.run_turn(session, "descendant", issue, [])
        child_pid = workspace |> Path.join("child.pid") |> File.read!() |> String.trim()
        send(parent, {:native_owner_ready, self(), child_pid})
        Process.sleep(:infinity)
      end)

    assert_receive {:native_owner_ready, ^owner, child_pid}, 2_000
    assert process_alive?(child_pid)
    assert :ok = CleanupRegistry.require_ack(owner)
    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
    assert :ok = Transport.await_owner_cleanup(owner, 2_000)
    refute process_alive?(child_pid)
    File.rm_rf!(root)
  end

  test "runtime restart remains blocked by a durable cleanup fence until the detached guard settles" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile, tracker_kind: "memory")
    assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)
    state_root = Application.fetch_env!(:symphony_elixir, :terminal_state_root)
    fence_path = Path.join([state_root, "cleanups", "#{session.transport.cleanup_fence_id}.json"])
    assert File.regular?(fence_path)

    cleanup_registry = Process.whereis(CleanupRegistry)
    runtime_supervisor = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)
    assert is_pid(cleanup_registry)
    assert is_pid(runtime_supervisor)

    on_exit(fn ->
      _ = TerminalFailure.complete_native_cleanup_fence(session.transport.cleanup_fence_id)

      if is_nil(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)) do
        Supervisor.restart_child(
          SymphonyElixir.Supervisor,
          SymphonyElixir.AgentRuntimeSupervisor
        )
      end
    end)

    assert :ok =
             Supervisor.terminate_child(
               SymphonyElixir.Supervisor,
               SymphonyElixir.AgentRuntimeSupervisor
             )

    restart =
      Task.async(fn ->
        Supervisor.restart_child(
          SymphonyElixir.Supervisor,
          SymphonyElixir.AgentRuntimeSupervisor
        )
      end)

    assert is_pid(wait_for_replacement(CleanupRegistry, cleanup_registry, 100))
    assert File.regular?(fence_path)
    assert nil == Task.yield(restart, 0)
    assert :ok = Backend.stop_session(session)
    assert {:ok, restarted_runtime} = Task.await(restart, 5_000)
    assert is_pid(restarted_runtime)
    File.rm_rf!(root)
  end

  test "resumed terminal evidence remains unpublished until native cleanup is verified" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    issue = %{id: "issue-deferred-terminal", identifier: "JARVIS-936", title: "Deferred terminal"}

    prior =
      SymphonyElixir.TerminalFailure.build(:provider_quota_exhausted, %{}, %{
        backend: :antigravity,
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        attempt: 0,
        session_id: "prior-session",
        workspace: workspace,
        binding_id: "slot-a"
      })

    assert {:ok, _path} = SymphonyElixir.TerminalFailure.persist(workspace, prior)
    assert {:ok, _receipt} = SymphonyElixir.TerminalFailure.record_resume(workspace, prior, "slot-b", 1)

    binding = %{binding_id: "slot-b", backend: :antigravity, options: %{profile_root: profile}}

    assert {:ok, session} =
             Backend.start_session(workspace, launcher: &direct_launcher/5, binding: binding)

    on_message = fn message -> send(self(), {:agy_message, message}) end

    assert {:error, {:backend_terminal_failure_pending_cleanup, successor}} =
             Backend.run_turn(session, "quota_error", issue,
               on_message: on_message,
               attempt: 1,
               writer_attempt: 1,
               writer_id: String.duplicate("a", 64),
               predecessor_event_id: prior.event_id
             )

    assert {:ambiguous, %{event_id: prior_event_id}} =
             SymphonyElixir.TerminalFailure.recovery_state(workspace, issue.id)

    assert prior_event_id == prior.event_id
    refute process_alive?(Integer.to_string(session.backend_process_pid))
    refute_receive {:agy_message, %{event: :terminal_failure}}
    assert :ok = Backend.stop_session(session)
    assert {:ok, _path} = SymphonyElixir.TerminalFailure.persist(workspace, successor)

    assert {:settled, %{event_id: successor_event_id}} =
             SymphonyElixir.TerminalFailure.recovery_state(workspace, issue.id)

    assert successor_event_id == successor.event_id
    File.rm_rf!(root)
  end

  test "AgentRunner publishes a resumed terminal hold only after backend cleanup" do
    {root, workspace, profile, agy} = setup_fake_agy!()

    configure_backend!(agy, profile,
      workspace_root: Path.dirname(workspace),
      max_turns: 1,
      prompt: "quota_error"
    )

    issue = %Issue{
      id: "issue-runner-deferred-terminal",
      identifier: Path.basename(workspace),
      title: "quota_error",
      description: "Force a deferred terminal failure",
      state: "In Progress",
      url: "https://example.org/issues/deferred-terminal",
      dispatchable: true
    }

    prior =
      SymphonyElixir.TerminalFailure.build(:provider_quota_exhausted, %{}, %{
        backend: :antigravity,
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        attempt: 0,
        session_id: "prior-session",
        workspace: workspace,
        binding_id: "slot-a"
      })

    assert {:ok, _path} = SymphonyElixir.TerminalFailure.persist(workspace, prior)
    assert {:ok, _receipt} = SymphonyElixir.TerminalFailure.record_resume(workspace, prior, "slot-b", 1)
    binding = %{binding_id: "slot-b", backend: :antigravity, options: %{profile_root: profile}}

    assert_raise RuntimeError, ~r/backend_terminal_failure/, fn ->
      SymphonyElixir.AgentRunner.run(
        issue,
        self(),
        workspace_path: workspace,
        max_turns: 1,
        binding: binding,
        attempt: 1,
        writer_attempt: 1,
        writer_id: String.duplicate("b", 64),
        predecessor_event_id: prior.event_id,
        issue_state_fetcher: fn _ids -> {:ok, [issue]} end
      )
    end

    issue_id = issue.id

    assert_receive {:codex_worker_update, ^issue_id, %{event: :session_started, backend_process_pid: native_pid}}

    assert_receive {:codex_worker_update, ^issue_id, %{event: :terminal_failure, terminal_failure: successor}}

    refute process_alive?(Integer.to_string(native_pid))
    assert successor.predecessor_event_id == prior.event_id

    assert {:settled, %{event_id: successor_event_id}} =
             SymphonyElixir.TerminalFailure.recovery_state(workspace, issue.id)

    assert successor_event_id == successor.event_id
    File.rm_rf!(root)
  end

  test "bounds silent turns, records liveness, and empties each process group" do
    for {prompt, liveness} <- [
          {"silent", :alive_but_thinking},
          {"no_event", :dead_or_unreachable}
        ] do
      {root, workspace, profile, agy} = setup_fake_agy!()
      configure_backend!(agy, profile, first_event_timeout_ms: 30, turn_timeout_ms: 200, cancel_grace_ms: 100)
      issue = %{id: "issue-timeout", identifier: "JARVIS-907", title: "Timeout"}
      on_message = fn message -> send(self(), {:agy_message, message}) end

      assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)

      evidence =
        Backend.run_turn(session, prompt, issue, on_message: on_message)
        |> assert_terminal_failure(:worker_stalled)

      assert evidence.liveness == liveness
      assert_receive {:agy_message, %{event: :terminal_failure, terminal_failure: ^evidence}}
      assert :ok = Backend.stop_session(session)
      File.rm_rf!(root)
    end
  end

  test "bound launch failures never log the selected profile path" do
    {root, _workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    secret_profile = Path.join(root, "profiles/account-owner-secret")
    issue = %Issue{id: "issue-binding-log", identifier: "JARVIS-LOG", title: "Binding log"}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert_raise RuntimeError, fn ->
          SymphonyElixir.AgentRunner.run(
            issue,
            nil,
            backend: "antigravity",
            binding: %{
              binding_id: "slot-safe-id",
              backend: :antigravity,
              options: %{profile_root: secret_profile}
            }
          )
        end
      end)

    refute log =~ secret_profile
    assert log =~ "slot-safe-id"
    File.rm_rf!(root)
  end

  test "terminal persistence failure emits a distinct storage blocker without terminal evidence" do
    {root, workspace, profile, agy} = setup_fake_agy!()
    configure_backend!(agy, profile)
    blocked_state_root = Path.join(root, "blocked-state-root")
    File.write!(blocked_state_root, "not a directory")
    original_state_root = Application.get_env(:symphony_elixir, :terminal_state_root)

    on_exit(fn ->
      if original_state_root,
        do: Application.put_env(:symphony_elixir, :terminal_state_root, original_state_root),
        else: Application.delete_env(:symphony_elixir, :terminal_state_root)

      File.rm_rf!(root)
    end)

    issue = %{id: "issue-storage-failure", identifier: "JARVIS-936", title: "Storage failure"}
    on_message = fn message -> send(self(), {:agy_message, message}) end
    assert {:ok, session} = Backend.start_session(workspace, launcher: &direct_launcher/5)
    Application.put_env(:symphony_elixir, :terminal_state_root, blocked_state_root)

    assert {:error, {:backend_terminal_storage_failure, event_id}} =
             Backend.run_turn(session, "quota_error", issue,
               on_message: on_message,
               attempt: 1
             )

    assert is_binary(event_id)

    assert_receive {:agy_message,
                    %{
                      event: :terminal_storage_failure,
                      terminal_storage_failure: %{event_id: ^event_id}
                    }}

    refute_receive {:agy_message, %{event: :terminal_failure}}

    assert {:storage_fault, %{event_id: ^event_id}} =
             SymphonyElixir.TerminalFailure.recovery_state(workspace, issue.id)

    if original_state_root,
      do: Application.put_env(:symphony_elixir, :terminal_state_root, original_state_root),
      else: Application.delete_env(:symphony_elixir, :terminal_state_root)

    assert :ok = Backend.stop_session(session)
  end

  test "AgentRunner emits a lifecycle storage blocker when active-marker clear fails" do
    {root, workspace, profile, agy} = setup_fake_agy!()

    configure_backend!(agy, profile,
      workspace_root: Path.dirname(workspace),
      max_turns: 1
    )

    issue = %Issue{
      id: "issue-marker-clear",
      identifier: Path.basename(workspace),
      title: "Marker clear failure",
      description: "complete normally",
      state: "In Progress",
      url: "https://example.org/issues/marker-clear",
      dispatchable: true
    }

    evidence =
      SymphonyElixir.TerminalFailure.build(
        :provider_quota_exhausted,
        %{},
        %{
          backend: :antigravity,
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          attempt: 0,
          session_id: "prior-session",
          workspace: workspace,
          binding_id: "slot-a"
        }
      )

    assert {:ok, _path} = SymphonyElixir.TerminalFailure.persist(workspace, evidence)
    issue_hash = :crypto.hash(:sha256, issue.id) |> Base.encode16(case: :lower)

    global_marker =
      Path.join(
        Application.fetch_env!(:symphony_elixir, :terminal_state_root),
        "active/#{evidence.workflow_scope}-#{issue_hash}.json"
      )

    File.rm!(global_marker)
    File.mkdir_p!(global_marker)

    assert_raise RuntimeError, ~r/terminal_marker_clear_failed/, fn ->
      SymphonyElixir.AgentRunner.run(
        issue,
        self(),
        workspace_path: workspace,
        max_turns: 1,
        issue_state_fetcher: fn _ids -> {:ok, []} end
      )
    end

    issue_id = issue.id

    assert_receive {:codex_worker_update, ^issue_id,
                    %{
                      event: :terminal_storage_failure,
                      terminal_storage_failure: %{code: _code}
                    }}

    refute_receive {:codex_worker_update, ^issue_id, %{event: :terminal_failure}}
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
    File.rm_rf!(root)
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
          *unsafe_permission_secret*) printf '%s\n' '{"event":"init","conversation_id":"agy-session","init":{"cwd":"'"$PWD"'","permission_mode":"PERMISSION_SECRET_907"}}' ;;
          *unsafe_permission*) printf '{"event":"init","conversation_id":"agy-session","init":{"cwd":"%s","permission_mode":"always-proceed"}}\n' "$PWD" ;;
          *workspace_mismatch*) printf '%s\n' '{"event":"init","conversation_id":"agy-session","init":{"cwd":"/wrong","permission_mode":"request-review"}}' ;;
          *no_event*) : ;;
          *) printf '{"event":"init","conversation_id":"agy-session","init":{"cwd":"%s","permission_mode":"request-review","account_identifier":"must-not-forward"}}\n' "$PWD" ;;
        esac
      fi
      case "$line" in
        *quota_error*)
          printf '%s\n' '{"event":"step_update","step_update":{"step_type":"error_message","source":"SYSTEM","type":"ERROR_MESSAGE","status":"DONE","error":"API error (attempt 1): RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 3h1m10s."}}'
          ;;
        *auth_error*)
          printf '%s\n' '{"event":"step_update","step_update":{"source":"SYSTEM","type":"ERROR_MESSAGE","status":"DONE","error":"UNAUTHENTICATED (code 401): OAuth failed for owner@example.com refresh_token=secret-refresh-value"}}'
          ;;
        *network_error*)
          printf '%s\n' '{"event":"step_update","step_update":{"source":"SYSTEM","type":"ERROR_MESSAGE","status":"ERROR","error":"network unreachable: DNS resolution failed"}}'
          ;;
        *provider_permission_error*)
          printf '%s\n' '{"event":"step_update","step_update":{"source":"SYSTEM","type":"ERROR_MESSAGE","status":"DONE","error":"PERMISSION_DENIED (code 403): forbidden"}}'
          ;;
        *unknown_error*)
          printf '%s\n' '{"event":"step_update","step_update":{"source":"SYSTEM","type":"ERROR_MESSAGE","status":"DONE","error":"provider ended the request for an undocumented reason"}}'
          ;;
        *crash*)
          exit 42
          ;;
        *system_message*)
          printf '%s\n' '{"event":"step_update","step_update":{"conversation_id":"agy-session","step_type":"system_message"}}'
          printf '{"event":"result","result":{"conversation_id":"agy-session","status":"SUCCESS","response":"system-message-done","duration_seconds":1,"num_turns":%s,"usage":{"input_tokens":10,"output_tokens":3,"thinking_tokens":2,"cache_read_tokens":0,"total_tokens":15}}}\n' "$turn"
          ;;
        *bad_step_type*)
          printf '%s\n' '{"event":"step_update","step_update":{"conversation_id":"agy-session","step_type":"STEP_SECRET_907"}}'
          ;;
        *bad_step_shape*)
          printf '%s\n' '{"event":"step_update","step_update":{"conversation_id":"agy-session","step_type":{"secret":"STEP_SECRET_907"}}}'
          ;;
        *bad_text_delta*)
          printf '%s\n' '{"event":"step_update","step_update":{"conversation_id":"agy-session","step_type":"agent_response","text_delta":{"value":"STEP_SECRET_907"}}}'
          ;;
        *oversized_delta*)
          printf '%s' '{"event":"step_update","step_update":{"conversation_id":"agy-session","step_type":"agent_response","text_delta":"'
          head -c 65537 /dev/zero | tr '\\000' x
          printf '%s\n' '"}}'
          ;;
        *invalid_status*)
          printf '%s\n' '{"event":"result","result":{"conversation_id":"agy-session","status":"STATUS_SECRET_907","response":"bad","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":3,"thinking_tokens":2,"cache_read_tokens":0,"total_tokens":15}}}'
          ;;
        *invalid_turn_count*)
          printf '%s\n' '{"event":"result","result":{"conversation_id":"agy-session","status":"SUCCESS","response":"bad","duration_seconds":1,"num_turns":"TURN_SECRET_907","usage":{"input_tokens":10,"output_tokens":3,"thinking_tokens":2,"cache_read_tokens":0,"total_tokens":15}}}'
          ;;
        *waiting*)
          printf '{"event":"result","result":{"conversation_id":"agy-session","status":"WAITING","response":"waiting","duration_seconds":1,"num_turns":%s,"usage":{"input_tokens":10,"output_tokens":3,"thinking_tokens":2,"cache_read_tokens":0,"total_tokens":15}}}\n' "$turn"
          ;;
        *invalid_usage_secret*)
          printf '%s\n' '{"event":"result","result":{"conversation_id":"agy-session","status":"SUCCESS","response":"bad","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":"USAGE_SECRET_907","output_tokens":3,"thinking_tokens":2,"cache_read_tokens":0,"total_tokens":15}}}'
          ;;
        *silent_secret*)
          sleep 10
          if [ "$interrupted" -eq 1 ]; then
            printf '{"event":"result","result":{"conversation_id":"agy-session","status":"CANCEL_SECRET_907","response":"","error":"interrupted","duration_seconds":0,"num_turns":%s,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0}}}\n' "$turn"
          fi
          ;;
        *identity_mismatch*)
          printf '%s\n' '{"event":"step_update","step_update":{"conversation_id":"other-session","step_type":"agent_response","text_delta":"bad"}}'
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
          printf '{"event":"step_update","step_update":{"conversation_id":"agy-session","step_type":"agent_response","text_delta":"spawned"}}\n'
          printf '{"event":"result","result":{"conversation_id":"agy-session","status":"SUCCESS","response":"descendant","duration_seconds":1,"num_turns":%s,"usage":{"input_tokens":%s,"output_tokens":%s,"thinking_tokens":%s,"cache_read_tokens":0,"total_tokens":%s}}}\n' "$turn" "$input" "$output" "$thinking" "$total"
          ;;
        *silent*|*no_event*)
          sleep 10
          if [ "$interrupted" -eq 1 ]; then
            printf '{"event":"result","result":{"conversation_id":"agy-session","status":"ERROR","response":"","error":"interrupted","duration_seconds":0,"num_turns":%s,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0}}}\n' "$turn"
          fi
          ;;
        *)
          input=$((turn * 10)); output=$((turn * 3)); thinking=$((turn * 2)); total=$((turn * 15))
          printf '{"event":"step_update","step_update":{"conversation_id":"agy-session","step_type":"agent_response","text_delta":"working-%s","private_tool_argument":"must-not-forward"}}\n' "$turn"
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

  defp receive_messages(messages) do
    receive do
      {:agy_message, message} -> receive_messages([message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end

  defp assert_redacted_result(result, :timeout) do
    assert_terminal_failure(result, :worker_stalled)
  end

  defp assert_redacted_result(result, _native_reason) do
    assert_terminal_failure(result, :provider_protocol_error)
  end

  defp assert_terminal_failure(
         {:error, {:backend_terminal_failure, %{reason: reason} = evidence}},
         reason
       ) do
    assert SymphonyElixir.TerminalFailure.valid?(evidence)

    assert :ok =
             SymphonyElixir.TerminalFailure.clear_active(
               evidence.workspace,
               evidence.issue_id,
               evidence.event_id
             )

    evidence
  end

  defp wait_for_replacement(_name, _prior_pid, 0), do: nil

  defp wait_for_replacement(name, prior_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != prior_pid ->
        pid

      _other ->
        Process.sleep(10)
        wait_for_replacement(name, prior_pid, attempts - 1)
    end
  end

  defp process_alive?(pid) do
    match?({_output, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  end

  defp assert_home_masked_or_private(args, home) do
    if Path.split(home) |> Enum.take(2) == ["/", "tmp"] do
      refute subsequence?(args, ["--tmpfs", home])
    else
      assert subsequence?(args, ["--tmpfs", home])
    end
  end

  defp subsequence?(list, expected) do
    expected_length = length(expected)

    Enum.any?(0..max(length(list) - expected_length, 0), fn index ->
      Enum.slice(list, index, expected_length) == expected
    end)
  end
end
