defmodule SymphonyElixir.AgentBackend do
  @moduledoc false

  @type session :: term()
  @type turn_result :: %{required(:session_id) => String.t(), optional(atom()) => term()}

  @backends %{"codex" => SymphonyElixir.Codex.AppServer}

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), map(), keyword()) ::
              {:ok, turn_result()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @spec supported_names() :: [String.t()]
  def supported_names, do: Map.keys(@backends)

  @spec resolve(String.t() | atom()) :: {:ok, module()} | {:error, term()}
  def resolve(backend) when is_atom(backend), do: backend |> Atom.to_string() |> resolve()

  def resolve(backend) when is_binary(backend) do
    case Map.fetch(@backends, backend) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unsupported_backend, backend}}
    end
  end

  def resolve(backend), do: {:error, {:invalid_backend, backend}}
end
