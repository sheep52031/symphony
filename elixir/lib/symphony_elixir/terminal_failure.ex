defmodule SymphonyElixir.TerminalFailure do
  @moduledoc """
  Provider-neutral, bounded terminal evidence emitted after a worker attempt can no longer continue.

  Provider adapters classify native failures. This module only validates the shared reason set,
  removes common secret-bearing values, binds correlation fields, and persists an idempotent receipt
  inside the existing issue workspace.
  """

  @max_message_bytes 2_048
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
          optional(:message) => String.t(),
          optional(:liveness) => atom()
        }

  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @spec build(reason(), map(), map()) :: evidence()
  def build(reason, details, context) when reason in @reasons and is_map(details) and is_map(context) do
    evidence = %{
      reason: reason,
      category: category(reason),
      backend: Map.fetch!(context, :backend),
      issue_id: bounded_optional(Map.get(context, :issue_id), 256),
      issue_identifier: bounded_optional(Map.get(context, :issue_identifier), 256),
      attempt: normalize_attempt(Map.get(context, :attempt)),
      session_id: bounded_optional(Map.get(context, :session_id), 256),
      workspace: Map.fetch!(context, :workspace),
      binding_id: bounded_optional(Map.get(context, :binding_id), 256),
      occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    evidence =
      evidence
      |> maybe_put(:provider_code, bounded_optional(Map.get(details, :provider_code), 128))
      |> maybe_put(:http_status, normalize_http_status(Map.get(details, :http_status)))
      |> maybe_put(:reset_hint, bounded_optional(Map.get(details, :reset_hint), @max_hint_bytes))
      |> maybe_put(:message, sanitize_message(Map.get(details, :message)))
      |> maybe_put(:liveness, normalize_liveness(Map.get(details, :liveness)))

    Map.put(evidence, :event_id, event_id(evidence))
  end

  @spec persist(Path.t(), evidence()) :: {:ok, Path.t()} | {:error, term()}
  def persist(workspace, %{event_id: event_id} = evidence)
      when is_binary(workspace) and is_binary(event_id) do
    directory = Path.join(workspace, ".symphony/terminal-events")
    receipt_path = Path.join(directory, "#{event_id}.json")
    latest_path = Path.join(workspace, ".symphony/terminal-failure.json")

    with {:ok, payload} <- Jason.encode(json_safe(evidence), pretty: true),
         :ok <- File.mkdir_p(directory),
         :ok <- atomic_write(receipt_path, payload),
         :ok <- atomic_write(latest_path, payload) do
      {:ok, receipt_path}
    end
  end

  @spec recovery_state(Path.t()) ::
          :none | {:settled, evidence()} | {:ambiguous, evidence()} | {:error, term()}
  def recovery_state(workspace) when is_binary(workspace) do
    active_path = Path.join(workspace, ".symphony/terminal-failure.json")

    case File.read(active_path) do
      {:ok, contents} -> decode_recovery_state(workspace, contents)
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_recovery_state(workspace, contents) do
    with {:ok, decoded} <- Jason.decode(contents),
         {:ok, evidence} <- decode_evidence(decoded) do
      recovery_disposition(workspace, evidence)
    end
  end

  defp recovery_disposition(workspace, evidence) do
    resume_path =
      Path.join(workspace, ".symphony/terminal-resumes/#{evidence.event_id}.json")

    if File.regular?(resume_path),
      do: {:ambiguous, evidence},
      else: {:settled, evidence}
  end

  @spec clear_active(Path.t()) :: :ok | {:error, term()}
  def clear_active(workspace) when is_binary(workspace) do
    case File.rm(Path.join(workspace, ".symphony/terminal-failure.json")) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec record_resume(Path.t(), evidence(), String.t(), non_neg_integer()) ::
          {:ok, Path.t()} | {:error, term()}
  def record_resume(workspace, %{event_id: event_id}, binding_id, attempt)
      when is_binary(workspace) and is_binary(event_id) and is_binary(binding_id) and
             is_integer(attempt) and attempt >= 0 do
    directory = Path.join(workspace, ".symphony/terminal-resumes")
    receipt_path = Path.join(directory, "#{event_id}.json")

    receipt = %{
      "terminal_event_id" => event_id,
      "binding_id" => binding_id,
      "attempt" => attempt,
      "resumed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with {:ok, payload} <- Jason.encode(receipt, pretty: true),
         :ok <- File.mkdir_p(directory),
         :ok <- atomic_write(receipt_path, payload) do
      {:ok, receipt_path}
    end
  end

  @spec sanitize_message(term()) :: String.t() | nil
  def sanitize_message(message) when is_binary(message) do
    message
    |> String.replace(~r/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/u, "[REDACTED_EMAIL]")
    |> String.replace(
      ~r/(?i)\b(bearer|oauth[_-]?(?:token|payload|code)|access[_-]?token|refresh[_-]?token|api[_-]?key|secret|password|credential)\b\s*[:=]?\s*[^\s,;]+/u,
      "\\1=[REDACTED]"
    )
    |> String.replace(~r/\beyJ[A-Za-z0-9_-]{16,}(?:\.[A-Za-z0-9_-]+){1,2}\b/u, "[REDACTED_TOKEN]")
    |> bounded(@max_message_bytes)
  end

  def sanitize_message(_message), do: nil

  @spec valid?(term()) :: boolean()
  def valid?(%{
        event_id: event_id,
        reason: reason,
        category: category,
        backend: backend,
        workspace: workspace,
        occurred_at: occurred_at
      }) do
    is_binary(event_id) and byte_size(event_id) == 64 and reason in @reasons and
      is_binary(category) and is_atom(backend) and is_binary(workspace) and workspace != "" and
      is_binary(occurred_at)
  end

  def valid?(_evidence), do: false

  defp decode_evidence(decoded) when is_map(decoded) do
    reason = decode_reason(Map.get(decoded, "reason"))
    backend = decode_backend(Map.get(decoded, "backend"))
    liveness = decode_liveness(Map.get(decoded, "liveness"))

    evidence = %{
      event_id: Map.get(decoded, "event_id"),
      reason: reason,
      category: Map.get(decoded, "category"),
      backend: backend,
      issue_id: Map.get(decoded, "issue_id"),
      issue_identifier: Map.get(decoded, "issue_identifier"),
      attempt: Map.get(decoded, "attempt"),
      session_id: Map.get(decoded, "session_id"),
      workspace: Map.get(decoded, "workspace"),
      binding_id: Map.get(decoded, "binding_id"),
      occurred_at: Map.get(decoded, "occurred_at")
    }

    evidence =
      evidence
      |> maybe_put(:provider_code, bounded_optional(Map.get(decoded, "provider_code"), 128))
      |> maybe_put(:http_status, normalize_http_status(Map.get(decoded, "http_status")))
      |> maybe_put(:reset_hint, bounded_optional(Map.get(decoded, "reset_hint"), @max_hint_bytes))
      |> maybe_put(:message, sanitize_message(Map.get(decoded, "message")))
      |> maybe_put(:liveness, liveness)

    if valid?(evidence) and event_id(evidence) == evidence.event_id,
      do: {:ok, evidence},
      else: {:error, :invalid_terminal_failure_receipt}
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

  defp atomic_write(path, payload) do
    temp_path = "#{path}.tmp-#{System.unique_integer([:positive, :monotonic])}"

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

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), json_safe(nested)} end)
  end

  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp bounded_optional(value, max_bytes) when is_binary(value) and value != "",
    do: bounded(value, max_bytes)

  defp bounded_optional(_value, _max_bytes), do: nil

  defp bounded(value, max_bytes) when byte_size(value) <= max_bytes, do: value
  defp bounded(value, max_bytes), do: binary_part(value, 0, max_bytes)

  defp normalize_attempt(value) when is_integer(value) and value >= 0, do: value
  defp normalize_attempt(_value), do: nil

  defp normalize_http_status(value) when is_integer(value) and value in 100..599, do: value
  defp normalize_http_status(_value), do: nil

  defp normalize_liveness(value)
       when value in [:alive_but_thinking, :semantically_stuck, :dead_or_unreachable],
       do: value

  defp normalize_liveness(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
