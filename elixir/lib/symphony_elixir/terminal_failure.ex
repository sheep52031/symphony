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
  @ownerless_lock_grace_seconds 2
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
    with {:ok, payload} <- Jason.encode(json_safe(evidence), pretty: true),
         {:ok, receipt_path} <-
           persist_immutable_candidates(
             event_receipt_paths(
               workspace,
               evidence.issue_id,
               event_id,
               evidence.workflow_scope
             ),
             payload
           ),
         {:ok, _active_path} <-
           persist_active_candidates(
             active_paths(workspace, evidence.issue_id, evidence.workflow_scope),
             payload,
             evidence
           ) do
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
    case read_storage_fault([global_storage_fault_path(issue_id)], nil) do
      :none -> read_active([global_active_path(issue_id)], nil, nil)
      result -> result
    end
  end

  defp read_recovery_state(workspace, issue_id) do
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
      case clear_paths(paths, expected_event_id) do
        :ok ->
          clear_fault_paths(
            storage_fault_paths(workspace, issue_id, scope),
            expected_event_id
          )

        {:error, _reason} = error ->
          error
      end
    end)
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

  @spec storage_ready() :: :ok | {:error, term()}
  def storage_ready do
    case probe_storage_namespaces(["events", "active", "resumes", "faults", "locks"]) do
      :ok -> recover_lock_namespace()
      {:error, _reason} = error -> error
    end
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
      optional_field_valid?(decoded, "public_attempt", &valid_raw_attempt?/1) and
      optional_field_valid?(decoded, "provider_code", &(normalize_provider_code(&1) == &1)) and
      optional_field_valid?(decoded, "http_status", &(normalize_http_status(&1) == &1)) and
      optional_field_valid?(decoded, "reset_hint", &(normalize_reset_hint(&1) == &1)) and
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
  defp valid_raw_attempt?(value), do: is_integer(value) and value >= 0
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

  defp persist_immutable_candidates(paths, payload),
    do: persist_mirrored(paths, &atomic_create(&1, payload), :immutable_receipt_unavailable)

  defp persist_active_candidates(paths, payload, evidence) do
    with_active_marker_locks(paths, fn ->
      with :ok <- validate_existing_active_paths(paths, payload, evidence),
           {:ok, selected_path} <- persist_local_active_paths(paths, payload, evidence),
           :ok <- persist_global_active_paths(paths, payload, evidence) do
        {:ok, selected_path}
      end
    end)
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
    @spec lock_recovery_edges_for_test(Path.t()) :: map()
    def lock_recovery_edges_for_test(root) do
      cleanup_path = Path.join(root, "cleanup.lock")
      File.mkdir_p!(cleanup_path)
      File.write!(lock_owner_path(cleanup_path), "owner")

      failed_owner_path = Path.join(root, "failed-owner.lock")
      File.mkdir_p!(lock_owner_path(failed_owner_path))

      invalid_owner = lock_owner(String.duplicate("a", 64)) |> Map.put("os_start_time", 42)
      missing_lock_root = Path.join(root, "missing-lock-root")
      invalid_lock_root = Path.join(root, "invalid-lock-root")
      File.write!(invalid_lock_root, "not-a-directory")

      %{
        cleanup: cleanup_failed_lock(cleanup_path),
        owner_failure: persist_lock_owner(failed_owner_path, String.duplicate("b", 64)),
        invalid_owner: valid_lock_owner?(invalid_owner),
        incomplete_owner: valid_lock_owner?(%{}),
        missing: reclaim_stale_lock(Path.join(root, "missing.lock")),
        missing_rmdir: normalize_ownerless_rmdir({:error, :enoent}),
        denied_rmdir: normalize_ownerless_rmdir({:error, :eacces}),
        denied_stat: reclaim_ownerless_lock_from_stat("unused", {:error, :eacces}, 0),
        missing_namespace: recover_lock_namespace(missing_lock_root),
        invalid_namespace: recover_lock_namespace(invalid_lock_root),
        machine_fallback: machine_scope_from_read({:error, :enoent}, "test-boot"),
        boot_fallback: boot_scope_from_read({:error, :enoent}),
        short_stat: process_start_time_from_read({:ok, "1 (beam) S"}),
        missing_stat: process_start_time_from_read({:error, :enoent}),
        invalid_pid: decode_owner_pid(Base.encode64("not-an-erlang-term"))
      }
    end
  end

  defp with_active_marker_locks(paths, operation) do
    lock_paths = [ownership_lock_path(paths)]

    case acquire_marker_locks(lock_paths, []) do
      {:ok, acquired} ->
        try do
          operation.()
        after
          release_marker_locks(acquired)
        end

      {:error, reason, acquired} ->
        release_marker_locks(acquired)
        {:error, reason}
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
    case File.mkdir_p(Path.dirname(lock_path)) do
      :ok -> create_owned_lock_directory(lock_path, token)
      {:error, reason} -> {:error, {:lock_namespace_unavailable, reason}}
    end
  end

  defp create_owned_lock_directory(lock_path, token) do
    case File.mkdir(lock_path) do
      :ok -> persist_lock_owner(lock_path, token)
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_lock_owner(lock_path, token) do
    with {:ok, payload} <- Jason.encode(lock_owner(token)),
         :ok <- File.write(lock_owner_path(lock_path), payload, [:exclusive, :sync]) do
      :ok
    else
      {:error, _reason} = error ->
        cleanup_failed_lock(lock_path)
        error
    end
  end

  defp cleanup_failed_lock(lock_path) do
    File.rm(lock_owner_path(lock_path))
    File.rmdir(lock_path)
    :ok
  end

  defp release_marker_locks(locks), do: Enum.each(locks, &release_owned_lock/1)

  defp release_owned_lock({lock_path, token}) do
    with {:ok, %{"token" => ^token}} <- read_lock_owner(lock_path),
         :ok <- File.rm(lock_owner_path(lock_path)) do
      File.rmdir(lock_path)
    else
      _other -> :ok
    end
  end

  defp lock_owner(token) do
    %{
      "token" => token,
      "runtime_instance" => runtime_instance(),
      "erlang_pid" => self() |> :erlang.term_to_binary() |> Base.encode64(),
      "machine_scope" => machine_scope(),
      "os_pid" => System.pid(),
      "os_start_time" => os_process_start_time(System.pid())
    }
  end

  defp lock_owner_path(lock_path), do: Path.join(lock_path, "owner.json")

  defp read_lock_owner(lock_path) do
    with {:ok, contents} <- File.read(lock_owner_path(lock_path)),
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
        "erlang_pid",
        "machine_scope",
        "os_pid",
        "os_start_time",
        "runtime_instance",
        "token"
      ] and
      valid_hash?(Map.get(owner, "token")) and
      valid_hash?(Map.get(owner, "runtime_instance")) and
      valid_hash?(Map.get(owner, "machine_scope")) and
      is_binary(Map.get(owner, "erlang_pid")) and
      is_binary(Map.get(owner, "os_pid")) and
      is_binary(Map.get(owner, "os_start_time"))
  end

  defp valid_lock_owner?(_owner), do: false

  defp reclaim_stale_lock(lock_path) do
    case read_lock_owner(lock_path) do
      {:ok, owner} ->
        if stale_lock_owner?(owner),
          do: remove_stale_owned_lock(lock_path, owner),
          else: :locked

      {:error, :owner_missing} ->
        reclaim_ownerless_lock(lock_path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stale_lock_owner?(owner) do
    if owner["runtime_instance"] == runtime_instance() do
      case decode_owner_pid(owner["erlang_pid"]) do
        {:ok, pid} -> not Process.alive?(pid)
        :error -> false
      end
    else
      owner["machine_scope"] == machine_scope() and
        os_process_start_time(owner["os_pid"]) != owner["os_start_time"]
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
    with {:ok, %{"token" => ^token}} <- read_lock_owner(lock_path),
         :ok <- File.rm(lock_owner_path(lock_path)),
         :ok <- File.rmdir(lock_path) do
      :reclaimed
    else
      _other -> :locked
    end
  end

  defp reclaim_ownerless_lock(lock_path) do
    stale_before = System.os_time(:second) - @ownerless_lock_grace_seconds
    reclaim_ownerless_lock_from_stat(lock_path, File.stat(lock_path, time: :posix), stale_before)
  end

  defp reclaim_ownerless_lock_from_stat(lock_path, stat_result, stale_before) do
    case stat_result do
      {:ok, %{mtime: modified_at}} when is_integer(modified_at) and modified_at <= stale_before ->
        normalize_ownerless_rmdir(File.rmdir(lock_path))

      {:ok, _stat} ->
        :locked

      {:error, :enoent} ->
        :reclaimed

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_ownerless_rmdir(result) when result in [:ok, {:error, :enoent}], do: :reclaimed
  defp normalize_ownerless_rmdir({:error, _reason}), do: :locked

  defp recover_lock_namespace,
    do: recover_lock_namespace(Path.join(state_root(), "locks"))

  defp recover_lock_namespace(lock_root) do
    case File.ls(lock_root) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, &recover_lock_entry(lock_root, &1, &2))

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:terminal_lock_namespace_unavailable, reason}}
    end
  end

  defp recover_lock_entry(lock_root, entry, :ok) do
    lock_path = Path.join(lock_root, entry)

    result =
      if String.ends_with?(entry, ".lock") and File.dir?(lock_path),
        do: reclaim_stale_lock(lock_path),
        else: :reclaimed

    case result do
      :reclaimed -> {:cont, :ok}
      :locked -> {:halt, {:error, {:active_marker_locked, lock_path, :eexist}}}
      {:error, reason} -> {:halt, {:error, {:active_marker_locked, lock_path, reason}}}
    end
  end

  defp runtime_instance do
    identity_hash(
      Enum.join(
        [machine_scope(), current_boot_scope(), System.pid(), os_process_start_time(System.pid())],
        ":"
      )
    )
  end

  defp machine_scope do
    machine_scope_from_read(File.read("/etc/machine-id"), current_boot_scope())
  end

  defp machine_scope_from_read({:ok, machine_id}, _boot_scope),
    do: identity_hash(String.trim(machine_id))

  defp machine_scope_from_read({:error, _reason}, boot_scope),
    do: identity_hash("unknown-machine:#{boot_scope}")

  defp current_boot_scope do
    boot_scope_from_read(File.read("/proc/sys/kernel/random/boot_id"))
  end

  defp boot_scope_from_read({:ok, boot_id}), do: String.trim(boot_id)
  defp boot_scope_from_read({:error, _reason}), do: "unknown-boot"

  defp os_process_start_time(pid) when is_binary(pid) do
    process_start_time_from_read(File.read("/proc/#{pid}/stat"))
  end

  defp process_start_time_from_read({:ok, stat}) do
    stat
    |> String.split(") ", parts: 2)
    |> List.last()
    |> String.split()
    |> Enum.at(19)
    |> case do
      value when is_binary(value) -> value
      _other -> "unavailable"
    end
  end

  defp process_start_time_from_read({:error, _reason}), do: "unavailable"

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
  defp candidate_result({:error, :receipt_conflict} = error, _path, _error_tag), do: {:halt, error}

  defp candidate_result({:error, reason} = error, path, error_tag) do
    if fail_closed_active_error?(reason),
      do: {:halt, error},
      else: {:cont, {:error, {error_tag, path, reason}}}
  end

  defp fail_closed_active_error?(reason) do
    reason == :active_marker_owner_mismatch or
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
