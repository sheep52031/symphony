defmodule SymphonyElixir.TerminalFailure do
  @moduledoc """
  Provider-neutral, bounded terminal evidence emitted after a worker attempt can no longer continue.

  Provider adapters classify native failures. This module retains only reviewed structured fields,
  binds correlation fields, and persists immutable receipts plus a fail-closed active marker. Raw
  provider prose, account identifiers, profile paths, and credential payloads are never retained.
  """

  @max_hint_bytes 128
  @lock_retry_attempts 40
  @lock_retry_delay_ms 5
  @runtime_instance_key {__MODULE__, :runtime_instance}
  @lock_namespace_mutex {__MODULE__, :lock_namespace_mutex}
  @sync_path "/usr/bin/sync"
  @native_cleanup_wait_attempts if(Mix.env() == :test, do: 4, else: 120)
  @native_cleanup_wait_delay_ms 50

  if Mix.env() == :test do
    @lock_test_overrides_key {__MODULE__, :lock_test_overrides}
    @terminal_persist_hook_key {__MODULE__, :terminal_persist_hook}
    @lock_test_override_keys MapSet.new([
                               :machine_read,
                               :boot_read,
                               :pid_namespace_read,
                               :process_read,
                               :file_ls,
                               :pending_ls,
                               :owner_read,
                               :lock_lstat,
                               :reclaim_link,
                               :public_remove,
                               :transient_remove,
                               :directory_sync,
                               :namespace_transaction,
                               :native_cleanup_wait,
                               :cleanup_ls,
                               :cleanup_lstat
                             ])
  end

  @required_evidence_keys MapSet.new([
                            "event_id",
                            "integrity_hash",
                            "workflow_scope",
                            "reason",
                            "category",
                            "backend",
                            "issue_id",
                            "issue_identifier",
                            "attempt",
                            "session_id",
                            "workspace",
                            "binding_id",
                            "predecessor_event_id",
                            "occurred_at"
                          ])
  @native_cleanup_fence_keys MapSet.new([
                               "version",
                               "cleanup_id",
                               "workflow_scope",
                               "runtime_instance",
                               "created_at",
                               "integrity_hash"
                             ])

  @optional_evidence_keys MapSet.new([
                            "writer_id",
                            "public_attempt",
                            "provider_code",
                            "http_status",
                            "reset_hint",
                            "liveness"
                          ])
  @reasons [
    :provider_quota_exhausted,
    :provider_auth_failed,
    :provider_network_unreachable,
    :permission_denied,
    :worker_crashed,
    :worker_stalled,
    :provider_protocol_error,
    :unknown_terminal_failure
  ]

  @type reason ::
          :provider_quota_exhausted
          | :provider_auth_failed
          | :provider_network_unreachable
          | :permission_denied
          | :worker_crashed
          | :worker_stalled
          | :provider_protocol_error
          | :unknown_terminal_failure

  @type evidence :: %{
          required(:event_id) => String.t(),
          required(:integrity_hash) => String.t(),
          required(:workflow_scope) => String.t(),
          required(:reason) => reason(),
          required(:category) => String.t(),
          required(:backend) => atom(),
          required(:issue_id) => String.t() | nil,
          required(:issue_identifier) => String.t() | nil,
          required(:attempt) => non_neg_integer() | nil,
          optional(:writer_id) => String.t(),
          optional(:public_attempt) => non_neg_integer(),
          required(:session_id) => String.t() | nil,
          required(:workspace) => Path.t(),
          required(:binding_id) => String.t() | nil,
          required(:predecessor_event_id) => String.t() | nil,
          required(:occurred_at) => String.t(),
          optional(:provider_code) => String.t(),
          optional(:http_status) => non_neg_integer(),
          optional(:reset_hint) => String.t(),
          optional(:liveness) => atom()
        }

  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @spec build(reason(), map(), map()) :: evidence()
  def build(reason, details, context) when reason in @reasons and is_map(details) and is_map(context) do
    evidence = %{
      workflow_scope: lifecycle_scope(),
      reason: reason,
      category: category(reason),
      backend: Map.fetch!(context, :backend),
      issue_id: bounded_optional(Map.get(context, :issue_id), 256),
      issue_identifier: bounded_optional(Map.get(context, :issue_identifier), 256),
      attempt: normalize_attempt(Map.get(context, :attempt)),
      session_id: bounded_optional(Map.get(context, :session_id), 256),
      workspace: bounded_required(Map.fetch!(context, :workspace), 4_096),
      binding_id: bounded_optional(Map.get(context, :binding_id), 256),
      predecessor_event_id: bounded_optional(Map.get(context, :predecessor_event_id), 64),
      occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    evidence =
      evidence
      |> maybe_put(:writer_id, normalize_writer_id(Map.get(context, :writer_id)))
      |> maybe_put(:public_attempt, normalize_attempt(Map.get(context, :public_attempt)))
      |> maybe_put(:provider_code, normalize_provider_code(Map.get(details, :provider_code)))
      |> maybe_put(:http_status, normalize_http_status(Map.get(details, :http_status)))
      |> maybe_put(:reset_hint, normalize_reset_hint(Map.get(details, :reset_hint)))
      |> maybe_put(:liveness, normalize_liveness(Map.get(details, :liveness)))

    evidence = Map.put(evidence, :event_id, event_id(evidence))
    Map.put(evidence, :integrity_hash, integrity_hash(evidence))
  end

  @spec persist(Path.t(), evidence()) :: {:ok, Path.t()} | {:error, term()}
  def persist(workspace, %{event_id: event_id} = evidence)
      when is_binary(workspace) and is_binary(event_id) do
    active_paths = active_paths(workspace, evidence.issue_id, evidence.workflow_scope)

    with {:ok, payload} <- Jason.encode(json_safe(evidence), pretty: true) do
      with_active_marker_locks(active_paths, fn ->
        persist_lifecycle_transaction(workspace, evidence, payload, active_paths)
      end)
    end
  end

  defp persist_lifecycle_transaction(workspace, evidence, payload, active_paths) do
    pending_paths = pending_paths(workspace, evidence.issue_id, evidence.workflow_scope)

    receipt_paths =
      event_receipt_paths(
        workspace,
        evidence.issue_id,
        evidence.event_id,
        evidence.workflow_scope
      )

    with :ok <- validate_existing_receipts(receipt_paths, payload),
         :ok <- validate_existing_active_paths(active_paths, payload, evidence),
         {:ok, _pending_path} <- persist_pending(pending_paths, payload),
         :ok <- sync_parent_directories(pending_paths),
         {:ok, receipt_path} <- persist_immutable_candidates(receipt_paths, payload),
         :ok <- sync_parent_directories(receipt_paths),
         :ok <- run_terminal_persist_hook(:after_receipts),
         {:ok, _active_path} <- persist_active_candidates_locked(active_paths, payload, evidence),
         :ok <- sync_parent_directories(active_paths),
         :ok <- clear_pending_paths(pending_paths, evidence.event_id),
         :ok <- sync_parent_directories(pending_paths) do
      {:ok, receipt_path}
    end
  end

  @spec recovery_state(Path.t()) ::
          :none
          | {:settled, evidence()}
          | {:ambiguous, evidence()}
          | {:storage_fault, map()}
          | {:error, term()}
  def recovery_state(workspace) when is_binary(workspace) do
    read_recovery_state(workspace, nil)
  end

  @spec recovery_state(Path.t(), String.t()) ::
          :none
          | {:settled, evidence()}
          | {:ambiguous, evidence()}
          | {:storage_fault, map()}
          | {:error, term()}
  def recovery_state(workspace, issue_id) when is_binary(workspace) and is_binary(issue_id) do
    read_recovery_state(workspace, issue_id)
  end

  @spec recovery_state_for_issue(String.t()) ::
          :none
          | {:settled, evidence()}
          | {:ambiguous, evidence()}
          | {:storage_fault, map()}
          | {:error, term()}
  def recovery_state_for_issue(issue_id) when is_binary(issue_id) do
    case read_pending([global_pending_path(issue_id)], nil) do
      :none ->
        case read_storage_fault([global_storage_fault_path(issue_id)], nil) do
          :none -> read_active([global_active_path(issue_id)], nil, nil)
          result -> result
        end

      result ->
        result
    end
  end

  defp read_recovery_state(workspace, issue_id) do
    case read_pending(pending_paths(workspace, issue_id), workspace) do
      :none ->
        read_fault_or_active(workspace, issue_id)

      {:error, {_path, _reason}} = pending_error ->
        case read_storage_fault(storage_fault_paths(workspace, issue_id), nil) do
          :none -> pending_error
          result -> result
        end

      result ->
        result
    end
  end

  defp read_fault_or_active(workspace, issue_id) do
    case read_storage_fault(storage_fault_paths(workspace, issue_id), nil) do
      :none -> read_active(active_paths(workspace, issue_id), workspace, nil)
      result -> result
    end
  end

  @spec clear_active(Path.t(), String.t() | nil) :: :ok | {:error, term()}
  def clear_active(workspace, issue_id \\ nil) when is_binary(workspace) do
    recovery =
      if is_binary(issue_id), do: recovery_state(workspace, issue_id), else: recovery_state(workspace)

    case recovery do
      :none ->
        :ok

      {disposition, evidence} when disposition in [:settled, :ambiguous] ->
        clear_active(workspace, issue_id, evidence.event_id)

      {:storage_fault, %{code: code, event_id: event_id}}
      when code in [:incomplete_terminal_mirror, :incomplete_resume_mirror] ->
        clear_active(workspace, issue_id, event_id)

      {:storage_fault, %{event_id: event_id}} when is_binary(issue_id) ->
        clear_storage_fault(workspace, issue_id, event_id)

      {:error, _reason} = error ->
        error
    end
  end

  @spec clear_active(Path.t(), String.t() | nil, String.t()) :: :ok | {:error, term()}
  def clear_active(workspace, issue_id, expected_event_id)
      when is_binary(workspace) and is_binary(expected_event_id) do
    scope = active_marker_scope(workspace, issue_id, expected_event_id)
    paths = active_paths(workspace, issue_id, scope)

    with_active_marker_locks(paths, fn -> clear_paths(paths, expected_event_id) end)
  end

  @spec persist_storage_fault(Path.t(), evidence(), atom() | String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def persist_storage_fault(workspace, evidence, code)
      when is_binary(workspace) and is_map(evidence) and (is_atom(code) or is_binary(code)) do
    fault = %{
      "event_id" => evidence.event_id,
      "workflow_scope" => evidence.workflow_scope,
      "issue_id" => evidence.issue_id,
      "workspace" => evidence.workspace,
      "code" => bounded_required(to_string(code), 128),
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with {:ok, payload} <- Jason.encode(fault, pretty: true) do
      persist_mirrored(
        storage_fault_paths(workspace, evidence.issue_id, evidence.workflow_scope),
        &atomic_create(&1, payload),
        :storage_fault_marker_unavailable
      )
    end
  end

  @spec clear_storage_fault(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def clear_storage_fault(workspace, issue_id, expected_event_id)
      when is_binary(workspace) and is_binary(issue_id) and is_binary(expected_event_id) do
    clear_fault_paths(storage_fault_paths(workspace, issue_id), expected_event_id)
  end

  @spec settle_lifecycle(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def settle_lifecycle(workspace, issue_id, expected_event_id)
      when is_binary(workspace) and is_binary(issue_id) and is_binary(expected_event_id) do
    scope = active_marker_scope(workspace, issue_id, expected_event_id)
    paths = active_paths(workspace, issue_id, scope)

    with_active_marker_locks(paths, fn ->
      with :ok <- clear_paths(paths, expected_event_id),
           :ok <- clear_pending_paths(pending_paths(workspace, issue_id, scope), expected_event_id) do
        clear_fault_paths(
          storage_fault_paths(workspace, issue_id, scope),
          expected_event_id
        )
      end
    end)
  end

  defp clear_pending_paths(paths, expected_event_id) do
    {local_paths, global_paths} = Enum.split(paths, 2)

    with :ok <- clear_local_pending_paths(local_paths, expected_event_id) do
      clear_paths(global_paths, expected_event_id)
    end
  end

  defp clear_local_pending_paths(paths, expected_event_id) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      clear_local_pending_path(path, expected_event_id)
    end)
  end

  defp clear_local_pending_path(path, expected_event_id) do
    case read_active_event_id(path) do
      {:ok, ^expected_event_id} -> remove_active_marker(path)
      {:ok, _other_event_id} -> {:halt, {:error, {:active_marker_owner_mismatch, path}}}
      {:error, reason} when reason in [:enoent, :enotdir] -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {path, reason}}}
    end
  end

  defp clear_paths(paths, expected_event_id) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case read_active_event_id(path) do
        {:ok, ^expected_event_id} ->
          remove_active_marker(path)

        {:ok, _other_event_id} ->
          {:halt, {:error, {:active_marker_owner_mismatch, path}}}

        {:error, :enoent} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {path, reason}}}
      end
    end)
  end

  defp remove_active_marker(path) do
    case File.rm(path) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {path, reason}}}
    end
  end

  if Mix.env() == :test do
    @doc false
    @spec remove_active_marker_for_test(Path.t()) :: :ok | {:error, term()}
    def remove_active_marker_for_test(path) do
      case remove_active_marker(path) do
        {:cont, :ok} -> :ok
        {:halt, {:error, _reason} = error} -> error
      end
    end

    @doc false
    @spec active_transfer_allowed_for_test(Path.t(), String.t(), evidence()) ::
            :ok | {:error, term()}
    def active_transfer_allowed_for_test(path, payload, evidence),
      do: active_transfer_allowed?(path, payload, evidence)

    @doc false
    @spec persist_active_paths_for_test([Path.t()], String.t()) :: :ok | {:error, term()}
    def persist_active_paths_for_test(paths, payload),
      do: persist_all_existing_active(paths, payload)

    @doc false
    @spec classify_candidate_error_for_test(term()) :: {:error, term()}
    def classify_candidate_error_for_test(reason) do
      persist_candidates(
        [Path.join(System.tmp_dir!(), "terminal-failure-candidate-test")],
        fn _path -> {:error, reason} end,
        :candidate_error
      )
    end
  end

  @spec begin_native_cleanup_fence() :: {:ok, String.t()} | {:error, term()}
  def begin_native_cleanup_fence do
    cleanup_id = random_hex(32)
    path = native_cleanup_fence_path(cleanup_id)
    payload = native_cleanup_fence_payload(cleanup_id)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- atomic_create(path, Jason.encode!(payload)),
         :ok <- File.chmod(path, 0o600),
         :ok <- sync_parent_directories([path]) do
      {:ok, cleanup_id}
    else
      {:error, reason} -> {:error, {:native_cleanup_fence_unavailable, reason}}
    end
  rescue
    _error -> {:error, :native_cleanup_fence_unavailable}
  end

  @spec complete_native_cleanup_fence(String.t()) :: :ok | {:error, term()}
  def complete_native_cleanup_fence(cleanup_id) when is_binary(cleanup_id) do
    if valid_hex_id?(cleanup_id) do
      path = native_cleanup_fence_path(cleanup_id)

      case remove_native_cleanup_fence(path) do
        :ok -> sync_parent_directories([path])
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_native_cleanup_fence_id}
    end
  rescue
    _error -> {:error, :native_cleanup_fence_clear_failed}
  end

  @spec storage_ready() :: :ok | {:error, term()}
  def storage_ready do
    with :ok <-
           probe_storage_namespaces([
             "events",
             "pending",
             "active",
             "resumes",
             "faults",
             "locks",
             "cleanups"
           ]),
         :ok <- sync_parent_directories([Path.join(state_root(), "storage-probe")]),
         :ok <- await_native_cleanup_fences(@native_cleanup_wait_attempts),
         :ok <- verify_no_pending_transactions() do
      with_lock_namespace_mutex(&recover_lock_namespace/0)
    end
  end

  defp verify_no_pending_transactions do
    pending_root = Path.join(state_root(), "pending")

    case lock_override(:pending_ls, fn -> File.ls(pending_root) end) do
      {:ok, entries} -> Enum.reduce_while(entries, :ok, &verify_pending_entry(pending_root, &1, &2))
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:terminal_pending_namespace_unavailable, reason}}
    end
  end

  defp verify_pending_entry(pending_root, entry, :ok) do
    path = Path.join(pending_root, entry)

    result =
      with true <- String.ends_with?(entry, ".json"),
           {:ok, contents} <- File.read(path),
           {:ok, decoded} <- Jason.decode(contents),
           {:ok, evidence} <- decode_evidence(decoded) do
        {:error, {:incomplete_terminal_transaction, evidence.event_id}}
      else
        _other -> {:error, :invalid_terminal_pending_entry}
      end

    {:halt, result}
  end

  defp probe_storage_namespaces(namespaces) do
    Enum.reduce_while(namespaces, :ok, fn namespace, :ok ->
      case probe_storage_namespace(namespace) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp probe_storage_namespace(namespace) do
    probe_path =
      Path.join([
        state_root(),
        namespace,
        ".write-probe-#{System.unique_integer([:positive, :monotonic])}"
      ])

    with :ok <- File.mkdir_p(Path.dirname(probe_path)),
         :ok <- File.write(probe_path, "ready", [:exclusive, :sync]),
         :ok <- File.rm(probe_path) do
      :ok
    else
      {:error, reason} ->
        File.rm(probe_path)
        {:error, {:terminal_state_namespace_unavailable, namespace, reason}}
    end
  end

  @spec record_resume(Path.t(), evidence(), String.t(), non_neg_integer()) ::
          {:ok, Path.t()} | {:error, term()}
  def record_resume(workspace, %{event_id: event_id} = evidence, binding_id, attempt)
      when is_binary(workspace) and is_binary(event_id) and is_binary(binding_id) and
             is_integer(attempt) and attempt >= 0 do
    receipt = %{
      "terminal_event_id" => event_id,
      "workflow_scope" => evidence.workflow_scope,
      "issue_id" => evidence.issue_id,
      "workspace" => evidence.workspace,
      "binding_id" => bounded_required(binding_id, 256),
      "attempt" => attempt,
      "resumed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with {:ok, payload} <- Jason.encode(receipt, pretty: true) do
      persist_immutable_candidates(
        resume_receipt_paths(
          workspace,
          evidence.issue_id,
          event_id,
          evidence.workflow_scope
        ),
        payload
      )
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(
        %{
          event_id: event_id,
          integrity_hash: integrity_hash,
          reason: reason,
          category: category,
          backend: backend,
          workspace: workspace,
          occurred_at: occurred_at
        } = evidence
      ) do
    valid_event_id?(event_id, evidence) and valid_integrity_hash?(integrity_hash, evidence) and
      valid_hash?(Map.get(evidence, :workflow_scope)) and valid_optional_hashes?(evidence) and
      valid_reason?(reason, category) and
      valid_backend?(backend) and
      is_binary(workspace) and workspace != "" and is_binary(occurred_at)
  end

  def valid?(_evidence), do: false

  defp valid_hash?(value), do: is_binary(value) and byte_size(value) == 64

  defp valid_event_id?(value, evidence) do
    valid_hash?(value) and value == event_id(evidence)
  end

  defp valid_integrity_hash?(value, evidence) do
    valid_hash?(value) and value == integrity_hash(evidence)
  end

  defp valid_optional_hashes?(evidence) do
    hashes_valid? =
      Enum.all?([:predecessor_event_id, :writer_id], fn key ->
        value = Map.get(evidence, key)
        is_nil(value) or valid_hash?(value)
      end)

    public_attempt = Map.get(evidence, :public_attempt)
    hashes_valid? and (is_nil(public_attempt) or valid_raw_attempt?(public_attempt))
  end

  defp valid_reason?(reason, category), do: reason in @reasons and category == category(reason)
  defp valid_backend?(backend), do: is_atom(backend) and not is_nil(backend)

  defp read_pending([], _workspace), do: :none

  defp read_pending([path | rest], workspace) do
    case File.read(path) do
      {:ok, contents} -> decode_pending(contents)
      {:error, :enoent} -> read_pending(rest, workspace)
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  defp decode_pending(contents) do
    with {:ok, decoded} <- Jason.decode(contents),
         {:ok, evidence} <- decode_evidence(decoded) do
      {:storage_fault, storage_fault(evidence, :incomplete_terminal_transaction)}
    else
      {:error, _reason} -> {:error, :invalid_terminal_pending_marker}
    end
  end

  defp read_storage_fault([], nil), do: :none
  defp read_storage_fault([], error), do: {:error, error}

  defp read_storage_fault([path | rest], prior_error) do
    case File.read(path) do
      {:ok, contents} -> decode_storage_fault(contents)
      {:error, :enoent} -> read_storage_fault(rest, prior_error)
      {:error, reason} -> read_storage_fault(rest, prior_error || {path, reason})
    end
  end

  defp decode_storage_fault(contents) do
    with {:ok, decoded} <- Jason.decode(contents),
         event_id when is_binary(event_id) <- Map.get(decoded, "event_id"),
         64 <- byte_size(event_id),
         workflow_scope when is_binary(workflow_scope) <- Map.get(decoded, "workflow_scope"),
         64 <- byte_size(workflow_scope),
         issue_id when is_binary(issue_id) <- Map.get(decoded, "issue_id"),
         workspace when is_binary(workspace) <- Map.get(decoded, "workspace"),
         code when is_binary(code) <- Map.get(decoded, "code") do
      {:storage_fault,
       %{
         event_id: event_id,
         workflow_scope: workflow_scope,
         issue_id: issue_id,
         workspace: workspace,
         code: code
       }}
    else
      _other -> {:error, :invalid_terminal_storage_fault}
    end
  end

  defp read_active([], _workspace, nil), do: :none
  defp read_active([], _workspace, error), do: {:error, error}

  defp read_active([path | rest], workspace, prior_error) do
    case File.read(path) do
      {:ok, contents} -> decode_recovery_state(workspace, contents)
      {:error, :enoent} -> read_active(rest, workspace, prior_error)
      {:error, reason} -> read_active(rest, workspace, prior_error || {path, reason})
    end
  end

  defp clear_fault_paths(paths, expected_event_id) do
    Enum.reduce_while(paths, :ok, fn path, :ok -> clear_fault_path(path, expected_event_id) end)
  end

  defp clear_fault_path(path, expected_event_id) do
    case File.read(path) do
      {:ok, contents} -> clear_decoded_fault_path(path, expected_event_id, contents)
      {:error, :enoent} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {path, reason}}}
    end
  end

  defp clear_decoded_fault_path(path, expected_event_id, contents) do
    case decode_storage_fault(contents) do
      {:storage_fault, %{event_id: ^expected_event_id}} -> remove_fault_marker(path)
      {:storage_fault, _other} -> {:halt, {:error, {:storage_fault_owner_mismatch, path}}}
      {:error, reason} -> {:halt, {:error, {path, reason}}}
    end
  end

  defp remove_fault_marker(path) do
    case File.rm(path) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {path, reason}}}
    end
  end

  defp read_active_event_id(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, evidence} <- decode_evidence(decoded) do
      {:ok, evidence.event_id}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_recovery_state(_workspace, contents) do
    with {:ok, decoded} <- Jason.decode(contents),
         {:ok, evidence} <- decode_evidence(decoded) do
      workspace = evidence.workspace

      if terminal_mirror_complete?(workspace, evidence) do
        recovery_disposition(workspace, evidence)
      else
        {:storage_fault, storage_fault(evidence, :incomplete_terminal_mirror)}
      end
    end
  end

  defp terminal_mirror_complete?(workspace, evidence) do
    event_paths =
      event_receipt_paths(
        workspace,
        evidence.issue_id,
        evidence.event_id,
        evidence.workflow_scope
      )

    active_marker_paths = active_paths(workspace, evidence.issue_id, evidence.workflow_scope)

    mirrored_evidence_complete?(event_paths, evidence.event_id) and
      mirrored_evidence_complete?(active_marker_paths, evidence.event_id)
  end

  defp mirrored_evidence_complete?(paths, event_id) do
    {local_paths, global_paths} = Enum.split(paths, 2)
    existing_local_paths = Enum.filter(local_paths, &File.regular?/1)

    existing_local_paths != [] and
      Enum.all?(existing_local_paths, &evidence_path_matches?(&1, event_id)) and
      Enum.all?(global_paths, &evidence_path_matches?(&1, event_id))
  end

  defp evidence_path_matches?(path, event_id) do
    case read_active_event_id(path) do
      {:ok, ^event_id} -> true
      _other -> false
    end
  end

  defp storage_fault(evidence, code) do
    %{
      event_id: evidence.event_id,
      workflow_scope: evidence.workflow_scope,
      issue_id: evidence.issue_id,
      workspace: evidence.workspace,
      code: code
    }
  end

  defp recovery_disposition(workspace, evidence) do
    resume_paths =
      resume_receipt_paths(
        workspace,
        evidence.issue_id,
        evidence.event_id,
        evidence.workflow_scope
      )

    if Enum.any?(resume_paths, &File.exists?/1) do
      if resume_mirror_complete?(resume_paths, evidence),
        do: {:ambiguous, evidence},
        else: {:storage_fault, storage_fault(evidence, :incomplete_resume_mirror)}
    else
      {:settled, evidence}
    end
  end

  defp resume_mirror_complete?(paths, evidence) do
    {local_paths, global_paths} = Enum.split(paths, 2)
    existing_local_paths = Enum.filter(local_paths, &File.regular?/1)

    existing_local_paths != [] and
      Enum.all?(existing_local_paths, &resume_receipt_matches_prior?(&1, evidence)) and
      Enum.all?(global_paths, &resume_receipt_matches_prior?(&1, evidence))
  end

  defp strict_evidence_payload?(decoded) do
    keys = Map.keys(decoded) |> MapSet.new()
    allowed_keys = MapSet.union(@required_evidence_keys, @optional_evidence_keys)

    MapSet.subset?(@required_evidence_keys, keys) and MapSet.subset?(keys, allowed_keys) and
      strict_required_evidence_fields?(decoded) and strict_optional_evidence_fields?(decoded)
  end

  defp strict_required_evidence_fields?(decoded) do
    strict_evidence_identity_fields?(decoded) and strict_evidence_correlation_fields?(decoded)
  end

  defp strict_evidence_identity_fields?(decoded) do
    Enum.all?(["event_id", "integrity_hash", "workflow_scope"], &valid_hash?(Map.get(decoded, &1))) and
      not is_nil(decode_reason(Map.get(decoded, "reason"))) and
      is_binary(Map.get(decoded, "category")) and
      not is_nil(decode_backend(Map.get(decoded, "backend"))) and
      is_binary(Map.get(decoded, "occurred_at"))
  end

  defp strict_evidence_correlation_fields?(decoded) do
    exact_nullable_bounded?(Map.get(decoded, "issue_id"), 256) and
      exact_nullable_bounded?(Map.get(decoded, "issue_identifier"), 256) and
      valid_raw_attempt?(Map.get(decoded, "attempt")) and
      exact_nullable_bounded?(Map.get(decoded, "session_id"), 256) and
      exact_required_bounded?(Map.get(decoded, "workspace"), 4_096) and
      exact_nullable_bounded?(Map.get(decoded, "binding_id"), 256) and
      valid_raw_optional_hash?(Map.get(decoded, "predecessor_event_id"))
  end

  defp strict_optional_evidence_fields?(decoded) do
    optional_field_valid?(decoded, "writer_id", &valid_hash?/1) and
      optional_field_valid?(decoded, "public_attempt", &valid_present_attempt?/1) and
      optional_field_valid?(decoded, "provider_code", &valid_present_provider_code?/1) and
      optional_field_valid?(decoded, "http_status", &valid_present_http_status?/1) and
      optional_field_valid?(decoded, "reset_hint", &valid_present_reset_hint?/1) and
      optional_field_valid?(decoded, "liveness", &(not is_nil(decode_liveness(&1))))
  end

  defp optional_field_valid?(decoded, key, validator) do
    not Map.has_key?(decoded, key) or validator.(Map.get(decoded, key))
  end

  defp exact_nullable_bounded?(nil, _max_bytes), do: true

  defp exact_nullable_bounded?(value, max_bytes),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= max_bytes

  defp exact_required_bounded?(value, max_bytes),
    do: exact_nullable_bounded?(value, max_bytes) and value not in [nil, ""]

  defp valid_raw_attempt?(nil), do: true
  defp valid_raw_attempt?(value), do: valid_present_attempt?(value)
  defp valid_present_attempt?(value), do: is_integer(value) and value >= 0
  defp valid_present_provider_code?(value), do: not is_nil(value) and normalize_provider_code(value) == value
  defp valid_present_http_status?(value), do: not is_nil(value) and normalize_http_status(value) == value
  defp valid_present_reset_hint?(value), do: not is_nil(value) and normalize_reset_hint(value) == value
  defp valid_raw_optional_hash?(nil), do: true
  defp valid_raw_optional_hash?(value), do: valid_hash?(value)

  defp decode_evidence(decoded) when is_map(decoded) do
    if not strict_evidence_payload?(decoded), do: throw(:invalid_evidence_payload)

    reason = decode_reason(Map.get(decoded, "reason"))
    backend = decode_backend(Map.get(decoded, "backend"))
    liveness = decode_liveness(Map.get(decoded, "liveness"))

    evidence = %{
      event_id: Map.get(decoded, "event_id"),
      integrity_hash: Map.get(decoded, "integrity_hash"),
      workflow_scope: Map.get(decoded, "workflow_scope"),
      reason: reason,
      category: Map.get(decoded, "category"),
      backend: backend,
      issue_id: bounded_optional(Map.get(decoded, "issue_id"), 256),
      issue_identifier: bounded_optional(Map.get(decoded, "issue_identifier"), 256),
      attempt: normalize_attempt(Map.get(decoded, "attempt")),
      session_id: bounded_optional(Map.get(decoded, "session_id"), 256),
      workspace: bounded_required(Map.get(decoded, "workspace"), 4_096),
      binding_id: bounded_optional(Map.get(decoded, "binding_id"), 256),
      predecessor_event_id: bounded_optional(Map.get(decoded, "predecessor_event_id"), 64),
      occurred_at: Map.get(decoded, "occurred_at")
    }

    evidence =
      evidence
      |> maybe_put(:writer_id, normalize_writer_id(Map.get(decoded, "writer_id")))
      |> maybe_put(:public_attempt, normalize_attempt(Map.get(decoded, "public_attempt")))
      |> maybe_put(:provider_code, normalize_provider_code(Map.get(decoded, "provider_code")))
      |> maybe_put(:http_status, normalize_http_status(Map.get(decoded, "http_status")))
      |> maybe_put(:reset_hint, normalize_reset_hint(Map.get(decoded, "reset_hint")))
      |> maybe_put(:liveness, liveness)

    if valid?(evidence) and event_id(evidence) == evidence.event_id,
      do: {:ok, evidence},
      else: {:error, :invalid_terminal_failure_receipt}
  catch
    :invalid_evidence_payload -> {:error, :invalid_terminal_failure_receipt}
  end

  defp decode_evidence(_decoded), do: {:error, :invalid_terminal_failure_receipt}

  defp decode_reason(reason) when is_binary(reason) do
    Enum.find(@reasons, &(Atom.to_string(&1) == reason))
  end

  defp decode_reason(_reason), do: nil

  defp decode_backend("antigravity"), do: :antigravity
  defp decode_backend("codex"), do: :codex
  defp decode_backend("pi"), do: :pi
  defp decode_backend(_backend), do: nil

  defp decode_liveness("alive_but_thinking"), do: :alive_but_thinking
  defp decode_liveness("semantically_stuck"), do: :semantically_stuck
  defp decode_liveness("dead_or_unreachable"), do: :dead_or_unreachable
  defp decode_liveness(_liveness), do: nil

  defp category(:provider_quota_exhausted), do: "quota"
  defp category(:provider_auth_failed), do: "authentication"
  defp category(:provider_network_unreachable), do: "network"
  defp category(:permission_denied), do: "permission"
  defp category(:worker_crashed), do: "process"
  defp category(:worker_stalled), do: "stall"
  defp category(:provider_protocol_error), do: "protocol"
  defp category(:unknown_terminal_failure), do: "unknown"

  defp event_id(evidence) do
    evidence
    |> Map.drop([:occurred_at, :event_id, :integrity_hash])
    |> canonical_hash()
  end

  defp integrity_hash(evidence) do
    evidence
    |> Map.delete(:integrity_hash)
    |> canonical_hash()
  end

  defp canonical_hash(value) do
    value
    |> json_safe()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp active_marker_scope(workspace, _issue_id, expected_event_id) do
    [
      Path.join(workspace, ".symphony/terminal-failure.json"),
      Path.join(fallback_root(workspace), "active/#{workspace_hash(workspace)}.json")
    ]
    |> Enum.find_value(fn path ->
      with {:ok, contents} <- File.read(path),
           {:ok, decoded} <- Jason.decode(contents),
           {:ok, evidence} <- decode_evidence(decoded),
           true <- evidence.event_id == expected_event_id do
        evidence.workflow_scope
      else
        _other -> nil
      end
    end)
    |> case do
      nil -> lifecycle_scope()
      scope -> scope
    end
  end

  defp event_receipt_paths(workspace, issue_id, event_id, scope) do
    scope = scope || lifecycle_scope()

    local_paths = [
      Path.join(workspace, ".symphony/terminal-events/#{event_id}.json"),
      Path.join(fallback_root(workspace), "events/#{workspace_hash(workspace)}-#{event_id}.json")
    ]

    if is_binary(issue_id) and issue_id != "" do
      local_paths ++
        [Path.join(state_root(), "events/#{scoped_identity(issue_id, scope)}-#{event_id}.json")]
    else
      local_paths
    end
  end

  defp pending_paths(workspace, issue_id, scope \\ nil) do
    scope = scope || lifecycle_scope()

    local_paths = [
      Path.join(workspace, ".symphony/terminal-pending.json"),
      Path.join(fallback_root(workspace), "pending/#{workspace_hash(workspace)}.json")
    ]

    if is_binary(issue_id) and issue_id != "" do
      local_paths ++ [global_pending_path(issue_id, scope)]
    else
      local_paths
    end
  end

  defp active_paths(workspace, issue_id, scope \\ nil) do
    scope = scope || lifecycle_scope()

    local_paths = [
      Path.join(workspace, ".symphony/terminal-failure.json"),
      Path.join(fallback_root(workspace), "active/#{workspace_hash(workspace)}.json")
    ]

    if is_binary(issue_id) and issue_id != "" do
      local_paths ++ [global_active_path(issue_id, scope)]
    else
      local_paths
    end
  end

  defp resume_receipt_paths(workspace, issue_id, event_id, scope) do
    scope = scope || lifecycle_scope()

    local_paths = [
      Path.join(workspace, ".symphony/terminal-resumes/#{event_id}.json"),
      Path.join(fallback_root(workspace), "resumes/#{workspace_hash(workspace)}-#{event_id}.json")
    ]

    if is_binary(issue_id) and issue_id != "" do
      local_paths ++
        [Path.join(state_root(), "resumes/#{scoped_identity(issue_id, scope)}-#{event_id}.json")]
    else
      local_paths
    end
  end

  defp storage_fault_paths(workspace, issue_id, scope \\ nil) do
    scope = scope || lifecycle_scope()

    local_paths = [
      Path.join(workspace, ".symphony/terminal-storage-fault.json"),
      Path.join(fallback_root(workspace), "faults/#{workspace_hash(workspace)}.json")
    ]

    if is_binary(issue_id) and issue_id != "" do
      local_paths ++ [global_storage_fault_path(issue_id, scope)]
    else
      local_paths
    end
  end

  defp fallback_root(workspace), do: Path.join(Path.dirname(Path.expand(workspace)), ".symphony/terminal-holds")

  defp state_root do
    Application.get_env(:symphony_elixir, :terminal_state_root) ||
      Application.get_env(
        :symphony_elixir,
        :log_file,
        SymphonyElixir.LogFile.default_log_file()
      )
      |> Path.dirname()
      |> Path.join("terminal-holds")
  end

  defp global_pending_path(issue_id, scope \\ nil),
    do: Path.join(state_root(), "pending/#{scoped_identity(issue_id, scope)}.json")

  defp global_active_path(issue_id, scope \\ nil),
    do: Path.join(state_root(), "active/#{scoped_identity(issue_id, scope)}.json")

  defp global_storage_fault_path(issue_id, scope \\ nil),
    do: Path.join(state_root(), "faults/#{scoped_identity(issue_id, scope)}.json")

  defp scoped_identity(issue_id, scope),
    do: "#{scope || lifecycle_scope()}-#{identity_hash(issue_id)}"

  defp lifecycle_scope do
    Application.get_env(:symphony_elixir, :terminal_lifecycle_scope) ||
      SymphonyElixir.Workflow.workflow_file_path()
      |> Path.expand()
      |> identity_hash()
  end

  defp identity_hash(identity) do
    identity
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp workspace_hash(workspace) do
    workspace
    |> Path.expand()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp random_hex(byte_count) do
    byte_count
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp valid_hex_id?(value), do: valid_hash?(value)

  defp native_cleanup_fence_path(cleanup_id) do
    Path.join([state_root(), "cleanups", "#{cleanup_id}.json"])
  end

  defp native_cleanup_fence_payload(cleanup_id) do
    payload = %{
      "version" => 1,
      "cleanup_id" => cleanup_id,
      "workflow_scope" => lifecycle_scope(),
      "runtime_instance" => runtime_instance(),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Map.put(payload, "integrity_hash", native_cleanup_fence_integrity(payload))
  end

  defp native_cleanup_fence_integrity(payload) do
    [
      Integer.to_string(payload["version"]),
      payload["cleanup_id"],
      payload["workflow_scope"],
      payload["runtime_instance"],
      payload["created_at"]
    ]
    |> Enum.join("\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp await_native_cleanup_fences(attempts_remaining) do
    case native_cleanup_fences() do
      {:ok, []} ->
        :ok

      {:ok, _fences} when attempts_remaining > 0 ->
        run_native_cleanup_wait_hook()
        Process.sleep(@native_cleanup_wait_delay_ms)
        await_native_cleanup_fences(attempts_remaining - 1)

      {:ok, fences} ->
        {:error, {:native_cleanup_incomplete, length(fences)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp native_cleanup_fences do
    directory = Path.join(state_root(), "cleanups")

    case cleanup_directory_ls(directory) do
      {:ok, entries} -> validate_native_cleanup_fences(entries, directory)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:native_cleanup_namespace_unavailable, reason}}
    end
  end

  defp validate_native_cleanup_fences(entries, directory) do
    entries
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, fences} ->
      reduce_native_cleanup_fence(entry, directory, fences)
    end)
  end

  defp reduce_native_cleanup_fence(entry, directory, fences) do
    path = Path.join(directory, entry)

    case validate_native_cleanup_fence(path, entry) do
      :ok -> {:cont, {:ok, [path | fences]}}
      {:error, :enoent} -> {:cont, {:ok, fences}}
      {:error, reason} -> {:halt, {:error, {:invalid_native_cleanup_fence, entry, reason}}}
    end
  end

  defp validate_native_cleanup_fence(path, entry) do
    expected_id = String.trim_trailing(entry, ".json")

    with true <- String.ends_with?(entry, ".json"),
         true <- valid_hex_id?(expected_id),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= 2_048 <- cleanup_fence_lstat(path),
         {:ok, contents} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(contents),
         true <- Map.keys(decoded) |> MapSet.new() |> MapSet.equal?(@native_cleanup_fence_keys),
         true <- decoded["version"] == 1,
         true <- decoded["cleanup_id"] == expected_id,
         true <- valid_hash?(decoded["workflow_scope"]),
         true <- valid_hash?(decoded["runtime_instance"]),
         true <- is_binary(decoded["created_at"]) and byte_size(decoded["created_at"]) <= 64,
         {:ok, _datetime, 0} <- DateTime.from_iso8601(decoded["created_at"]),
         true <- valid_hash?(decoded["integrity_hash"]),
         true <- decoded["integrity_hash"] == native_cleanup_fence_integrity(decoded) do
      :ok
    else
      {:error, :enoent} -> {:error, :enoent}
      _invalid -> {:error, :invalid_payload}
    end
  end

  defp remove_native_cleanup_fence(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:native_cleanup_fence_clear_failed, reason}}
    end
  end

  defp sync_parent_directories(paths) do
    if :os.type() == {:unix, :linux}, do: sync_linux_parent_directories(paths), else: :ok
  rescue
    _error -> {:error, :terminal_directory_sync_failed}
  end

  defp sync_linux_parent_directories(paths) do
    paths
    |> Enum.map(&Path.dirname/1)
    |> Enum.filter(&File.dir?/1)
    |> Enum.uniq()
    |> directories_by_device()
    |> Enum.reduce_while(:ok, &sync_linux_directory/2)
  end

  defp sync_linux_directory(directory, :ok) do
    case run_directory_sync(directory) do
      {_output, 0} -> {:cont, :ok}
      {_output, _status} -> {:halt, {:error, :terminal_directory_sync_failed}}
    end
  end

  defp directories_by_device(directories) do
    directories
    |> Enum.reduce(%{}, fn directory, devices ->
      stat = File.stat!(directory)
      Map.put_new(devices, {stat.major_device, stat.minor_device}, directory)
    end)
    |> Map.values()
  end

  defp persist_pending(paths, payload) do
    {local_paths, global_paths} = Enum.split(paths, 2)
    writer = &atomic_create(&1, payload)

    case persist_required(global_paths, writer, :pending_marker_unavailable) do
      :ok -> persist_candidates(local_paths, writer, :pending_marker_unavailable)
      {:error, _reason} = error -> error
    end
  end

  defp validate_existing_receipts(paths, payload) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      validate_existing_receipt(path, payload)
    end)
  end

  defp validate_existing_receipt(path, payload) do
    if File.regular?(path) do
      case existing_receipt_result(path, payload) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    else
      {:cont, :ok}
    end
  end

  defp persist_immutable_candidates(paths, payload),
    do: persist_mirrored(paths, &atomic_create(&1, payload), :immutable_receipt_unavailable)

  defp persist_active_candidates_locked(paths, payload, evidence) do
    with :ok <- validate_existing_active_paths(paths, payload, evidence),
         {:ok, selected_path} <- persist_local_active_paths(paths, payload, evidence),
         :ok <- persist_global_active_paths(paths, payload, evidence) do
      {:ok, selected_path}
    end
  end

  defp validate_existing_active_paths(paths, payload, evidence) do
    existing = Enum.filter(paths, &File.regular?/1)

    if is_binary(Map.get(evidence, :predecessor_event_id)) and existing == [] do
      {:error, :active_marker_owner_mismatch}
    else
      Enum.reduce_while(existing, :ok, fn path, :ok ->
        active_transfer_reducer(path, payload, evidence)
      end)
    end
  end

  defp active_transfer_reducer(path, payload, evidence) do
    case active_transfer_allowed?(path, payload, evidence) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp active_transfer_allowed?(path, payload, evidence) do
    case File.read(path) do
      {:ok, ^payload} -> :ok
      {:ok, contents} -> validate_active_successor(contents, evidence)
      {:error, reason} -> {:error, {:active_marker_invalid, reason}}
    end
  end

  defp validate_active_successor(contents, evidence) do
    with {:ok, decoded} <- Jason.decode(contents),
         {:ok, prior} <- decode_evidence(decoded),
         true <- same_active_owner?(prior, evidence),
         true <- evidence.predecessor_event_id == prior.event_id,
         true <- resumed_event?(prior, evidence) do
      :ok
    else
      false -> {:error, :active_marker_owner_mismatch}
      {:error, reason} -> {:error, {:active_marker_invalid, reason}}
    end
  end

  defp persist_local_active_paths(paths, payload, evidence) do
    {local_paths, _global_paths} = Enum.split(paths, 2)
    existing = Enum.filter(local_paths, &File.regular?/1)

    case existing do
      [] -> persist_candidates(local_paths, &claim_active_marker(&1, payload, evidence), :active_marker_unavailable)
      existing_paths -> persist_all_existing_active(existing_paths, payload)
    end
  end

  defp persist_all_existing_active(paths, payload) do
    Enum.reduce_while(paths, {:ok, List.first(paths)}, fn path, result ->
      case replace_active_marker(path, payload) do
        :ok -> {:cont, result}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp persist_global_active_paths(paths, payload, evidence) do
    {_local_paths, global_paths} = Enum.split(paths, 2)
    persist_required(global_paths, &claim_active_marker(&1, payload, evidence), :active_marker_unavailable)
  end

  defp claim_active_marker(path, payload, evidence) do
    case atomic_create(path, payload) do
      :ok -> :ok
      {:error, :receipt_conflict} -> replace_claimed_active_marker(path, payload, evidence)
      {:error, _reason} = error -> error
    end
  end

  defp replace_claimed_active_marker(path, payload, evidence) do
    with {:ok, contents} <- File.read(path),
         :ok <- validate_active_successor(contents, evidence) do
      replace_active_marker(path, payload)
    end
  end

  defp replace_active_marker(path, payload) do
    case File.read(path) do
      {:ok, ^payload} -> :ok
      {:ok, _contents} -> wrap_active_replace(atomic_replace(path, payload))
      {:error, reason} -> {:error, {:active_marker_replace_failed, reason}}
    end
  end

  defp wrap_active_replace(:ok), do: :ok
  defp wrap_active_replace({:error, reason}), do: {:error, {:active_marker_replace_failed, reason}}

  defp same_active_owner?(prior, evidence) do
    prior.workflow_scope == evidence.workflow_scope and prior.issue_id == evidence.issue_id and
      Path.expand(prior.workspace) == Path.expand(evidence.workspace)
  end

  defp resumed_event?(prior, successor) do
    prior
    |> resume_receipt_paths_for_evidence()
    |> Enum.any?(&resume_receipt_authorizes?(&1, prior, successor))
  end

  defp resume_receipt_paths_for_evidence(evidence) do
    resume_receipt_paths(
      evidence.workspace,
      evidence.issue_id,
      evidence.event_id,
      evidence.workflow_scope
    )
  end

  defp resume_receipt_authorizes?(path, prior, successor) do
    case read_resume_receipt(path) do
      {:ok, receipt} ->
        receipt.terminal_event_id == prior.event_id and
          receipt.workflow_scope == prior.workflow_scope and
          receipt.issue_id == prior.issue_id and
          Path.expand(receipt.workspace) == Path.expand(prior.workspace) and
          receipt.binding_id == successor.binding_id and receipt.attempt == successor.attempt

      {:error, _reason} ->
        false
    end
  end

  defp resume_receipt_matches_prior?(path, evidence) do
    case read_resume_receipt(path) do
      {:ok, receipt} ->
        receipt.terminal_event_id == evidence.event_id and
          receipt.workflow_scope == evidence.workflow_scope and
          receipt.issue_id == evidence.issue_id and
          Path.expand(receipt.workspace) == Path.expand(evidence.workspace)

      {:error, _reason} ->
        false
    end
  end

  defp read_resume_receipt(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         terminal_event_id when is_binary(terminal_event_id) <- Map.get(decoded, "terminal_event_id"),
         workflow_scope when is_binary(workflow_scope) <- Map.get(decoded, "workflow_scope"),
         issue_id when is_binary(issue_id) <- Map.get(decoded, "issue_id"),
         workspace when is_binary(workspace) <- Map.get(decoded, "workspace"),
         binding_id when is_binary(binding_id) <- Map.get(decoded, "binding_id"),
         attempt when is_integer(attempt) and attempt >= 0 <- Map.get(decoded, "attempt") do
      {:ok,
       %{
         terminal_event_id: terminal_event_id,
         workflow_scope: workflow_scope,
         issue_id: issue_id,
         workspace: workspace,
         binding_id: binding_id,
         attempt: attempt
       }}
    else
      _other -> {:error, :invalid_resume_receipt}
    end
  end

  if Mix.env() == :test do
    @doc false
    @spec active_lock_path_for_test(Path.t(), String.t()) :: Path.t()
    def active_lock_path_for_test(workspace, issue_id) do
      workspace
      |> active_paths(issue_id)
      |> ownership_lock_path()
    end

    @doc false
    @spec hold_active_lock_for_test(Path.t(), String.t(), pid()) :: :ok | {:error, term()}
    def hold_active_lock_for_test(workspace, issue_id, parent) do
      with_active_marker_locks(active_paths(workspace, issue_id), fn ->
        send(parent, {:active_lock_acquired, self()})

        receive do
          :release_active_lock -> :ok
        end
      end)
    end

    @doc false
    @spec with_lock_overrides_for_test(map(), (-> result)) :: result when result: term()
    def with_lock_overrides_for_test(overrides, operation)
        when is_map(overrides) and is_function(operation, 0) do
      validate_lock_overrides!(overrides)
      previous = Process.get(@lock_test_overrides_key)
      Process.put(@lock_test_overrides_key, Map.merge(previous || %{}, overrides))

      try do
        operation.()
      after
        if is_nil(previous),
          do: Process.delete(@lock_test_overrides_key),
          else: Process.put(@lock_test_overrides_key, previous)
      end
    end

    defp validate_lock_overrides!(overrides) do
      keys = Map.keys(overrides) |> MapSet.new()

      unless Enum.all?(overrides, &valid_lock_override?/1) and
               MapSet.subset?(keys, @lock_test_override_keys) do
        raise ArgumentError, "invalid terminal lock test override"
      end
    end

    defp valid_lock_override?({key, operation})
         when key in [
                :process_read,
                :owner_read,
                :lock_lstat,
                :public_remove,
                :transient_remove,
                :directory_sync,
                :cleanup_lstat
              ],
         do: is_function(operation, 1)

    defp valid_lock_override?({:reclaim_link, operation}), do: is_function(operation, 2)
    defp valid_lock_override?({:namespace_transaction, operation}), do: is_function(operation, 1)
    defp valid_lock_override?({:native_cleanup_wait, operation}), do: is_function(operation, 0)

    defp valid_lock_override?({key, result})
         when key in [
                :machine_read,
                :boot_read,
                :pid_namespace_read,
                :file_ls,
                :pending_ls,
                :cleanup_ls
              ],
         do: match?({:ok, _value}, result) or match?({:error, _reason}, result)

    defp valid_lock_override?(_entry), do: false

    @doc false
    @spec with_terminal_persist_hook_for_test((atom() -> term()), (-> result)) :: result when result: term()
    def with_terminal_persist_hook_for_test(hook, operation)
        when is_function(hook, 1) and is_function(operation, 0) do
      Process.put(@terminal_persist_hook_key, hook)

      try do
        operation.()
      after
        Process.delete(@terminal_persist_hook_key)
      end
    end
  end

  if Mix.env() == :test do
    defp lock_override(key, fallback) do
      case Process.get(@lock_test_overrides_key, %{}) do
        %{^key => value} -> value
        _overrides -> fallback.()
      end
    end

    defp lock_process_read(pid) do
      case Process.get(@lock_test_overrides_key, %{}) do
        %{process_read: reader} when is_function(reader, 1) -> reader.(pid)
        _overrides -> File.read("/proc/#{pid}/stat")
      end
    end

    defp read_lock_file(path) do
      case Process.get(@lock_test_overrides_key, %{}) do
        %{owner_read: reader} when is_function(reader, 1) -> reader.(path)
        _overrides -> File.read(path)
      end
    end

    defp lock_lstat(path) do
      case Process.get(@lock_test_overrides_key, %{}) do
        %{lock_lstat: operation} when is_function(operation, 1) -> operation.(path)
        _overrides -> File.lstat(path)
      end
    end

    defp remove_transient_lock(path) do
      case Process.get(@lock_test_overrides_key, %{}) do
        %{transient_remove: operation} when is_function(operation, 1) -> operation.(path)
        _overrides -> File.rm(path)
      end
    end

    defp create_reclaim_link(source, destination) do
      case Process.get(@lock_test_overrides_key, %{}) do
        %{reclaim_link: operation} when is_function(operation, 2) ->
          operation.(source, destination)

        _overrides ->
          File.ln(source, destination)
      end
    end

    defp remove_public_lock(path) do
      case Process.get(@lock_test_overrides_key, %{}) do
        %{public_remove: operation} when is_function(operation, 1) -> operation.(path)
        _overrides -> File.rm(path)
      end
    end

    defp cleanup_directory_ls(directory) do
      case Process.get(@lock_test_overrides_key, %{}) do
        %{cleanup_ls: result} -> result
        _overrides -> File.ls(directory)
      end
    end

    defp cleanup_fence_lstat(path) do
      case Process.get(@lock_test_overrides_key, %{}) do
        %{cleanup_lstat: operation} when is_function(operation, 1) -> operation.(path)
        _overrides -> File.lstat(path)
      end
    end

    defp run_native_cleanup_wait_hook do
      case Process.get(@lock_test_overrides_key, %{}) do
        %{native_cleanup_wait: operation} when is_function(operation, 0) -> operation.()
        _overrides -> :ok
      end
    end

    defp run_lock_namespace_transaction(operation) do
      case Process.get(@lock_test_overrides_key, %{}) do
        %{namespace_transaction: transaction} when is_function(transaction, 1) ->
          transaction.(operation)

        _overrides ->
          :global.trans({@lock_namespace_mutex, self()}, operation, [node()])
      end
    end

    defp run_directory_sync(directory) do
      case Process.get(@lock_test_overrides_key, %{}) do
        %{directory_sync: operation} when is_function(operation, 1) -> operation.(directory)
        _overrides -> System.cmd(@sync_path, ["-f", directory], stderr_to_stdout: true)
      end
    end

    defp run_terminal_persist_hook(phase) do
      case Process.get(@terminal_persist_hook_key) do
        hook when is_function(hook, 1) -> hook.(phase)
        _other -> :ok
      end
    end
  else
    defp lock_override(_key, fallback), do: fallback.()
    defp lock_process_read(pid), do: File.read("/proc/#{pid}/stat")
    defp read_lock_file(path), do: File.read(path)
    defp lock_lstat(path), do: File.lstat(path)
    defp remove_transient_lock(path), do: File.rm(path)
    defp create_reclaim_link(source, destination), do: File.ln(source, destination)
    defp remove_public_lock(path), do: File.rm(path)
    defp cleanup_directory_ls(directory), do: File.ls(directory)
    defp cleanup_fence_lstat(path), do: File.lstat(path)
    defp run_native_cleanup_wait_hook, do: :ok

    defp run_lock_namespace_transaction(operation),
      do: :global.trans({@lock_namespace_mutex, self()}, operation, [node()])

    defp run_directory_sync(directory),
      do: System.cmd(@sync_path, ["-f", directory], stderr_to_stdout: true)

    defp run_terminal_persist_hook(_phase), do: :ok
  end

  defp with_active_marker_locks(paths, operation) do
    lock_paths = [ownership_lock_path(paths)]
    acquisition = with_lock_namespace_mutex(fn -> acquire_marker_locks(lock_paths, []) end)

    case acquisition do
      {:ok, acquired} ->
        try do
          operation.()
        after
          release_marker_locks(acquired)
        end

      {:error, reason, acquired} ->
        release_marker_locks(acquired)
        {:error, reason}

      {:error, _reason} = error ->
        error
    end
  end

  defp with_lock_namespace_mutex(operation) do
    case run_lock_namespace_transaction(operation) do
      {:aborted, reason} -> {:error, {:terminal_lock_namespace_serialization_failed, reason}}
      result -> result
    end
  end

  defp ownership_lock_path(paths) do
    ownership_key = paths |> Enum.map(&Path.expand/1) |> Enum.sort() |> Enum.join("\u0000") |> identity_hash()
    Path.join(state_root(), "locks/#{ownership_key}.lock")
  end

  defp acquire_marker_locks(paths, acquired),
    do: acquire_marker_locks(paths, acquired, @lock_retry_attempts)

  defp acquire_marker_locks([], acquired, _attempts_left), do: {:ok, acquired}

  defp acquire_marker_locks([lock_path | rest] = paths, acquired, attempts_left) do
    token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    case create_owned_lock(lock_path, token) do
      :ok ->
        acquire_marker_locks(rest, [{lock_path, token} | acquired], @lock_retry_attempts)

      {:error, :eexist} when attempts_left > 0 ->
        Process.sleep(@lock_retry_delay_ms)
        acquire_marker_locks(paths, acquired, attempts_left - 1)

      {:error, :eexist} ->
        case reclaim_stale_lock(lock_path) do
          :reclaimed -> acquire_marker_locks(paths, acquired, @lock_retry_attempts)
          :locked -> {:error, {:active_marker_locked, lock_path, :eexist}, acquired}
          {:error, reason} -> {:error, {:active_marker_locked, lock_path, reason}, acquired}
        end

      {:error, reason} ->
        {:error, {:active_marker_locked, lock_path, reason}, acquired}
    end
  end

  defp create_owned_lock(lock_path, token) do
    candidate_path = "#{lock_path}.candidate-#{token}"

    with :ok <- lock_namespace_ready(lock_path),
         {:ok, payload} <- Jason.encode(lock_owner(token)),
         :ok <- File.write(candidate_path, payload, [:exclusive, :sync]),
         :ok <- File.ln(candidate_path, lock_path) do
      File.rm(candidate_path)
      :ok
    else
      {:error, reason} = error ->
        File.rm(candidate_path)
        if reason == :enotdir, do: {:error, {:lock_namespace_unavailable, reason}}, else: error
    end
  end

  defp lock_namespace_ready(lock_path) do
    case File.mkdir_p(Path.dirname(lock_path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:lock_namespace_unavailable, reason}}
    end
  end

  defp release_marker_locks(locks), do: Enum.each(locks, &release_owned_lock/1)

  defp release_owned_lock({lock_path, token}) do
    case read_lock_owner(lock_path) do
      {:ok, %{"token" => ^token}} -> remove_public_lock(lock_path)
      _other -> :ok
    end
  end

  defp lock_owner(token) do
    %{
      "token" => token,
      "runtime_instance" => runtime_instance(),
      "erlang_pid" => self() |> :erlang.term_to_binary() |> Base.encode64()
    }
    |> Map.merge(lock_process_identity())
  end

  defp lock_process_identity do
    with {:ok, os_pid} <- parse_positive_integer(System.pid()),
         {:ok, machine_scope} <- machine_scope(),
         {:ok, boot_scope} <- boot_scope(),
         {:ok, pid_namespace_scope} <- pid_namespace_scope(),
         {:ok, os_start_time} <- process_start_time(os_pid) do
      %{
        "probe_status" => "verified",
        "machine_scope" => machine_scope,
        "boot_scope" => boot_scope,
        "pid_namespace_scope" => pid_namespace_scope,
        "os_pid" => os_pid,
        "os_start_time" => os_start_time
      }
    else
      _unavailable ->
        %{
          "probe_status" => "unavailable",
          "machine_scope" => nil,
          "boot_scope" => nil,
          "pid_namespace_scope" => nil,
          "os_pid" => nil,
          "os_start_time" => nil
        }
    end
  end

  defp read_lock_owner(lock_path) do
    with {:ok, contents} <- read_lock_file(lock_path),
         {:ok, owner} <- Jason.decode(contents),
         true <- valid_lock_owner?(owner) do
      {:ok, owner}
    else
      {:error, :enoent} -> {:error, :owner_missing}
      _other -> {:error, :invalid_lock_owner}
    end
  end

  defp valid_lock_owner?(owner) when is_map(owner) do
    Enum.sort(Map.keys(owner)) ==
      [
        "boot_scope",
        "erlang_pid",
        "machine_scope",
        "os_pid",
        "os_start_time",
        "pid_namespace_scope",
        "probe_status",
        "runtime_instance",
        "token"
      ] and
      valid_hash?(Map.get(owner, "token")) and
      valid_hash?(Map.get(owner, "runtime_instance")) and
      is_binary(Map.get(owner, "erlang_pid")) and valid_lock_probe?(owner)
  end

  defp valid_lock_owner?(_owner), do: false

  defp valid_lock_probe?(%{"probe_status" => "verified"} = owner) do
    Enum.all?(
      ["machine_scope", "boot_scope", "pid_namespace_scope"],
      &valid_hash?(Map.get(owner, &1))
    ) and positive_integer?(owner["os_pid"]) and positive_integer?(owner["os_start_time"])
  end

  defp valid_lock_probe?(%{"probe_status" => "unavailable"} = owner) do
    Enum.all?(
      ["machine_scope", "boot_scope", "pid_namespace_scope", "os_pid", "os_start_time"],
      &is_nil(Map.get(owner, &1))
    )
  end

  defp valid_lock_probe?(_owner), do: false

  defp reclaim_stale_lock(lock_path) do
    case read_lock_owner(lock_path) do
      {:ok, owner} ->
        if stale_lock_owner?(owner),
          do: remove_stale_owned_lock(lock_path, owner),
          else: :locked

      {:error, :owner_missing} ->
        :reclaimed

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stale_lock_owner?(owner) do
    if owner["runtime_instance"] == runtime_instance(),
      do: same_runtime_owner_stale?(owner),
      else: prior_runtime_owner_stale?(owner)
  end

  defp same_runtime_owner_stale?(owner) do
    case decode_owner_pid(owner["erlang_pid"]) do
      {:ok, pid} -> not Process.alive?(pid)
      :error -> false
    end
  end

  defp prior_runtime_owner_stale?(%{"probe_status" => "verified"} = owner) do
    with {:ok, current_machine} <- machine_scope(),
         true <- current_machine == owner["machine_scope"],
         {:ok, current_boot} <- boot_scope() do
      if current_boot != owner["boot_scope"],
        do: true,
        else: same_boot_owner_stale?(owner)
    else
      _unavailable_or_remote -> false
    end
  end

  defp prior_runtime_owner_stale?(_owner), do: false

  defp same_boot_owner_stale?(owner) do
    with {:ok, current_namespace} <- pid_namespace_scope(),
         true <- current_namespace == owner["pid_namespace_scope"] do
      case process_start_time(owner["os_pid"]) do
        :dead -> true
        {:ok, current_start_time} -> current_start_time != owner["os_start_time"]
        {:unavailable, _reason} -> false
      end
    else
      _unavailable_or_other_namespace -> false
    end
  end

  defp decode_owner_pid(encoded_pid) do
    with {:ok, binary} <- Base.decode64(encoded_pid),
         pid when is_pid(pid) <- :erlang.binary_to_term(binary, [:safe]),
         true <- node(pid) == node() do
      {:ok, pid}
    else
      _other -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp remove_stale_owned_lock(lock_path, %{"token" => token}) do
    claim_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    reclaim_path = "#{lock_path}.reclaim-#{token}-#{claim_id}"

    case create_reclaim_link(lock_path, reclaim_path) do
      :ok ->
        result = remove_fenced_stale_lock(lock_path, reclaim_path, token)
        File.rm(reclaim_path)
        result

      {:error, :enoent} ->
        :reclaimed

      {:error, :eexist} ->
        :locked

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_fenced_stale_lock(lock_path, reclaim_path, token) do
    with {:ok, %File.Stat{links: 2}} <- File.stat(reclaim_path),
         {:ok, %{"token" => ^token}} <- read_lock_owner(lock_path),
         {:ok, %{"token" => ^token}} <- read_lock_owner(reclaim_path),
         :ok <- remove_public_lock(lock_path) do
      :reclaimed
    else
      _other -> :locked
    end
  end

  defp recover_lock_namespace,
    do: recover_lock_namespace(Path.join(state_root(), "locks"))

  defp recover_lock_namespace(lock_root) do
    case lock_override(:file_ls, fn -> File.ls(lock_root) end) do
      {:ok, entries} ->
        entries
        |> Enum.sort_by(&lock_recovery_order/1)
        |> Enum.reduce_while(:ok, &recover_lock_entry(lock_root, &1, &2))

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:terminal_lock_namespace_unavailable, reason}}
    end
  end

  defp lock_recovery_order(entry), do: if(transient_lock_artifact?(entry), do: 0, else: 1)

  defp recover_lock_entry(lock_root, entry, :ok) do
    lock_path = Path.join(lock_root, entry)

    result =
      cond do
        transient_lock_artifact?(entry) -> recover_transient_lock_artifact(lock_path)
        String.ends_with?(entry, ".lock") -> recover_published_lock(lock_path)
        true -> :reclaimed
      end

    case result do
      :reclaimed -> {:cont, :ok}
      :locked -> {:halt, {:error, {:active_marker_locked, lock_path, :eexist}}}
      {:error, reason} -> {:halt, {:error, {:active_marker_locked, lock_path, reason}}}
    end
  end

  defp transient_lock_artifact?(entry) do
    String.contains?(entry, ".lock.candidate-") or String.contains?(entry, ".lock.reclaim-")
  end

  defp recover_transient_lock_artifact(path) do
    case lock_lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        normalize_transient_lock_removal(remove_transient_lock(path))

      {:ok, %File.Stat{type: type}} ->
        {:error, {:invalid_transient_lock_artifact, type}}

      {:error, :enoent} ->
        :reclaimed

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_transient_lock_removal(result) when result in [:ok, {:error, :enoent}], do: :reclaimed
  defp normalize_transient_lock_removal({:error, reason}), do: {:error, reason}

  defp recover_published_lock(path) do
    case lock_lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> reclaim_stale_lock(path)
      {:ok, %File.Stat{type: :directory}} -> {:error, :unsupported_legacy_lock_directory}
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_lock_target, type}}
      {:error, :enoent} -> :reclaimed
      {:error, reason} -> {:error, reason}
    end
  end

  defp runtime_instance, do: initialize_runtime_instance()

  defp initialize_runtime_instance do
    :global.trans(
      {@runtime_instance_key, self()},
      fn ->
        case :persistent_term.get(@runtime_instance_key, nil) do
          nil ->
            instance = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
            :persistent_term.put(@runtime_instance_key, instance)
            instance

          instance ->
            instance
        end
      end,
      [node()]
    )
  end

  defp machine_scope do
    read_result = lock_override(:machine_read, fn -> File.read("/etc/machine-id") end)
    scope_from_read(read_result, :machine_scope_unavailable)
  end

  defp boot_scope do
    read_result = lock_override(:boot_read, fn -> File.read("/proc/sys/kernel/random/boot_id") end)
    scope_from_read(read_result, :boot_scope_unavailable)
  end

  defp pid_namespace_scope do
    read_result = lock_override(:pid_namespace_read, fn -> File.read_link("/proc/self/ns/pid") end)

    case read_result do
      {:ok, namespace} when namespace != "" -> {:ok, identity_hash(namespace)}
      {:ok, _empty} -> {:unavailable, :pid_namespace_unavailable}
      {:error, reason} -> {:unavailable, {:pid_namespace_unavailable, reason}}
    end
  end

  defp scope_from_read({:ok, value}, error) do
    case String.trim(value) do
      "" -> {:unavailable, error}
      normalized -> {:ok, identity_hash(normalized)}
    end
  end

  defp scope_from_read({:error, reason}, error), do: {:unavailable, {error, reason}}

  defp process_start_time(pid) when is_integer(pid) and pid > 0 do
    process_start_time_from_read(lock_process_read(pid))
  end

  defp process_start_time_from_read({:ok, stat}) do
    with [_prefix, fields] <- String.split(stat, ") ", parts: 2),
         value when is_binary(value) <- fields |> String.split() |> Enum.at(19),
         {:ok, start_time} <- parse_positive_integer(value) do
      {:ok, start_time}
    else
      _malformed -> {:unavailable, :malformed_process_stat}
    end
  end

  defp process_start_time_from_read({:error, :enoent}), do: :dead
  defp process_start_time_from_read({:error, reason}), do: {:unavailable, reason}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _invalid -> {:unavailable, :invalid_positive_integer}
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp persist_mirrored(paths, writer, error_tag) do
    {local_paths, global_paths} = Enum.split(paths, 2)

    with {:ok, selected_path} <- persist_candidates(local_paths, writer, error_tag),
         :ok <- persist_required(global_paths, writer, error_tag) do
      {:ok, selected_path}
    end
  end

  defp persist_required(paths, writer, error_tag) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      result = with :ok <- File.mkdir_p(Path.dirname(path)), do: writer.(path)

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {error_tag, path, reason}}}
      end
    end)
  end

  defp persist_candidates(paths, writer, error_tag) do
    Enum.reduce_while(paths, {:error, {error_tag, :no_path}}, fn path, _last_error ->
      result = with :ok <- File.mkdir_p(Path.dirname(path)), do: writer.(path)

      candidate_result(result, path, error_tag)
    end)
  end

  defp candidate_result(:ok, path, _error_tag), do: {:halt, {:ok, path}}

  defp candidate_result({:error, reason} = error, path, error_tag) do
    if fail_closed_active_error?(reason),
      do: {:halt, error},
      else: {:cont, {:error, {error_tag, path, reason}}}
  end

  defp fail_closed_active_error?(reason) do
    reason in [:receipt_conflict, :active_marker_owner_mismatch] or
      match?({:active_marker_invalid, _reason}, reason) or
      match?({:active_marker_replace_failed, _reason}, reason)
  end

  defp atomic_create(path, payload) do
    case File.write(path, payload, [:exclusive, :sync]) do
      :ok ->
        File.chmod(path, 0o600)

      {:error, :eexist} ->
        existing_receipt_result(path, payload)

      {:error, _reason} = error ->
        error
    end
  end

  defp existing_receipt_result(path, payload) do
    cond do
      not File.regular?(path) -> {:error, :invalid_receipt_target}
      File.read(path) == {:ok, payload} -> :ok
      true -> {:error, :receipt_conflict}
    end
  end

  defp atomic_replace(path, payload) do
    temp_path = temp_path(path)

    with :ok <- File.write(temp_path, payload),
         :ok <- File.chmod(temp_path, 0o600),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(temp_path)
        error
    end
  end

  defp temp_path(path), do: "#{path}.tmp-#{System.unique_integer([:positive, :monotonic])}"

  defp json_safe(nil), do: nil

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), json_safe(nested)} end)
  end

  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp bounded_required(value, max_bytes) when is_binary(value), do: bounded(value, max_bytes)
  defp bounded_required(_value, _max_bytes), do: raise(ArgumentError, "required evidence string is invalid")

  defp bounded_optional(value, max_bytes) when is_binary(value) and value != "",
    do: bounded(value, max_bytes)

  defp bounded_optional(_value, _max_bytes), do: nil

  defp bounded(value, max_bytes) do
    value = if String.valid?(value), do: value, else: "[INVALID_UTF8]"

    if byte_size(value) <= max_bytes do
      value
    else
      value
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, &bounded_grapheme(&1, &2, max_bytes))
      |> elem(0)
      |> Enum.reverse()
      |> IO.iodata_to_binary()
    end
  end

  defp bounded_grapheme(grapheme, {parts, bytes}, max_bytes) do
    next_bytes = bytes + byte_size(grapheme)

    if next_bytes <= max_bytes,
      do: {:cont, {[grapheme | parts], next_bytes}},
      else: {:halt, {parts, bytes}}
  end

  defp normalize_attempt(value) when is_integer(value) and value >= 0, do: value
  defp normalize_attempt(_value), do: nil

  defp normalize_writer_id(value) when is_binary(value) and byte_size(value) == 64, do: value
  defp normalize_writer_id(_value), do: nil

  defp normalize_provider_code(value) when value in ["RESOURCE_EXHAUSTED", "UNAUTHENTICATED", "PERMISSION_DENIED", "UNAVAILABLE"],
    do: value

  defp normalize_provider_code(_value), do: nil

  defp normalize_http_status(value) when is_integer(value) and value in 100..599, do: value
  defp normalize_http_status(_value), do: nil

  defp normalize_reset_hint(value) when is_binary(value) do
    value = bounded(value, @max_hint_bytes)
    if Regex.match?(~r/\A[0-9]+(?:\s*[smhd])(?:\s*[0-9]+\s*[smhd]){0,3}\z/i, value), do: value
  end

  defp normalize_reset_hint(_value), do: nil

  defp normalize_liveness(value)
       when value in [:alive_but_thinking, :semantically_stuck, :dead_or_unreachable],
       do: value

  defp normalize_liveness(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
