defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Small execution-layer contract shared by native Harness adapters.

  The contract covers lifecycle and the minimum runner-facing update/result shape. Each backend
  keeps its own process protocol, session state, event mapping, credential handling, and failure
  semantics.
  """

  @type session :: term()
  @type backend :: module()
  @type backend_id :: :antigravity | :codex | :pi
  @type update :: %{
          required(:event) => atom(),
          required(:timestamp) => DateTime.t(),
          optional(atom()) => term()
        }
  @type turn_result :: %{required(:session_id) => String.t(), optional(atom()) => term()}
  @type message_handler :: (update() -> term())
  @type contract_error ::
          {:invalid_backend_update, term()}
          | {:invalid_backend_turn_result, term()}
          | {:invalid_backend_start_result, term()}
          | {:invalid_backend_stop_result, term()}

  @backends %{
    "antigravity" => {:antigravity, SymphonyElixir.Antigravity.Backend},
    "codex" => {:codex, SymphonyElixir.Codex.AppServer},
    "pi" => {:pi, SymphonyElixir.Pi.Backend}
  }

  @callback validate_config(SymphonyElixir.Config.Schema.t()) :: :ok | {:error, term()}
  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), map(), keyword()) ::
              {:ok, turn_result()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @spec supported_names() :: [String.t()]
  def supported_names, do: @backends |> Map.keys() |> Enum.sort()

  @spec resolve(String.t() | atom()) :: {:ok, backend_id(), backend()} | {:error, term()}
  def resolve(backend) when is_atom(backend), do: backend |> Atom.to_string() |> resolve()

  def resolve(backend) when is_binary(backend) do
    case Map.fetch(@backends, backend) do
      {:ok, {backend_id, module}} -> {:ok, backend_id, module}
      :error -> {:error, {:unsupported_backend, backend}}
    end
  end

  def resolve(backend), do: {:error, {:invalid_backend, backend}}

  @spec validate_config(String.t() | atom(), SymphonyElixir.Config.Schema.t()) ::
          :ok | {:error, term()}
  def validate_config(backend, settings) do
    with {:ok, _backend_id, module} <- resolve(backend) do
      module.validate_config(settings)
    end
  end

  @spec validate_update(term()) :: :ok | {:error, contract_error()}
  def validate_update(%{event: event, timestamp: %DateTime{}})
      when is_atom(event) and not is_nil(event),
      do: :ok

  def validate_update(update), do: {:error, {:invalid_backend_update, update}}

  @spec validate_turn_result(term()) :: :ok | {:error, contract_error()}
  def validate_turn_result(%{session_id: session_id}) when is_binary(session_id) do
    if String.trim(session_id) == "" do
      {:error, {:invalid_backend_turn_result, :blank_session_id}}
    else
      :ok
    end
  end

  def validate_turn_result(result), do: {:error, {:invalid_backend_turn_result, result}}

  @spec validate_start_result(term()) :: {:ok, session()} | {:error, term()}
  def validate_start_result({:ok, session}), do: {:ok, session}
  def validate_start_result({:error, _reason} = error), do: error
  def validate_start_result(result), do: {:error, {:invalid_backend_start_result, result}}

  @spec validate_stop_result(term()) :: :ok | {:error, contract_error()}
  def validate_stop_result(:ok), do: :ok
  def validate_stop_result(result), do: {:error, {:invalid_backend_stop_result, result}}
end
