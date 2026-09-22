defmodule SymphonyElixir.TerminalFailureTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TerminalFailure

  test "terminal receipts are allowlisted, deterministic, immutable, and restart-classified" do
    assert TerminalFailure.reasons() == [
             :provider_quota_exhausted,
             :provider_auth_failed,
             :provider_network_unreachable,
             :permission_denied,
             :worker_crashed,
             :worker_stalled,
             :provider_protocol_error,
             :unknown_terminal_failure
           ]

    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-failure-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    context = %{
      backend: :antigravity,
      issue_id: "issue-936",
      issue_identifier: "JARVIS-936",
      attempt: 3,
      session_id: "session-936",
      workspace: workspace,
      binding_id: "slot-b"
    }

    details = %{
      provider_code: "RESOURCE_EXHAUSTED",
      http_status: 429,
      reset_hint: "3h1m10s",
      message: "quota for owner@example.com refresh_token=secret-refresh-value"
    }

    first = TerminalFailure.build(:provider_quota_exhausted, details, context)
    second = TerminalFailure.build(:provider_quota_exhausted, details, context)

    assert first.event_id == second.event_id
    refute Map.has_key?(first, :message)
    refute inspect(first) =~ "owner@example.com"
    refute inspect(first) =~ "secret-refresh-value"
    refute TerminalFailure.valid?(%{reason: :provider_quota_exhausted})

    unicode_context = %{
      context
      | issue_identifier: String.duplicate("a", 255) <> "💥",
        session_id: <<255, 254, 253>>
    }

    unicode_evidence = TerminalFailure.build(:worker_stalled, %{}, unicode_context)
    assert String.valid?(unicode_evidence.issue_identifier)
    assert byte_size(unicode_evidence.issue_identifier) <= 256
    assert unicode_evidence.session_id == "[INVALID_UTF8]"

    assert {:ok, first_path} = TerminalFailure.persist(workspace, first)
    first_bytes = File.read!(first_path)
    assert {:ok, ^first_path} = TerminalFailure.persist(workspace, first)
    assert File.read!(first_path) == first_bytes
    assert {:error, :receipt_conflict} = TerminalFailure.persist(workspace, second)
    assert {:settled, recovered} = TerminalFailure.recovery_state(workspace)
    assert recovered.event_id == first.event_id

    assert {:ok, _resume_path} =
             TerminalFailure.record_resume(workspace, first, "slot-c", 4)

    assert {:ambiguous, ambiguous} = TerminalFailure.recovery_state(workspace)
    assert ambiguous.event_id == first.event_id

    relocated_workspace = Path.join(Path.dirname(workspace), "relocated/#{Path.basename(workspace)}")
    File.mkdir_p!(relocated_workspace)

    assert {:ambiguous, relocated} =
             TerminalFailure.recovery_state(relocated_workspace, context.issue_id)

    assert relocated.workspace == workspace

    terminal_event_files =
      workspace
      |> Path.join(".symphony/terminal-events")
      |> File.ls!()

    assert terminal_event_files == ["#{first.event_id}.json"]
    assert :ok = TerminalFailure.clear_active(workspace, context.issue_id)
    assert :none = TerminalFailure.recovery_state(workspace, context.issue_id)
    assert :none = TerminalFailure.recovery_state(relocated_workspace, context.issue_id)
    File.rm_rf!(Path.dirname(relocated_workspace))
  end

  test "provider-neutral receipts decode known backends and liveness states" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-neutral-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    for {backend, liveness} <- [
          {:codex, :alive_but_thinking},
          {:pi, :semantically_stuck},
          {:antigravity, :dead_or_unreachable}
        ] do
      workspace = Path.join(root, Atom.to_string(backend))
      File.mkdir_p!(workspace)

      evidence =
        TerminalFailure.build(
          :worker_stalled,
          %{message: "bounded stall", liveness: liveness},
          %{
            backend: backend,
            issue_id: "issue-#{backend}",
            issue_identifier: "TEST-#{backend}",
            attempt: -1,
            session_id: nil,
            workspace: workspace,
            binding_id: nil
          }
        )

      assert evidence.attempt == nil
      refute Map.has_key?(evidence, :message)
      assert {:ok, _path} = TerminalFailure.persist(workspace, evidence)
      assert {:settled, recovered} = TerminalFailure.recovery_state(workspace)
      assert recovered.backend == backend
      assert recovered.liveness == liveness
    end
  end

  test "filesystem and decoding errors remain bounded and fail closed" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-errors-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    evidence =
      TerminalFailure.build(
        :unknown_terminal_failure,
        %{message: "unknown"},
        %{
          backend: :antigravity,
          issue_id: nil,
          issue_identifier: nil,
          attempt: nil,
          session_id: nil,
          workspace: workspace,
          binding_id: nil
        }
      )

    receipt_target =
      Path.join(workspace, ".symphony/terminal-events/#{evidence.event_id}.json")

    File.mkdir_p!(receipt_target)
    assert {:ok, fallback_receipt} = TerminalFailure.persist(workspace, evidence)
    assert fallback_receipt != receipt_target
    assert File.regular?(fallback_receipt)
    assert {:settled, recovered} = TerminalFailure.recovery_state(workspace)
    assert recovered.event_id == evidence.event_id
    refute Enum.any?(File.ls!(Path.dirname(receipt_target)), &String.contains?(&1, ".tmp-"))

    marker_workspace = Path.join(root, "marker-directory")
    marker = Path.join(marker_workspace, ".symphony/terminal-failure.json")
    marker_hash = :crypto.hash(:sha256, Path.expand(marker_workspace)) |> Base.encode16(case: :lower)
    fallback_marker = Path.join(root, ".symphony/terminal-holds/active/#{marker_hash}.json")
    File.mkdir_p!(marker)
    File.mkdir_p!(fallback_marker)
    assert {:error, _reason} = TerminalFailure.recovery_state(marker_workspace)
    assert {:error, _reason} = TerminalFailure.clear_active(marker_workspace)

    locked_receipt_workspace = Path.join(root, "locked-receipt")
    locked_receipt_directory = Path.join(locked_receipt_workspace, ".symphony/terminal-events")
    File.mkdir_p!(locked_receipt_directory)
    File.chmod!(locked_receipt_directory, 0o500)

    locked_receipt_evidence =
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        issue_id: nil,
        issue_identifier: nil,
        attempt: nil,
        session_id: nil,
        workspace: locked_receipt_workspace,
        binding_id: nil
      })

    assert {:ok, locked_receipt_fallback} =
             TerminalFailure.persist(locked_receipt_workspace, locked_receipt_evidence)

    assert String.contains?(locked_receipt_fallback, "terminal-holds")
    File.chmod!(locked_receipt_directory, 0o700)

    locked_active_workspace = Path.join(root, "locked-active")
    locked_metadata = Path.join(locked_active_workspace, ".symphony")
    File.mkdir_p!(Path.join(locked_metadata, "terminal-events"))
    File.chmod!(locked_metadata, 0o500)

    locked_active_evidence =
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        issue_id: nil,
        issue_identifier: nil,
        attempt: nil,
        session_id: nil,
        workspace: locked_active_workspace,
        binding_id: nil
      })

    assert {:ok, _receipt} =
             TerminalFailure.persist(locked_active_workspace, locked_active_evidence)

    assert {:settled, %{event_id: event_id}} =
             TerminalFailure.recovery_state(locked_active_workspace)

    assert event_id == locked_active_evidence.event_id
    File.chmod!(locked_metadata, 0o700)

    file_workspace = Path.join(root, "workspace-file")
    File.write!(file_workspace, "not a directory")

    file_evidence =
      TerminalFailure.build(:unknown_terminal_failure, %{}, %{
        backend: :antigravity,
        issue_id: nil,
        issue_identifier: nil,
        attempt: nil,
        session_id: nil,
        workspace: file_workspace,
        binding_id: nil
      })

    assert {:ok, fallback_path} = TerminalFailure.persist(file_workspace, file_evidence)
    assert String.contains?(fallback_path, "terminal-holds")

    assert {:ok, fallback_resume} =
             TerminalFailure.record_resume(file_workspace, file_evidence, "slot-z", 9)

    assert String.contains?(fallback_resume, "terminal-holds")
  end

  test "default global hold root follows the configured log directory" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-default-state-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    log_file = Path.join(root, "logs/symphony.log")
    File.mkdir_p!(workspace)
    original_state_root = Application.get_env(:symphony_elixir, :terminal_state_root)
    original_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if original_state_root,
        do: Application.put_env(:symphony_elixir, :terminal_state_root, original_state_root),
        else: Application.delete_env(:symphony_elixir, :terminal_state_root)

      if original_log_file,
        do: Application.put_env(:symphony_elixir, :log_file, original_log_file),
        else: Application.delete_env(:symphony_elixir, :log_file)

      File.rm_rf!(root)
    end)

    Application.delete_env(:symphony_elixir, :terminal_state_root)
    Application.put_env(:symphony_elixir, :log_file, log_file)

    evidence =
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        issue_id: "default-state-issue",
        issue_identifier: "DEFAULT-STATE",
        attempt: 0,
        session_id: nil,
        workspace: workspace,
        binding_id: nil
      })

    assert {:ok, _receipt} = TerminalFailure.persist(workspace, evidence)
    issue_hash = :crypto.hash(:sha256, evidence.issue_id) |> Base.encode16(case: :lower)
    assert File.regular?(Path.join(root, "logs/terminal-holds/active/#{issue_hash}.json"))
    assert :ok = TerminalFailure.clear_active(workspace, evidence.issue_id)
  end

  test "tampered or malformed active evidence fails closed" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-tamper-#{System.unique_integer([:positive])}"
      )

    marker = Path.join(workspace, ".symphony/terminal-failure.json")
    File.mkdir_p!(Path.dirname(marker))
    on_exit(fn -> File.rm_rf!(workspace) end)

    File.write!(marker, ~s({"event_id":"#{String.duplicate("a", 64)}","reason":"provider_quota_exhausted"}))

    assert {:error, :invalid_terminal_failure_receipt} =
             TerminalFailure.recovery_state(workspace)

    File.write!(marker, "[]")

    assert {:error, :invalid_terminal_failure_receipt} =
             TerminalFailure.recovery_state(workspace)

    File.write!(
      marker,
      Jason.encode!(%{
        "event_id" => String.duplicate("a", 64),
        "reason" => 42,
        "category" => "quota",
        "backend" => "unknown",
        "workspace" => workspace,
        "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    )

    assert {:error, :invalid_terminal_failure_receipt} =
             TerminalFailure.recovery_state(workspace)
  end
end
