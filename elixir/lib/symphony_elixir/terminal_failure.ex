defmodule SymphonyElixir.TerminalFailure do
  @moduledoc """
  Provider-neutral, bounded terminal evidence emitted after a worker attempt can no longer continue.

  Provider adapters classify native failures. This module retains only reviewed structured fields,
  binds correlation fields, and persists immutable receipts plus a fail-closed active marker. Raw
  provider prose, account identifiers, profile paths, and credential payloads are never retained.
  """

  @max_hint_bytes 128
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
          required(:workflow_scope) => String.t(),
          required(:reason) => reason(),
          required(:category) => String.t(),
          required(:backend) => atom(),
          required(:issue_id) => String.t() | nil,
          required(:issue_identifier) => String.t() | nil,
          required(:attempt) => non_neg_integer() | nil,
          required(:session_id) => String.t() | nil,
          required(:workspace) => Path.t(),
          required(:binding_id) => String.t() | nil,
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
      occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    evidence =
      evidence
      |> maybe_put(:provider_code, normalize_provider_code(Map.get(details, :provider_code)))
      |> maybe_put(:http_status, normalize_http_status(Map.get(details, :http_status)))
      |> maybe_put(:reset_hint, normalize_reset_hint(Map.get(details, :reset_hint)))
      |> maybe_put(:liveness, normalize_liveness(Map.get(details, :liveness)))

    Map.put(evidence, :event_id, event_id(evidence))
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
          :none | {:settled, evidence()} | {:ambiguous, evidence()} | {:error, term()}
  def recovery_state(workspace) when is_binary(workspace) do
    read_active(active_paths(workspace, nil), workspace, nil)
  end

  @spec recovery_state(Path.t(), String.t()) ::
          :none | {:settled, evidence()} | {:ambiguous, evidence()} | {:error, term()}
  def recovery_state(workspace, issue_id) when is_binary(workspace) and is_binary(issue_id) do
    read_active(active_paths(workspace, issue_id), workspace, nil)
  end

  @spec recovery_state_for_issue(String.t()) ::
          :none | {:settled, evidence()} | {:ambiguous, evidence()} | {:error, term()}
  def recovery_state_for_issue(issue_id) when is_binary(issue_id) do
    read_active([global_active_path(issue_id)], nil, nil)
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

      {:error, _reason} = error ->
        error
    end
  end

  @spec clear_active(Path.t(), String.t() | nil, String.t()) :: :ok | {:error, term()}
  def clear_active(workspace, issue_id, expected_event_id)
      when is_binary(workspace) and is_binary(expected_event_id) do
    scope = active_marker_scope(workspace, issue_id, expected_event_id)
    {local_paths, global_paths} = Enum.split(active_paths(workspace, issue_id, scope), 2)

    case clear_paths(local_paths, expected_event_id) do
      :ok -> clear_paths(global_paths, expected_event_id)
      {:error, _reason} = error -> error
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

  @spec storage_ready() :: :ok | {:error, term()}
  def storage_ready do
    probe_path = Path.join(state_root(), ".write-probe-#{System.unique_integer([:positive, :monotonic])}")

    with :ok <- File.mkdir_p(Path.dirname(probe_path)),
         :ok <- File.write(probe_path, "ready", [:exclusive, :sync]),
         :ok <- File.rm(probe_path) do
      :ok
    else
      {:error, reason} ->
        File.rm(probe_path)
        {:error, {:terminal_state_root_unavailable, reason}}
    end
  end

  @spec record_resume(Path.t(), evidence(), String.t(), non_neg_integer()) ::
          {:ok, Path.t()} | {:error, term()}
  def record_resume(workspace, %{event_id: event_id} = evidence, binding_id, attempt)
      when is_binary(workspace) and is_binary(event_id) and is_binary(binding_id) and
             is_integer(attempt) and attempt >= 0 do
    receipt = %{
      "terminal_event_id" => event_id,
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
          reason: reason,
          category: category,
          backend: backend,
          workspace: workspace,
          occurred_at: occurred_at
        } = evidence
      ) do
    valid_hash?(event_id) and valid_hash?(Map.get(evidence, :workflow_scope)) and
      valid_reason?(reason, category) and valid_backend?(backend) and
      is_binary(workspace) and workspace != "" and is_binary(occurred_at)
  end

  def valid?(_evidence), do: false

  defp valid_hash?(value), do: is_binary(value) and byte_size(value) == 64
  defp valid_reason?(reason, category), do: reason in @reasons and category == category(reason)
  defp valid_backend?(backend), do: is_atom(backend) and not is_nil(backend)

  defp read_active([], _workspace, nil), do: :none
  defp read_active([], _workspace, error), do: {:error, error}

  defp read_active([path | rest], workspace, prior_error) do
    case File.read(path) do
      {:ok, contents} -> decode_recovery_state(workspace, contents)
      {:error, :enoent} -> read_active(rest, workspace, prior_error)
      {:error, reason} -> read_active(rest, workspace, prior_error || {path, reason})
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

  defp decode_recovery_state(workspace, contents) do
    with {:ok, decoded} <- Jason.decode(contents),
         {:ok, evidence} <- decode_evidence(decoded) do
      recovery_disposition(workspace, evidence)
    end
  end

  defp recovery_disposition(nil, evidence),
    do: recovery_disposition(evidence.workspace, evidence)

  defp recovery_disposition(workspace, evidence) do
    if Enum.any?(
         resume_receipt_paths(
           workspace,
           evidence.issue_id,
           evidence.event_id,
           evidence.workflow_scope
         ),
         &File.regular?/1
       ),
       do: {:ambiguous, evidence},
       else: {:settled, evidence}
  end

  defp decode_evidence(decoded) when is_map(decoded) do
    reason = decode_reason(Map.get(decoded, "reason"))
    backend = decode_backend(Map.get(decoded, "backend"))
    liveness = decode_liveness(Map.get(decoded, "liveness"))

    evidence = %{
      event_id: Map.get(decoded, "event_id"),
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
      occurred_at: Map.get(decoded, "occurred_at")
    }

    evidence =
      evidence
      |> maybe_put(:provider_code, normalize_provider_code(Map.get(decoded, "provider_code")))
      |> maybe_put(:http_status, normalize_http_status(Map.get(decoded, "http_status")))
      |> maybe_put(:reset_hint, normalize_reset_hint(Map.get(decoded, "reset_hint")))
      |> maybe_put(:liveness, liveness)

    if valid?(evidence) and event_id(evidence) == evidence.event_id,
      do: {:ok, evidence},
      else: {:error, :invalid_terminal_failure_receipt}
  rescue
    ArgumentError -> {:error, :invalid_terminal_failure_receipt}
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
    |> Map.drop([:occurred_at, :event_id])
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
    persist_mirrored(
      paths,
      &claim_active_marker(&1, payload, evidence),
      :active_marker_unavailable
    )
  end

  defp claim_active_marker(path, payload, evidence) do
    case atomic_create(path, payload) do
      :ok ->
        :ok

      {:error, :receipt_conflict} ->
        replace_claimed_active_marker(path, payload, evidence)

      {:error, _reason} = error ->
        error
    end
  end

  defp replace_claimed_active_marker(path, payload, evidence) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, prior} <- decode_evidence(decoded),
         true <- same_active_owner?(prior, evidence),
         true <- resumed_event?(prior) do
      replace_active_marker(path, payload)
    else
      false -> {:error, :active_marker_owner_mismatch}
      {:error, reason} -> {:error, {:active_marker_invalid, reason}}
    end
  end

  defp replace_active_marker(path, payload) do
    case atomic_replace(path, payload) do
      :ok -> :ok
      {:error, reason} -> {:error, {:active_marker_replace_failed, reason}}
    end
  end

  defp same_active_owner?(prior, evidence) do
    prior.workflow_scope == evidence.workflow_scope and prior.issue_id == evidence.issue_id
  end

  defp resumed_event?(evidence) do
    Enum.any?(
      resume_receipt_paths(
        evidence.workspace,
        evidence.issue_id,
        evidence.event_id,
        evidence.workflow_scope
      ),
      &File.regular?/1
    )
  end

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

      case result do
        :ok -> {:halt, {:ok, path}}
        {:error, :receipt_conflict} = error -> {:halt, error}
        {:error, :active_marker_owner_mismatch} = error -> {:halt, error}
        {:error, {:active_marker_invalid, _reason}} = error -> {:halt, error}
        {:error, {:active_marker_replace_failed, _reason}} = error -> {:halt, error}
        {:error, reason} -> {:cont, {:error, {error_tag, path, reason}}}
      end
    end)
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
