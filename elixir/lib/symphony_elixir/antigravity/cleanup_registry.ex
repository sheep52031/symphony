defmodule SymphonyElixir.Antigravity.CleanupRegistry do
  @moduledoc false

  use GenServer

  @retention_ms 5_000

  @type cleanup_result :: :ok | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec register(pid(), pid()) :: :ok | {:error, :cleanup_owner_already_registered}
  def register(owner_pid, guard_pid) when is_pid(owner_pid) and is_pid(guard_pid) do
    GenServer.call(__MODULE__, {:register, owner_pid, guard_pid})
  end

  @doc false
  @spec complete(pid(), pid(), cleanup_result()) :: :ok
  def complete(owner_pid, guard_pid, :ok) when is_pid(owner_pid) and is_pid(guard_pid) do
    GenServer.call(__MODULE__, {:complete, owner_pid, guard_pid, :ok})
  end

  def complete(owner_pid, guard_pid, {:error, _reason} = result)
      when is_pid(owner_pid) and is_pid(guard_pid) do
    GenServer.call(__MODULE__, {:complete, owner_pid, guard_pid, result})
  end

  @spec await(pid(), timeout()) :: cleanup_result() | {:error, :cleanup_not_registered}
  def await(owner_pid, timeout_ms) when is_pid(owner_pid) and is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(__MODULE__, {:await, owner_pid}, timeout_ms)
  catch
    :exit, {:timeout, _call} -> {:error, :cleanup_ack_timeout}
    :exit, {:noproc, _call} -> {:error, :cleanup_registry_unavailable}
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:register, owner_pid, guard_pid}, _from, state) do
    case Map.get(state, owner_pid) do
      nil ->
        entry = %{guard_pid: guard_pid, result: nil, waiters: [], expiry_token: nil}
        {:reply, :ok, Map.put(state, owner_pid, entry)}

      %{guard_pid: ^guard_pid} ->
        {:reply, :ok, state}

      %{result: result} when not is_nil(result) ->
        entry = %{guard_pid: guard_pid, result: nil, waiters: [], expiry_token: nil}
        {:reply, :ok, Map.put(state, owner_pid, entry)}

      _other ->
        {:reply, {:error, :cleanup_owner_already_registered}, state}
    end
  end

  def handle_call({:complete, owner_pid, guard_pid, result}, _from, state) do
    case Map.get(state, owner_pid) do
      %{guard_pid: ^guard_pid, waiters: []} = entry ->
        expiry_token = make_ref()
        Process.send_after(self(), {:expire, owner_pid, guard_pid, expiry_token}, @retention_ms)
        updated = %{entry | result: result, expiry_token: expiry_token}
        {:reply, :ok, Map.put(state, owner_pid, updated)}

      %{guard_pid: ^guard_pid, waiters: waiters} ->
        Enum.each(waiters, &GenServer.reply(&1, result))
        {:reply, :ok, Map.delete(state, owner_pid)}

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:await, owner_pid}, from, state) do
    case Map.get(state, owner_pid) do
      nil ->
        {:reply, {:error, :cleanup_not_registered}, state}

      %{result: result} when not is_nil(result) ->
        {:reply, result, Map.delete(state, owner_pid)}

      %{waiters: waiters} = entry ->
        {:noreply, Map.put(state, owner_pid, %{entry | waiters: [from | waiters]})}
    end
  end

  @impl true
  def handle_info({:expire, owner_pid, guard_pid, expiry_token}, state) do
    state =
      case Map.get(state, owner_pid) do
        %{guard_pid: ^guard_pid, expiry_token: ^expiry_token} -> Map.delete(state, owner_pid)
        _other -> state
      end

    {:noreply, state}
  end
end
