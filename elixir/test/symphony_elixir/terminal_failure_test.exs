defmodule SymphonyElixir.TerminalFailureTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TerminalFailure

  test "terminal receipts are redacted, deterministic, idempotent, and restart-classified" do
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
    refute first.message =~ "owner@example.com"
    refute first.message =~ "secret-refresh-value"
    assert TerminalFailure.sanitize_message(nil) == nil

    long_message = "eyJabcdefghijklmnop.qrstuvwxyz " <> String.duplicate("x", 3_000)
    sanitized_long = TerminalFailure.sanitize_message(long_message)
    assert byte_size(sanitized_long) == 2_048
    refute sanitized_long =~ "eyJabcdefghijklmnop"
    refute TerminalFailure.valid?(%{reason: :provider_quota_exhausted})

    assert {:ok, first_path} = TerminalFailure.persist(workspace, first)
    assert {:ok, ^first_path} = TerminalFailure.persist(workspace, second)
    assert {:settled, recovered} = TerminalFailure.recovery_state(workspace)
    assert recovered.event_id == first.event_id

    assert {:ok, _resume_path} =
             TerminalFailure.record_resume(workspace, first, "slot-c", 4)

    assert {:ambiguous, ambiguous} = TerminalFailure.recovery_state(workspace)
    assert ambiguous.event_id == first.event_id

    terminal_event_files =
      workspace
      |> Path.join(".symphony/terminal-events")
      |> File.ls!()

    assert terminal_event_files == ["#{first.event_id}.json"]
    assert :ok = TerminalFailure.clear_active(workspace)
    assert :none = TerminalFailure.recovery_state(workspace)
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
    assert {:error, _reason} = TerminalFailure.persist(workspace, evidence)
    refute Enum.any?(File.ls!(Path.dirname(receipt_target)), &String.contains?(&1, ".tmp-"))

    marker_workspace = Path.join(root, "marker-directory")
    marker = Path.join(marker_workspace, ".symphony/terminal-failure.json")
    File.mkdir_p!(marker)
    assert {:error, _reason} = TerminalFailure.recovery_state(marker_workspace)
    assert {:error, _reason} = TerminalFailure.clear_active(marker_workspace)

    file_workspace = Path.join(root, "workspace-file")
    File.write!(file_workspace, "not a directory")
    assert {:error, _reason} = TerminalFailure.persist(file_workspace, evidence)
    assert {:error, _reason} = TerminalFailure.record_resume(file_workspace, evidence, "slot-z", 9)
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
