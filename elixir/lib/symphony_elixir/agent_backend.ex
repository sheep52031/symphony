defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Small execution-layer contract shared by native Harness adapters.

  The contract covers lifecycle and the minimum runner-facing update/result shape. Each backend
  keeps its own process protocol, session state, event mapping, credential handling, and failure
  semantics.
  """

  @type session :: term()
  @type backend :: module()
  @type backend_id :: :codex | :pi
  @type update :: %{
          required(:event) => atom(),
          required(:timestamp) => DateTime.t(),
          optional(atom()) => term()
        }
  @type turn_result :: %{required(:session_id) => String.t(), optional(atom()) => term()}
  @type message_handler :: (update() -> term())

  @backends %{
    "codex" => {:codex, SymphonyElixir.Codex.AppServer},
    "pi" => {:pi, SymphonyElixir.Pi.Backend}
  }

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
end
