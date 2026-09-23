defmodule SymphonyElixir.TerminalFailureTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TerminalFailure

  test "native cleanup fences survive runtime restart boundaries until positive cleanup proof" do
    assert {:ok, cleanup_id} = TerminalFailure.begin_native_cleanup_fence()
    state_root = Application.fetch_env!(:symphony_elixir, :terminal_state_root)
    fence_path = Path.join([state_root, "cleanups", "#{cleanup_id}.json"])
    assert File.regular?(fence_path)
    parent = self()

    waiter =
      Task.async(fn ->
        TerminalFailure.with_lock_overrides_for_test(
          %{
            native_cleanup_wait: fn ->
              send(parent, {:native_cleanup_waiting, self()})

              receive do
                :native_cleanup_may_continue -> :ok
              end
            end
          },
          &TerminalFailure.storage_ready/0
        )
      end)

    assert_receive {:native_cleanup_waiting, waiter_pid}, 1_000
    assert waiter_pid == waiter.pid
    assert :ok = TerminalFailure.complete_native_cleanup_fence(cleanup_id)
    send(waiter.pid, :native_cleanup_may_continue)
    assert :ok = Task.await(waiter, 1_000)
    refute File.exists?(fence_path)
  end

  test "native cleanup fence validation and unresolved ownership fail closed" do
    state_root = Application.fetch_env!(:symphony_elixir, :terminal_state_root)

    assert {:error, :invalid_native_cleanup_fence_id} =
             TerminalFailure.complete_native_cleanup_fence("not-a-fence")

    assert {:ok, unresolved_id} = TerminalFailure.begin_native_cleanup_fence()
    assert {:error, {:native_cleanup_incomplete, 1}} = TerminalFailure.storage_ready()
    assert :ok = TerminalFailure.complete_native_cleanup_fence(unresolved_id)
    assert :ok = TerminalFailure.complete_native_cleanup_fence(unresolved_id)

    assert {:ok, malformed_id} = TerminalFailure.begin_native_cleanup_fence()
    malformed_path = Path.join([state_root, "cleanups", "#{malformed_id}.json"])
    File.write!(malformed_path, Jason.encode!(%{"version" => 1}))

    assert {:error, {:invalid_native_cleanup_fence, _, :invalid_payload}} =
             TerminalFailure.storage_ready()

    File.rm!(malformed_path)
    assert :ok = TerminalFailure.storage_ready()
  end

  test "native cleanup fence IO failures are typed and race-safe" do
    assert :ok =
             TerminalFailure.with_lock_overrides_for_test(
               %{cleanup_ls: {:error, :enoent}},
               &TerminalFailure.storage_ready/0
             )

    assert {:error, {:native_cleanup_namespace_unavailable, :eacces}} =
             TerminalFailure.with_lock_overrides_for_test(
               %{cleanup_ls: {:error, :eacces}},
               &TerminalFailure.storage_ready/0
             )

    assert {:ok, disappearing_id} = TerminalFailure.begin_native_cleanup_fence()

    assert :ok =
             TerminalFailure.with_lock_overrides_for_test(
               %{cleanup_lstat: fn _path -> {:error, :enoent} end},
               &TerminalFailure.storage_ready/0
             )

    assert :ok = TerminalFailure.complete_native_cleanup_fence(disappearing_id)
    state_root = Application.fetch_env!(:symphony_elixir, :terminal_state_root)
    on_exit(fn -> Application.put_env(:symphony_elixir, :terminal_state_root, state_root) end)
    blocked_root = Path.join(state_root, "blocked-cleanup-root")
    File.write!(blocked_root, "not a directory")
    Application.put_env(:symphony_elixir, :terminal_state_root, blocked_root)

    assert {:error, {:native_cleanup_fence_unavailable, _reason}} =
             TerminalFailure.begin_native_cleanup_fence()

    Application.put_env(:symphony_elixir, :terminal_state_root, :invalid_root)
    assert {:error, :native_cleanup_fence_unavailable} = TerminalFailure.begin_native_cleanup_fence()

    assert {:error, :native_cleanup_fence_clear_failed} =
             TerminalFailure.complete_native_cleanup_fence(String.duplicate("a", 64))

    Application.put_env(:symphony_elixir, :terminal_state_root, state_root)
  end

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

    next_attempt =
      TerminalFailure.build(
        :provider_quota_exhausted,
        details,
        %{context | attempt: context.attempt + 1}
      )

    refute next_attempt.event_id == first.event_id

    first_writer =
      TerminalFailure.build(
        :worker_crashed,
        %{},
        Map.put(context, :writer_id, String.duplicate("a", 64))
      )

    restarted_writer =
      TerminalFailure.build(
        :worker_crashed,
        %{},
        Map.put(context, :writer_id, String.duplicate("b", 64))
      )

    refute first_writer.event_id == restarted_writer.event_id
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
    assert :ok = TerminalFailure.clear_active(workspace, context.issue_id)
    File.rm_rf!(Path.dirname(relocated_workspace))
  end

  test "receipt-to-active crashes leave a durable pending transaction that fails closed" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-pending-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "JARVIS-936")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    evidence =
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        issue_id: "pending-transaction",
        issue_identifier: "JARVIS-936",
        attempt: 0,
        session_id: nil,
        workspace: workspace,
        binding_id: nil
      })

    assert :simulated_crash =
             catch_throw(
               TerminalFailure.with_terminal_persist_hook_for_test(
                 fn :after_receipts -> throw(:simulated_crash) end,
                 fn -> TerminalFailure.persist(workspace, evidence) end
               )
             )

    receipt = Path.join(workspace, ".symphony/terminal-events/#{evidence.event_id}.json")
    assert File.regular?(receipt)
    refute File.exists?(Path.join(workspace, ".symphony/terminal-failure.json"))

    assert {:storage_fault, %{code: :incomplete_terminal_transaction, event_id: event_id}} =
             TerminalFailure.recovery_state(workspace, evidence.issue_id)

    assert event_id == evidence.event_id

    assert {:storage_fault, %{code: :incomplete_terminal_transaction}} =
             TerminalFailure.recovery_state_for_issue(evidence.issue_id)

    assert {:error, {:incomplete_terminal_transaction, event_id}} =
             TerminalFailure.storage_ready()

    assert {:ok, ^receipt} = TerminalFailure.persist(workspace, evidence)
    assert {:settled, %{event_id: ^event_id}} = TerminalFailure.recovery_state(workspace)
    assert :ok = TerminalFailure.settle_lifecycle(workspace, evidence.issue_id, event_id)
    assert :none = TerminalFailure.recovery_state(workspace, evidence.issue_id)
    assert File.regular?(receipt)
  end

  test "pending transaction corruption and storage failures remain fail closed" do
    {root, workspace, issue_id, _lock_path} = lock_fixture!("pending-errors")
    on_exit(fn -> File.rm_rf!(root) end)

    evidence =
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        issue_id: issue_id,
        issue_identifier: "JARVIS-936",
        attempt: 0,
        session_id: nil,
        workspace: workspace,
        binding_id: nil
      })

    local_pending = Path.join(workspace, ".symphony/terminal-pending.json")
    File.mkdir_p!(Path.dirname(local_pending))
    File.write!(local_pending, "not-json")
    assert {:error, :invalid_terminal_pending_marker} = TerminalFailure.recovery_state(workspace, issue_id)

    File.write!(local_pending, Jason.encode!(evidence))

    assert {:error, {:active_marker_owner_mismatch, ^local_pending}} =
             TerminalFailure.settle_lifecycle(workspace, issue_id, String.duplicate("a", 64))

    File.rm!(local_pending)
    File.mkdir!(local_pending)

    assert {:error, {^local_pending, :eisdir}} =
             TerminalFailure.settle_lifecycle(workspace, issue_id, evidence.event_id)

    File.rmdir!(local_pending)
    fallback_pending_root = Path.join(root, ".symphony/terminal-holds/pending")
    File.mkdir_p!(Path.dirname(fallback_pending_root))
    File.write!(fallback_pending_root, "blocked")

    assert {:error, {_path, :enotdir}} = TerminalFailure.recovery_state(workspace, issue_id)
    File.rm!(fallback_pending_root)

    state_root = Application.fetch_env!(:symphony_elixir, :terminal_state_root)
    state_pending_root = Path.join(state_root, "pending")
    File.rm_rf!(state_pending_root)
    File.write!(state_pending_root, "blocked")

    assert {:error, {:pending_marker_unavailable, _path, :enotdir}} =
             TerminalFailure.persist(workspace, evidence)

    File.rm!(state_pending_root)
    File.mkdir_p!(state_pending_root)
    malformed_global_pending = Path.join(state_pending_root, "malformed.json")
    File.write!(malformed_global_pending, "not-json")
    assert {:error, :invalid_terminal_pending_entry} = TerminalFailure.storage_ready()
    File.rm!(malformed_global_pending)
  end

  test "partial resume mirrors recover as storage faults instead of authorized handoffs" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-partial-resume-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "JARVIS-936")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    evidence =
      TerminalFailure.build(:provider_quota_exhausted, %{}, %{
        backend: :antigravity,
        issue_id: "partial-resume",
        issue_identifier: "JARVIS-936",
        attempt: 0,
        session_id: "prior-session",
        workspace: workspace,
        binding_id: "slot-a"
      })

    assert {:ok, _path} = TerminalFailure.persist(workspace, evidence)
    issue_hash = :crypto.hash(:sha256, evidence.issue_id) |> Base.encode16(case: :lower)

    global_resume =
      Path.join(
        Application.fetch_env!(:symphony_elixir, :terminal_state_root),
        "resumes/#{evidence.workflow_scope}-#{issue_hash}-#{evidence.event_id}.json"
      )

    File.mkdir_p!(global_resume)

    assert {:error, {:immutable_receipt_unavailable, ^global_resume, :invalid_receipt_target}} =
             TerminalFailure.record_resume(workspace, evidence, "slot-b", 1)

    assert {:storage_fault, %{code: :incomplete_resume_mirror}} =
             TerminalFailure.recovery_state(workspace, evidence.issue_id)

    local_resume = Path.join(workspace, ".symphony/terminal-resumes/#{evidence.event_id}.json")
    bytes = File.read!(local_resume)
    File.rm_rf!(global_resume)
    File.write!(global_resume, bytes)
    File.rm!(local_resume)

    assert {:storage_fault, %{code: :incomplete_resume_mirror}} =
             TerminalFailure.recovery_state(workspace, evidence.issue_id)

    File.write!(local_resume, bytes)

    assert {:ambiguous, %{event_id: event_id}} =
             TerminalFailure.recovery_state(workspace, evidence.issue_id)

    assert event_id == evidence.event_id
  end

  test "storage faults and partial terminal mirrors fail closed and clear by owner" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-storage-faults-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "JARVIS-936")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    evidence =
      TerminalFailure.build(:provider_quota_exhausted, %{}, %{
        backend: :antigravity,
        issue_id: "storage-fault-owner",
        issue_identifier: "JARVIS-936",
        attempt: 0,
        session_id: "storage-session",
        workspace: workspace,
        binding_id: "slot-a"
      })

    state_root = Application.fetch_env!(:symphony_elixir, :terminal_state_root)
    issue_hash = :crypto.hash(:sha256, evidence.issue_id) |> Base.encode16(case: :lower)
    scoped_identity = "#{evidence.workflow_scope}-#{issue_hash}"
    global_fault = Path.join(state_root, "faults/#{scoped_identity}.json")
    local_fault = Path.join(workspace, ".symphony/terminal-storage-fault.json")

    assert {:ok, _path} =
             TerminalFailure.persist_storage_fault(workspace, evidence, :active_marker_unavailable)

    assert {:storage_fault, %{event_id: event_id}} =
             TerminalFailure.recovery_state_for_issue(evidence.issue_id)

    assert event_id == evidence.event_id

    assert {:error, {:storage_fault_owner_mismatch, ^local_fault}} =
             TerminalFailure.clear_storage_fault(workspace, evidence.issue_id, String.duplicate("0", 64))

    assert :ok = TerminalFailure.clear_active(workspace, evidence.issue_id)
    assert :none = TerminalFailure.recovery_state_for_issue(evidence.issue_id)

    assert {:ok, _path} =
             TerminalFailure.persist_storage_fault(workspace, evidence, :active_marker_unavailable)

    fault_parent = Path.dirname(local_fault)
    File.chmod!(fault_parent, 0o500)

    assert {:error, {^local_fault, :eacces}} =
             TerminalFailure.clear_storage_fault(workspace, evidence.issue_id, evidence.event_id)

    File.chmod!(fault_parent, 0o700)
    assert :ok = TerminalFailure.clear_storage_fault(workspace, evidence.issue_id, evidence.event_id)

    File.mkdir_p!(global_fault)

    assert {:error, {^global_fault, :eisdir}} =
             TerminalFailure.recovery_state_for_issue(evidence.issue_id)

    File.rm_rf!(global_fault)
    File.mkdir_p!(local_fault)

    assert {:error, {^local_fault, :eisdir}} =
             TerminalFailure.recovery_state(workspace, evidence.issue_id)

    assert {:error, {^local_fault, :eisdir}} =
             TerminalFailure.clear_storage_fault(workspace, evidence.issue_id, evidence.event_id)

    File.rm_rf!(local_fault)
    File.write!(local_fault, "{}")

    assert {:error, {^local_fault, :invalid_terminal_storage_fault}} =
             TerminalFailure.clear_storage_fault(workspace, evidence.issue_id, evidence.event_id)

    File.rm!(local_fault)

    assert {:ok, _path} = TerminalFailure.persist(workspace, evidence)

    assert {:error, {:active_marker_owner_mismatch, _path}} =
             TerminalFailure.settle_lifecycle(
               workspace,
               evidence.issue_id,
               String.duplicate("f", 64)
             )

    global_event = Path.join(state_root, "events/#{scoped_identity}-#{evidence.event_id}.json")
    global_active = Path.join(state_root, "active/#{scoped_identity}.json")
    event_bytes = File.read!(global_event)
    active_bytes = File.read!(global_active)

    File.rm!(global_event)

    assert {:storage_fault, %{code: :incomplete_terminal_mirror}} =
             TerminalFailure.recovery_state(workspace, evidence.issue_id)

    assert :ok = TerminalFailure.clear_active(workspace, evidence.issue_id)
    assert {:ok, _path} = TerminalFailure.persist(workspace, evidence)

    File.write!(global_event, event_bytes)
    File.rm!(global_active)

    assert {:storage_fault, %{code: :incomplete_terminal_mirror}} =
             TerminalFailure.recovery_state(workspace, evidence.issue_id)

    File.write!(global_active, active_bytes)
    local_active = Path.join(workspace, ".symphony/terminal-failure.json")

    fallback_active =
      Path.join(
        root,
        ".symphony/terminal-holds/active/#{:crypto.hash(:sha256, Path.expand(workspace)) |> Base.encode16(case: :lower)}.json"
      )

    File.rm(local_active)
    File.rm(fallback_active)

    assert {:storage_fault, %{code: :incomplete_terminal_mirror}} =
             TerminalFailure.recovery_state_for_issue(evidence.issue_id)

    File.write!(local_active, active_bytes)

    assert {:settled, %{event_id: event_id}} =
             TerminalFailure.recovery_state_for_issue(evidence.issue_id)

    assert event_id == evidence.event_id
    assert :ok = TerminalFailure.clear_active(workspace, evidence.issue_id, evidence.event_id)
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

    clear_workspace = Path.join(root, "clear-permission")
    File.mkdir_p!(clear_workspace)

    clear_evidence =
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        issue_id: "clear-permission-issue",
        issue_identifier: "CLEAR-1",
        attempt: 0,
        session_id: nil,
        workspace: clear_workspace,
        binding_id: nil
      })

    assert {:ok, _path} = TerminalFailure.persist(clear_workspace, clear_evidence)
    metadata_dir = Path.join(clear_workspace, ".symphony")
    File.chmod!(metadata_dir, 0o500)

    marker = Path.join(clear_workspace, ".symphony/terminal-failure.json")

    assert {:error, {^marker, :eacces}} =
             TerminalFailure.clear_active(
               clear_workspace,
               clear_evidence.issue_id,
               clear_evidence.event_id
             )

    File.chmod!(metadata_dir, 0o700)
    assert :ok = TerminalFailure.clear_active(clear_workspace, clear_evidence.issue_id)
  end

  test "host lifecycle readiness fails closed when the state root is not writable" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-storage-probe-#{System.unique_integer([:positive])}"
      )

    blocked_root = Path.join(root, "state-root-file")
    File.mkdir_p!(root)
    File.write!(blocked_root, "not a directory")
    original_state_root = Application.get_env(:symphony_elixir, :terminal_state_root)

    on_exit(fn ->
      if original_state_root,
        do: Application.put_env(:symphony_elixir, :terminal_state_root, original_state_root),
        else: Application.delete_env(:symphony_elixir, :terminal_state_root)

      File.rm_rf!(root)
    end)

    Application.put_env(:symphony_elixir, :terminal_state_root, blocked_root)

    assert {:error, {:terminal_state_namespace_unavailable, "events", reason}} =
             TerminalFailure.storage_ready()

    assert reason in [:eexist, :enotdir]
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

    assert File.regular?(
             Path.join(
               root,
               "logs/terminal-holds/active/#{evidence.workflow_scope}-#{issue_hash}.json"
             )
           )

    assert :ok = TerminalFailure.clear_active(workspace, evidence.issue_id)
  end

  test "global lifecycle markers are workflow-scoped and cleared only by their event owner" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-scope-#{System.unique_integer([:positive])}"
      )

    state_root = Path.join(root, "state")
    workspace_a = Path.join(root, "workflow-a/SHARED-1")
    workspace_b = Path.join(root, "workflow-b/SHARED-1")
    File.mkdir_p!(workspace_a)
    File.mkdir_p!(workspace_b)
    original_scope = Application.get_env(:symphony_elixir, :terminal_lifecycle_scope)
    original_state_root = Application.get_env(:symphony_elixir, :terminal_state_root)

    on_exit(fn ->
      if original_scope,
        do: Application.put_env(:symphony_elixir, :terminal_lifecycle_scope, original_scope),
        else: Application.delete_env(:symphony_elixir, :terminal_lifecycle_scope)

      if original_state_root,
        do: Application.put_env(:symphony_elixir, :terminal_state_root, original_state_root),
        else: Application.delete_env(:symphony_elixir, :terminal_state_root)

      File.rm_rf!(root)
    end)

    Application.put_env(:symphony_elixir, :terminal_state_root, state_root)
    Application.put_env(:symphony_elixir, :terminal_lifecycle_scope, String.duplicate("a", 64))

    evidence_a =
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        issue_id: "shared-issue-id",
        issue_identifier: "SHARED-1",
        attempt: 0,
        session_id: "session-a",
        workspace: workspace_a,
        binding_id: nil
      })

    assert {:ok, _path} = TerminalFailure.persist(workspace_a, evidence_a)

    Application.put_env(:symphony_elixir, :terminal_lifecycle_scope, String.duplicate("b", 64))

    evidence_b =
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        issue_id: "shared-issue-id",
        issue_identifier: "SHARED-1",
        attempt: 0,
        session_id: "session-b",
        workspace: workspace_b,
        binding_id: nil
      })

    assert {:ok, _path} = TerminalFailure.persist(workspace_b, evidence_b)
    assert {:settled, %{event_id: event_b}} = TerminalFailure.recovery_state(workspace_b, "shared-issue-id")
    assert event_b == evidence_b.event_id

    assert {:error, {:active_marker_owner_mismatch, _path}} =
             TerminalFailure.clear_active(
               workspace_b,
               "shared-issue-id",
               evidence_a.event_id
             )

    assert :ok = TerminalFailure.clear_active(workspace_a, "shared-issue-id", evidence_a.event_id)
    assert {:settled, %{event_id: ^event_b}} = TerminalFailure.recovery_state(workspace_b, "shared-issue-id")
    assert :ok = TerminalFailure.clear_active(workspace_b, "shared-issue-id", evidence_b.event_id)
  end

  test "active ownership rejects unresumed and malformed predecessor markers" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-owner-reject-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "JARVIS-936")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    context = %{
      backend: :antigravity,
      issue_id: "owner-reject",
      issue_identifier: "JARVIS-936",
      attempt: 0,
      session_id: "first-session",
      workspace: workspace,
      binding_id: "slot-a"
    }

    first = TerminalFailure.build(:provider_quota_exhausted, %{}, context)
    assert {:ok, _path} = TerminalFailure.persist(workspace, first)

    second =
      TerminalFailure.build(
        :provider_auth_failed,
        %{},
        %{context | attempt: 1, session_id: "second-session"}
      )

    assert {:error, :active_marker_owner_mismatch} = TerminalFailure.persist(workspace, second)

    marker = Path.join(workspace, ".symphony/terminal-failure.json")
    File.write!(marker, "not-json")

    third =
      TerminalFailure.build(
        :provider_network_unreachable,
        %{},
        %{context | attempt: 2, session_id: "third-session"}
      )

    assert {:error, {:active_marker_invalid, %Jason.DecodeError{}}} =
             TerminalFailure.persist(workspace, third)
  end

  test "active replacement fails closed when an ownership-checked marker cannot be rewritten" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-owner-replace-error-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "JARVIS-936")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    context = %{
      backend: :antigravity,
      issue_id: "owner-replace-error",
      issue_identifier: "JARVIS-936",
      attempt: 0,
      session_id: "first-session",
      workspace: workspace,
      binding_id: "slot-a"
    }

    first = TerminalFailure.build(:provider_quota_exhausted, %{}, context)
    assert {:ok, _path} = TerminalFailure.persist(workspace, first)
    assert {:ok, _path} = TerminalFailure.record_resume(workspace, first, "slot-b", 1)
    metadata_dir = Path.join(workspace, ".symphony")
    File.chmod!(metadata_dir, 0o500)

    second =
      TerminalFailure.build(
        :provider_auth_failed,
        %{},
        Map.merge(context, %{
          attempt: 1,
          session_id: "second-session",
          binding_id: "slot-b",
          predecessor_event_id: first.event_id
        })
      )

    assert {:error, {:active_marker_replace_failed, :eacces}} =
             TerminalFailure.persist(workspace, second)

    File.chmod!(metadata_dir, 0o700)
    assert :ok = TerminalFailure.clear_active(workspace, context.issue_id, first.event_id)
  end

  test "a resumed event may atomically hand active ownership to its next terminal event" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-owner-handoff-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "JARVIS-936")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    context = %{
      backend: :antigravity,
      issue_id: "owner-handoff",
      issue_identifier: "JARVIS-936",
      attempt: 0,
      session_id: "first-session",
      workspace: workspace,
      binding_id: "slot-a"
    }

    first = TerminalFailure.build(:provider_quota_exhausted, %{}, context)
    assert {:ok, _path} = TerminalFailure.persist(workspace, first)
    assert {:ok, _path} = TerminalFailure.record_resume(workspace, first, "slot-b", 1)

    second =
      TerminalFailure.build(
        :provider_auth_failed,
        %{provider_code: "UNAUTHENTICATED", http_status: 401},
        Map.merge(context, %{
          attempt: 1,
          session_id: "second-session",
          binding_id: "slot-b",
          predecessor_event_id: first.event_id
        })
      )

    marker_lock = TerminalFailure.active_lock_path_for_test(workspace, context.issue_id)
    parent = self()

    holder =
      spawn(fn ->
        TerminalFailure.hold_active_lock_for_test(workspace, context.issue_id, parent)
      end)

    assert_receive {:active_lock_acquired, ^holder}, 1_000

    assert {:error, {:active_marker_locked, ^marker_lock, :eexist}} =
             TerminalFailure.persist(workspace, second)

    holder_ref = Process.monitor(holder)
    send(holder, :release_active_lock)
    assert_receive {:DOWN, ^holder_ref, :process, ^holder, :normal}, 1_000

    stale_writer =
      TerminalFailure.build(
        :provider_network_unreachable,
        %{},
        Map.merge(context, %{
          attempt: 1,
          session_id: "stale-session",
          binding_id: "slot-c",
          predecessor_event_id: first.event_id
        })
      )

    assert {:error, :active_marker_owner_mismatch} =
             TerminalFailure.persist(workspace, stale_writer)

    wrong_attempt =
      TerminalFailure.build(
        :provider_network_unreachable,
        %{},
        Map.merge(context, %{
          attempt: 2,
          session_id: "wrong-attempt",
          binding_id: "slot-b",
          predecessor_event_id: first.event_id
        })
      )

    assert {:error, :active_marker_owner_mismatch} =
             TerminalFailure.persist(workspace, wrong_attempt)

    assert {:ok, _path} = TerminalFailure.persist(workspace, second)
    assert {:settled, %{event_id: event_id}} = TerminalFailure.recovery_state(workspace, context.issue_id)
    assert event_id == second.event_id
    assert :ok = TerminalFailure.clear_active(workspace, context.issue_id, second.event_id)
  end

  test "crash-stale owned locks are reclaimed without manual filesystem repair" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-stale-lock-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "JARVIS-936")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    context = %{
      backend: :antigravity,
      issue_id: "stale-lock",
      issue_identifier: "JARVIS-936",
      attempt: 0,
      session_id: "stale-lock-session",
      workspace: workspace,
      binding_id: "slot-a"
    }

    parent = self()

    clean_holder =
      spawn(fn ->
        TerminalFailure.hold_active_lock_for_test(workspace, context.issue_id, parent)
      end)

    assert_receive {:active_lock_acquired, ^clean_holder}, 1_000
    clean_ref = Process.monitor(clean_holder)
    send(clean_holder, :release_active_lock)
    assert_receive {:DOWN, ^clean_ref, :process, ^clean_holder, :normal}, 1_000

    holder =
      spawn(fn ->
        TerminalFailure.hold_active_lock_for_test(workspace, context.issue_id, parent)
      end)

    assert_receive {:active_lock_acquired, ^holder}, 1_000
    assert {:error, {:active_marker_locked, _path, :eexist}} = TerminalFailure.storage_ready()
    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 1_000

    assert :ok = TerminalFailure.storage_ready()
    evidence = TerminalFailure.build(:worker_crashed, %{}, context)
    assert {:ok, _path} = TerminalFailure.persist(workspace, evidence)
    assert {:settled, %{event_id: event_id}} = TerminalFailure.recovery_state(workspace, context.issue_id)
    assert event_id == evidence.event_id
  end

  test "lock recovery requires positive same-host owner proof" do
    {root, workspace, issue_id, lock_path} = lock_fixture!("owner-proof")
    on_exit(fn -> File.rm_rf!(root) end)

    {holder, owner} = start_lock_holder!(workspace, issue_id, lock_path)
    assert {:error, {:active_marker_locked, ^lock_path, :eexist}} = TerminalFailure.storage_ready()
    kill_lock_holder!(holder)

    prior_owner = Map.put(owner, "runtime_instance", String.duplicate("d", 64))
    File.write!(lock_path, Jason.encode!(prior_owner))

    unavailable = [
      %{machine_read: {:error, :eacces}},
      %{boot_read: {:ok, ""}},
      %{pid_namespace_read: {:error, :eacces}},
      %{pid_namespace_read: {:ok, ""}},
      %{process_read: fn _pid -> {:error, :eacces} end},
      %{process_read: fn _pid -> {:ok, "malformed"} end},
      %{process_read: fn _pid -> {:ok, process_stat("x")} end}
    ]

    for overrides <- unavailable do
      assert {:error, {:active_marker_locked, ^lock_path, :eexist}} =
               TerminalFailure.with_lock_overrides_for_test(overrides, &TerminalFailure.storage_ready/0)
    end

    assert :ok =
             TerminalFailure.with_lock_overrides_for_test(
               %{process_read: fn _pid -> {:error, :enoent} end},
               &TerminalFailure.storage_ready/0
             )
  end

  test "lock recovery distinguishes PID reuse, namespaces, reboots, and unsupported owners" do
    {root, workspace, issue_id, lock_path} = lock_fixture!("owner-generations")
    on_exit(fn -> File.rm_rf!(root) end)

    {holder, owner} = start_lock_holder!(workspace, issue_id, lock_path)
    kill_lock_holder!(holder)
    assert owner["probe_status"] == "verified"

    other_namespace =
      owner
      |> Map.put("runtime_instance", String.duplicate("a", 64))
      |> Map.put("pid_namespace_scope", String.duplicate("b", 64))

    File.write!(lock_path, Jason.encode!(other_namespace))
    assert {:error, {:active_marker_locked, ^lock_path, :eexist}} = TerminalFailure.storage_ready()

    rebooted =
      owner
      |> Map.put("runtime_instance", String.duplicate("a", 64))
      |> Map.put("boot_scope", String.duplicate("b", 64))

    File.write!(lock_path, Jason.encode!(rebooted))
    assert :ok = TerminalFailure.storage_ready()

    {holder, owner} = start_lock_holder!(workspace, issue_id, lock_path)
    kill_lock_holder!(holder)
    File.write!(lock_path, Jason.encode!(Map.put(owner, "runtime_instance", String.duplicate("e", 64))))

    reused_start = owner["os_start_time"] + 1
    reused_stat = process_stat(reused_start)

    assert :ok =
             TerminalFailure.with_lock_overrides_for_test(
               %{process_read: fn _pid -> {:ok, reused_stat} end},
               &TerminalFailure.storage_ready/0
             )

    unavailable_owner =
      owner
      |> Map.put("runtime_instance", String.duplicate("f", 64))
      |> Map.merge(%{
        "probe_status" => "unavailable",
        "machine_scope" => nil,
        "boot_scope" => nil,
        "pid_namespace_scope" => nil,
        "os_pid" => nil,
        "os_start_time" => nil
      })

    File.write!(lock_path, Jason.encode!(unavailable_owner))
    assert {:error, {:active_marker_locked, ^lock_path, :eexist}} = TerminalFailure.storage_ready()
  end

  test "atomic lock claims preserve live generations and reject malformed owners" do
    {root, workspace, issue_id, lock_path} = lock_fixture!("atomic-claim")
    on_exit(fn -> File.rm_rf!(root) end)
    {holder, owner} = start_lock_holder!(workspace, issue_id, lock_path)

    evidence =
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        issue_id: issue_id,
        issue_identifier: "JARVIS-936",
        attempt: 0,
        session_id: nil,
        workspace: workspace,
        binding_id: nil
      })

    original_bytes = File.read!(lock_path)
    assert {:error, {:active_marker_locked, ^lock_path, :eexist}} = TerminalFailure.persist(workspace, evidence)
    assert File.read!(lock_path) == original_bytes
    assert Path.wildcard("#{lock_path}.candidate-*") == []
    assert Process.alive?(holder)
    kill_lock_holder!(holder)

    for encoded_pid <- ["not-base64", Base.encode64("not-a-term")] do
      File.write!(lock_path, Jason.encode!(Map.put(owner, "erlang_pid", encoded_pid)))
      assert {:error, {:active_marker_locked, ^lock_path, :eexist}} = TerminalFailure.storage_ready()
    end

    File.write!(lock_path, Jason.encode!(owner))
    assert :ok = TerminalFailure.storage_ready()

    for malformed <- ["[]", "{}", Jason.encode!(Map.put(owner, "probe_status", "invalid"))] do
      File.write!(lock_path, malformed)

      assert {:error, {:active_marker_locked, ^lock_path, :invalid_lock_owner}} =
               TerminalFailure.storage_ready()
    end

    File.rm!(lock_path)

    assert {:ok, _path} =
             TerminalFailure.with_lock_overrides_for_test(
               %{machine_read: {:error, :eacces}},
               fn -> TerminalFailure.persist(workspace, evidence) end
             )

    assert :ok = TerminalFailure.clear_active(workspace, issue_id, evidence.event_id)
  end

  test "lock reclamation fencing handles contention, disappearance, and cleanup races" do
    {root, workspace, issue_id, lock_path} = lock_fixture!("reclaim-fence")
    on_exit(fn -> File.rm_rf!(root) end)
    {holder, owner} = start_lock_holder!(workspace, issue_id, lock_path)
    kill_lock_holder!(holder)
    parent = self()

    reclaimer =
      Task.async(fn ->
        TerminalFailure.with_lock_overrides_for_test(
          %{
            reclaim_link: fn source, destination ->
              send(parent, :reclaim_link_started)

              receive do
                :finish_reclaim_link -> File.ln(source, destination)
              end
            end
          },
          &TerminalFailure.storage_ready/0
        )
      end)

    assert_receive :reclaim_link_started, 1_000

    concurrent_startup =
      Task.async(fn ->
        send(parent, :concurrent_startup_called)
        TerminalFailure.storage_ready()
      end)

    assert_receive :concurrent_startup_called, 1_000
    assert nil == Task.yield(concurrent_startup, 0)
    send(reclaimer.pid, :finish_reclaim_link)
    assert :ok = Task.await(reclaimer, 1_000)
    assert :ok = Task.await(concurrent_startup, 1_000)

    File.write!(lock_path, Jason.encode!(owner))

    assert :ok =
             TerminalFailure.with_lock_overrides_for_test(
               %{reclaim_link: fn _source, _destination -> {:error, :enoent} end},
               &TerminalFailure.storage_ready/0
             )

    for reason <- [:eexist, :eacces] do
      expected_reason = if reason == :eexist, do: :eexist, else: :eacces

      assert {:error, {:active_marker_locked, ^lock_path, ^expected_reason}} =
               TerminalFailure.with_lock_overrides_for_test(
                 %{reclaim_link: fn _source, _destination -> {:error, reason} end},
                 &TerminalFailure.storage_ready/0
               )
    end

    failed_evidence =
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        issue_id: issue_id,
        issue_identifier: "JARVIS-936",
        attempt: 0,
        session_id: nil,
        workspace: workspace,
        binding_id: nil
      })

    assert {:error, {:active_marker_locked, ^lock_path, :eacces}} =
             TerminalFailure.with_lock_overrides_for_test(
               %{reclaim_link: fn _source, _destination -> {:error, :eacces} end},
               fn -> TerminalFailure.persist(workspace, failed_evidence) end
             )

    assert :ok =
             TerminalFailure.with_lock_overrides_for_test(
               %{owner_read: fn _path -> {:error, :enoent} end},
               &TerminalFailure.storage_ready/0
             )

    assert {:error, {:active_marker_locked, ^lock_path, :eexist}} =
             TerminalFailure.with_lock_overrides_for_test(
               %{public_remove: fn _path -> {:error, :eacces} end},
               &TerminalFailure.storage_ready/0
             )

    evidence =
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        issue_id: issue_id,
        issue_identifier: "JARVIS-936",
        attempt: 0,
        session_id: nil,
        workspace: workspace,
        binding_id: nil
      })

    assert {:ok, _receipt} = TerminalFailure.persist(workspace, evidence)
    assert :ok = TerminalFailure.clear_active(workspace, issue_id, evidence.event_id)

    {holder, _live_owner} = start_lock_holder!(workspace, issue_id, lock_path)
    replacement = Map.put(owner, "token", String.duplicate("b", 64))
    File.write!(lock_path, Jason.encode!(replacement))
    holder_ref = Process.monitor(holder)
    send(holder, :release_active_lock)
    assert_receive {:DOWN, ^holder_ref, :process, ^holder, :normal}, 1_000
    assert File.regular?(lock_path)
    File.rm!(lock_path)
  end

  test "lock namespace recovery fails closed on storage errors" do
    {root, workspace, issue_id, lock_path} = lock_fixture!("namespace")
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(lock_path)
    File.write!(Path.join(lock_path, "owner.json"), "{}")

    assert {:error, {:active_marker_locked, ^lock_path, :unsupported_legacy_lock_directory}} =
             TerminalFailure.storage_ready()

    File.rm_rf!(lock_path)
    candidate_path = "#{lock_path}.candidate-abandoned"
    reclaim_path = "#{lock_path}.reclaim-abandoned"
    File.write!(candidate_path, "candidate")
    File.write!(reclaim_path, "reclaim")
    assert :ok = TerminalFailure.storage_ready()
    refute File.exists?(candidate_path)
    refute File.exists?(reclaim_path)

    File.mkdir!(candidate_path)

    assert {:error, {:active_marker_locked, ^candidate_path, {:invalid_transient_lock_artifact, :directory}}} =
             TerminalFailure.storage_ready()

    File.rmdir!(candidate_path)
    File.write!(candidate_path, "candidate")

    assert :ok =
             TerminalFailure.with_lock_overrides_for_test(
               %{lock_lstat: fn _path -> {:error, :enoent} end},
               &TerminalFailure.storage_ready/0
             )

    File.rm!(candidate_path)
    File.write!(candidate_path, "candidate")

    assert {:error, {:active_marker_locked, ^candidate_path, :eacces}} =
             TerminalFailure.with_lock_overrides_for_test(
               %{lock_lstat: fn _path -> {:error, :eacces} end},
               &TerminalFailure.storage_ready/0
             )

    assert {:error, {:active_marker_locked, ^candidate_path, :eperm}} =
             TerminalFailure.with_lock_overrides_for_test(
               %{transient_remove: fn _path -> {:error, :eperm} end},
               &TerminalFailure.storage_ready/0
             )

    File.rm!(candidate_path)
    invalid_target = Path.join(root, "invalid-lock-target")
    File.write!(invalid_target, "target")
    File.ln_s!(invalid_target, lock_path)

    assert {:error, {:active_marker_locked, ^lock_path, {:invalid_lock_target, :symlink}}} =
             TerminalFailure.storage_ready()

    File.rm!(lock_path)
    File.write!(lock_path, "published")

    assert :ok =
             TerminalFailure.with_lock_overrides_for_test(
               %{lock_lstat: fn _path -> {:error, :enoent} end},
               &TerminalFailure.storage_ready/0
             )

    assert {:error, {:active_marker_locked, ^lock_path, :eacces}} =
             TerminalFailure.with_lock_overrides_for_test(
               %{lock_lstat: fn _path -> {:error, :eacces} end},
               &TerminalFailure.storage_ready/0
             )

    File.rm!(lock_path)

    assert :ok =
             TerminalFailure.with_lock_overrides_for_test(
               %{pending_ls: {:error, :enoent}},
               &TerminalFailure.storage_ready/0
             )

    assert {:error, {:terminal_pending_namespace_unavailable, :eacces}} =
             TerminalFailure.with_lock_overrides_for_test(
               %{pending_ls: {:error, :eacces}},
               &TerminalFailure.storage_ready/0
             )

    assert {:error, :terminal_directory_sync_failed} =
             TerminalFailure.with_lock_overrides_for_test(
               %{directory_sync: fn _directory -> {"sync failed", 1} end},
               &TerminalFailure.storage_ready/0
             )

    assert {:error, :terminal_directory_sync_failed} =
             TerminalFailure.with_lock_overrides_for_test(
               %{directory_sync: fn _directory -> raise "sync crashed" end},
               &TerminalFailure.storage_ready/0
             )

    aborted_transaction = %{namespace_transaction: fn _operation -> {:aborted, :forced} end}

    assert {:error, {:terminal_lock_namespace_serialization_failed, :forced}} =
             TerminalFailure.with_lock_overrides_for_test(
               aborted_transaction,
               &TerminalFailure.storage_ready/0
             )

    assert {:error, {:terminal_lock_namespace_serialization_failed, :forced}} =
             TerminalFailure.with_lock_overrides_for_test(aborted_transaction, fn ->
               TerminalFailure.clear_active(workspace, issue_id, String.duplicate("a", 64))
             end)

    state_root = Application.fetch_env!(:symphony_elixir, :terminal_state_root)
    unrelated_lock_entry = Path.join(state_root, "locks/operator-note")
    File.write!(unrelated_lock_entry, "leave intact")
    assert :ok = TerminalFailure.storage_ready()
    assert File.regular?(unrelated_lock_entry)
    File.rm!(unrelated_lock_entry)

    assert_raise ArgumentError, fn ->
      TerminalFailure.with_lock_overrides_for_test(%{unknown: :value}, fn -> :ok end)
    end

    assert_raise ArgumentError, fn ->
      TerminalFailure.with_lock_overrides_for_test(%{process_read: :not_a_function}, fn -> :ok end)
    end

    assert :ok =
             TerminalFailure.with_lock_overrides_for_test(
               %{file_ls: {:error, :enoent}},
               fn ->
                 TerminalFailure.with_lock_overrides_for_test(
                   %{file_ls: {:error, :enoent}},
                   &TerminalFailure.storage_ready/0
                 )
               end
             )

    assert {:error, {:terminal_lock_namespace_unavailable, :eacces}} =
             TerminalFailure.with_lock_overrides_for_test(
               %{file_ls: {:error, :eacces}},
               &TerminalFailure.storage_ready/0
             )

    evidence =
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        issue_id: issue_id,
        issue_identifier: "JARVIS-936",
        attempt: 0,
        session_id: nil,
        workspace: workspace,
        binding_id: nil
      })

    state_root = Application.fetch_env!(:symphony_elixir, :terminal_state_root)
    lock_root = Path.join(state_root, "locks")
    File.rm_rf!(lock_root)
    File.write!(lock_root, "blocked")

    assert {:error, {:active_marker_locked, _path, {:lock_namespace_unavailable, reason}}} =
             TerminalFailure.persist(workspace, evidence)

    assert reason in [:eexist, :enotdir]
    File.rm!(lock_root)
    File.mkdir_p!(lock_root)
  end

  test "active marker IO failures fail closed during clear, validation, and transfer" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-active-io-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "JARVIS-936")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    context = %{
      backend: :antigravity,
      issue_id: "active-io",
      issue_identifier: "JARVIS-936",
      attempt: 0,
      session_id: "first-session",
      workspace: workspace,
      binding_id: "slot-a"
    }

    first = TerminalFailure.build(:provider_quota_exhausted, %{}, context)
    assert {:ok, _path} = TerminalFailure.persist(workspace, first)
    active_marker = Path.join(workspace, ".symphony/terminal-failure.json")
    active_parent = Path.dirname(active_marker)
    File.chmod!(active_parent, 0o500)

    assert {:error, {^active_marker, :eacces}} =
             TerminalFailure.remove_active_marker_for_test(active_marker)

    File.chmod!(active_parent, 0o700)
    removable = Path.join(root, "removable-active.json")
    File.write!(removable, "marker")
    assert :ok = TerminalFailure.remove_active_marker_for_test(removable)
    refute File.exists?(removable)
    assert {:ok, _path} = TerminalFailure.record_resume(workspace, first, "slot-b", 1)
    File.chmod!(active_marker, 0o000)

    second =
      TerminalFailure.build(
        :provider_auth_failed,
        %{},
        Map.merge(context, %{
          attempt: 1,
          session_id: "second-session",
          binding_id: "slot-b",
          predecessor_event_id: first.event_id
        })
      )

    assert {:error, {:active_marker_invalid, :eacces}} =
             TerminalFailure.active_transfer_allowed_for_test(active_marker, "different", second)

    File.chmod!(active_marker, 0o600)
    File.chmod!(active_parent, 0o500)
    successor_payload = Jason.encode!(second, pretty: true)

    assert {:error, {:active_marker_replace_failed, :enoent}} =
             TerminalFailure.persist_active_paths_for_test(
               [Path.join(root, "missing-active.json")],
               successor_payload
             )

    assert {:error, {:active_marker_replace_failed, :eacces}} =
             TerminalFailure.persist_active_paths_for_test([active_marker], successor_payload)

    File.chmod!(active_parent, 0o700)

    for reason <- [
          :active_marker_owner_mismatch,
          {:active_marker_invalid, :eacces},
          {:active_marker_replace_failed, :eacces}
        ] do
      assert {:error, ^reason} = TerminalFailure.classify_candidate_error_for_test(reason)
    end

    assert {:ok, _path} = TerminalFailure.persist(workspace, second)
    assert :ok = TerminalFailure.clear_active(workspace, context.issue_id, second.event_id)
  end

  test "a cleared predecessor cannot be resurrected by a stale authorized successor" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-cleared-predecessor-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "JARVIS-936")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    context = %{
      backend: :antigravity,
      issue_id: "cleared-predecessor",
      issue_identifier: "JARVIS-936",
      attempt: 0,
      session_id: "first-session",
      workspace: workspace,
      binding_id: "slot-a"
    }

    first = TerminalFailure.build(:provider_quota_exhausted, %{}, context)
    assert {:ok, _path} = TerminalFailure.persist(workspace, first)
    assert {:ok, _path} = TerminalFailure.record_resume(workspace, first, "slot-b", 1)
    assert :ok = TerminalFailure.clear_active(workspace, context.issue_id, first.event_id)

    successor =
      TerminalFailure.build(
        :worker_crashed,
        %{},
        Map.merge(context, %{
          attempt: 1,
          session_id: "second-session",
          binding_id: "slot-b",
          predecessor_event_id: first.event_id
        })
      )

    assert {:error, :active_marker_owner_mismatch} =
             TerminalFailure.persist(workspace, successor)

    assert :none = TerminalFailure.recovery_state(workspace, context.issue_id)
  end

  test "fallback marker ownership is transferred in place after storage recovers" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-fallback-transfer-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "JARVIS-936")
    preferred_marker = Path.join(workspace, ".symphony/terminal-failure.json")
    File.mkdir_p!(preferred_marker)
    on_exit(fn -> File.rm_rf!(root) end)

    context = %{
      backend: :antigravity,
      issue_id: "fallback-transfer",
      issue_identifier: "JARVIS-936",
      attempt: 0,
      session_id: "first-session",
      workspace: workspace,
      binding_id: "slot-a"
    }

    first = TerminalFailure.build(:provider_quota_exhausted, %{}, context)
    assert {:ok, _receipt_path} = TerminalFailure.persist(workspace, first)
    workspace_hash = :crypto.hash(:sha256, Path.expand(workspace)) |> Base.encode16(case: :lower)

    fallback_marker =
      Path.join(root, ".symphony/terminal-holds/active/#{workspace_hash}.json")

    assert File.regular?(fallback_marker)
    assert {:ok, _path} = TerminalFailure.record_resume(workspace, first, "slot-b", 1)
    File.rm_rf!(preferred_marker)

    second =
      TerminalFailure.build(
        :provider_auth_failed,
        %{},
        Map.merge(context, %{
          attempt: 1,
          session_id: "second-session",
          binding_id: "slot-b",
          predecessor_event_id: first.event_id
        })
      )

    assert {:ok, _receipt_path} = TerminalFailure.persist(workspace, second)
    assert Jason.decode!(File.read!(fallback_marker))["event_id"] == second.event_id
    refute File.exists?(preferred_marker)
    assert {:settled, %{event_id: event_id}} = TerminalFailure.recovery_state(workspace, context.issue_id)
    assert event_id == second.event_id
    assert :ok = TerminalFailure.clear_active(workspace, context.issue_id, second.event_id)
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

    valid =
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        issue_id: "issue-tamper",
        issue_identifier: "JARVIS-936",
        attempt: 0,
        writer_id: String.duplicate("c", 64),
        session_id: nil,
        workspace: workspace,
        binding_id: nil
      })

    File.rm!(marker)
    assert {:ok, _path} = TerminalFailure.persist(workspace, valid)
    persisted = marker |> File.read!() |> Jason.decode!()

    File.write!(marker, Jason.encode!(Map.put(persisted, "writer_id", "short")))

    assert {:error, :invalid_terminal_failure_receipt} =
             TerminalFailure.recovery_state(workspace)

    File.write!(marker, Jason.encode!(Map.put(persisted, "unexpected", "not integrity bound")))

    assert {:error, :invalid_terminal_failure_receipt} =
             TerminalFailure.recovery_state(workspace)

    File.write!(marker, Jason.encode!(Map.put(persisted, "occurred_at", "2099-01-01T00:00:00Z")))

    assert {:error, :invalid_terminal_failure_receipt} =
             TerminalFailure.recovery_state(workspace)

    for field <- ["public_attempt", "provider_code", "http_status", "reset_hint"] do
      File.write!(marker, Jason.encode!(Map.put(persisted, field, nil)))

      assert {:error, :invalid_terminal_failure_receipt} =
               TerminalFailure.recovery_state(workspace)
    end

    for {field, value} <- [{"reason", 42}, {"backend", "unknown"}, {"issue_id", 42}] do
      File.write!(marker, Jason.encode!(Map.put(persisted, field, value)))

      assert {:error, :invalid_terminal_failure_receipt} =
               TerminalFailure.recovery_state(workspace)
    end

    assert_raise ArgumentError, fn ->
      TerminalFailure.build(:worker_crashed, %{}, %{
        backend: :antigravity,
        workspace: 42
      })
    end
  end

  defp lock_fixture!(name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-lock-#{name}-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "JARVIS-936")
    File.mkdir_p!(workspace)
    issue_id = "lock-#{name}"
    {root, workspace, issue_id, TerminalFailure.active_lock_path_for_test(workspace, issue_id)}
  end

  defp start_lock_holder!(workspace, issue_id, lock_path) do
    parent = self()
    holder = spawn(fn -> TerminalFailure.hold_active_lock_for_test(workspace, issue_id, parent) end)
    assert_receive {:active_lock_acquired, ^holder}, 1_000
    {holder, lock_path |> File.read!() |> Jason.decode!()}
  end

  defp kill_lock_holder!(holder) do
    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 1_000
    :ok
  end

  defp process_stat(start_time) do
    encoded_start_time = if is_integer(start_time), do: Integer.to_string(start_time), else: start_time
    "999 (beam) " <> Enum.join(["S"] ++ List.duplicate("0", 18) ++ [encoded_start_time], " ")
  end
end
