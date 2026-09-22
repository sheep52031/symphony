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
  @type launch_binding :: %{
          required(:binding_id) => String.t(),
          required(:backend) => backend_id(),
          required(:options) => map()
        }
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
  @callback validate_binding(map(), SymphonyElixir.Config.Schema.t()) :: :ok | {:error, term()}
  @callback preflight_binding(map(), Path.t(), SymphonyElixir.Config.Schema.t()) ::
              :ok | {:error, term()}

  @optional_callbacks validate_binding: 2, preflight_binding: 3

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

  @spec validate_launch_binding(String.t() | atom(), term(), SymphonyElixir.Config.Schema.t()) ::
          {:ok, launch_binding()} | {:error, term()}
  def validate_launch_binding(expected_backend, binding, settings) when is_map(binding) do
    with {:ok, backend_id, module} <- resolve(expected_backend),
         {:ok, binding_backend_id, _binding_module} <- binding_backend(binding),
         true <- binding_backend_id == backend_id || {:error, :launch_binding_backend_mismatch},
         {:ok, binding_id} <- binding_id(binding),
         {:ok, options} <- binding_options(binding),
         :ok <- validate_backend_binding(module, options, settings) do
      {:ok, %{binding_id: binding_id, backend: backend_id, options: options}}
    end
  end

  def validate_launch_binding(_expected_backend, _binding, _settings),
    do: {:error, :invalid_launch_binding}

  @spec preflight_launch_binding(
          String.t() | atom(),
          term(),
          Path.t(),
          SymphonyElixir.Config.Schema.t()
        ) :: {:ok, launch_binding()} | {:error, term()}
  def preflight_launch_binding(expected_backend, binding, workspace, settings)
      when is_binary(workspace) do
    with {:ok, normalized} <- validate_launch_binding(expected_backend, binding, settings),
         {:ok, _backend_id, module} <- resolve(expected_backend),
         :ok <- preflight_backend_binding(module, normalized.options, workspace, settings) do
      {:ok, normalized}
    end
  end

  def preflight_launch_binding(_expected_backend, _binding, _workspace, _settings),
    do: {:error, :invalid_launch_binding_workspace}

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

  defp binding_backend(binding) do
    case Map.get(binding, :backend) || Map.get(binding, "backend") do
      backend when (is_atom(backend) and not is_nil(backend)) or is_binary(backend) -> resolve(backend)
      _ -> {:error, :launch_binding_backend_missing}
    end
  end

  defp binding_id(binding) do
    case Map.get(binding, :binding_id) || Map.get(binding, "binding_id") do
      binding_id when is_binary(binding_id) and byte_size(binding_id) <= 256 ->
        if String.trim(binding_id) == "",
          do: {:error, :launch_binding_id_blank},
          else: {:ok, binding_id}

      _ ->
        {:error, :launch_binding_id_invalid}
    end
  end

  defp binding_options(binding) do
    case Map.get(binding, :options) || Map.get(binding, "options") || %{} do
      %{} = options -> {:ok, options}
      _ -> {:error, :launch_binding_options_invalid}
    end
  end

  defp validate_backend_binding(module, options, settings) do
    if Code.ensure_loaded?(module) and function_exported?(module, :validate_binding, 2) do
      module.validate_binding(options, settings)
    else
      if options == %{}, do: :ok, else: {:error, :launch_binding_options_unsupported}
    end
  end

  defp preflight_backend_binding(module, options, workspace, settings) do
    if Code.ensure_loaded?(module) and function_exported?(module, :preflight_binding, 3) do
      module.preflight_binding(options, workspace, settings)
    else
      :ok
    end
  end
end
