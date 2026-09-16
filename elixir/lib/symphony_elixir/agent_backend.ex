defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Small execution-layer contract shared by native Harness adapters.

  The contract covers lifecycle only. Each backend keeps its own process protocol, session state,
  event mapping, credential handling, and failure semantics.
  """

  @type session :: term()
  @type backend :: module()

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @spec resolve(String.t() | atom()) :: {:ok, backend()} | {:error, term()}
  def resolve(backend) when is_atom(backend), do: backend |> Atom.to_string() |> resolve()

  def resolve("codex"), do: {:ok, SymphonyElixir.Codex.AppServer}
  def resolve("pi"), do: {:ok, SymphonyElixir.Pi.Backend}
  def resolve(backend) when is_binary(backend), do: {:error, {:unsupported_backend, backend}}
  def resolve(backend), do: {:error, {:invalid_backend, backend}}
end
