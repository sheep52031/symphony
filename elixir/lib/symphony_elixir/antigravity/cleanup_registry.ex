defmodule SymphonyElixir.Antigravity.CleanupRegistry do
  @moduledoc false

  use GenServer

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
  @spec require_ack(pid()) :: :ok
  def require_ack(owner_pid) when is_pid(owner_pid) do
    GenServer.call(__MODULE__, {:require_ack, owner_pid})
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
        {:reply, :ok, Map.put(state, owner_pid, new_entry(owner_pid, guard_pid, false))}

      %{guard_pid: nil} = entry ->
        {:reply, :ok, Map.put(state, owner_pid, attach_guard(entry, guard_pid))}

      %{guard_pid: ^guard_pid} ->
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :cleanup_owner_already_registered}, state}
    end
  end

  def handle_call({:require_ack, owner_pid}, _from, state) do
    state =
      case Map.fetch(state, owner_pid) do
        {:ok, entry} -> Map.put(state, owner_pid, %{entry | required?: true})
        :error -> Map.put(state, owner_pid, new_entry(owner_pid, nil, true))
      end

    {:reply, :ok, state}
  end

  def handle_call({:complete, owner_pid, guard_pid, result}, _from, state) do
    case Map.get(state, owner_pid) do
      %{guard_pid: ^guard_pid, waiters: []} = entry ->
        complete_without_waiter(owner_pid, result, detach_guard_monitor(entry), state)

      %{guard_pid: ^guard_pid, waiters: waiters} = entry ->
        entry = detach_guard_monitor(entry)
        Enum.each(waiters, &GenServer.reply(&1, result))
        {:reply, :ok, delete_entry(state, owner_pid, entry)}

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:await, owner_pid}, from, state) do
    case Map.get(state, owner_pid) do
      nil ->
        {:reply, {:error, :cleanup_not_registered}, state}

      %{result: result} = entry when not is_nil(result) ->
        {:reply, result, delete_entry(state, owner_pid, entry)}

      %{waiters: waiters} = entry ->
        {:noreply, Map.put(state, owner_pid, %{entry | waiters: [from | waiters]})}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    monitored_entry =
      Enum.find(state, fn {_owner_pid, entry} ->
        entry.monitor_ref == monitor_ref or entry.guard_monitor_ref == monitor_ref
      end)

    {:noreply, handle_monitored_down(monitored_entry, monitor_ref, state)}
  end

  defp handle_monitored_down(
         {owner_pid, %{monitor_ref: monitor_ref, guard_pid: nil, required?: true, waiters: []} = entry},
         monitor_ref,
         state
       ) do
    Map.put(state, owner_pid, %{entry | result: :ok})
  end

  defp handle_monitored_down(
         {owner_pid, %{monitor_ref: monitor_ref, guard_pid: nil, required?: true, waiters: waiters} = entry},
         monitor_ref,
         state
       ) do
    Enum.each(waiters, &GenServer.reply(&1, :ok))
    delete_entry(state, owner_pid, entry)
  end

  defp handle_monitored_down(
         {owner_pid, %{monitor_ref: monitor_ref, guard_pid: nil} = entry},
         monitor_ref,
         state
       ) do
    delete_entry(state, owner_pid, entry)
  end

  defp handle_monitored_down(
         {owner_pid, %{guard_monitor_ref: monitor_ref, required?: true, waiters: []} = entry},
         monitor_ref,
         state
       ) do
    Map.put(state, owner_pid, %{entry | result: {:error, :cleanup_guard_failed}})
  end

  defp handle_monitored_down(
         {owner_pid, %{guard_monitor_ref: monitor_ref, required?: true, waiters: waiters} = entry},
         monitor_ref,
         state
       ) do
    Enum.each(waiters, &GenServer.reply(&1, {:error, :cleanup_guard_failed}))
    delete_entry(state, owner_pid, entry)
  end

  defp handle_monitored_down(
         {owner_pid, %{guard_monitor_ref: monitor_ref} = entry},
         monitor_ref,
         state
       ) do
    delete_entry(state, owner_pid, entry)
  end

  defp handle_monitored_down(_monitored_entry, _monitor_ref, state), do: state

  defp new_entry(owner_pid, guard_pid, required?) do
    %{
      guard_pid: guard_pid,
      guard_monitor_ref: if(is_pid(guard_pid), do: Process.monitor(guard_pid)),
      result: nil,
      waiters: [],
      required?: required?,
      monitor_ref: Process.monitor(owner_pid)
    }
  end

  defp attach_guard(entry, guard_pid) do
    %{entry | guard_pid: guard_pid, guard_monitor_ref: Process.monitor(guard_pid)}
  end

  defp detach_guard_monitor(%{guard_monitor_ref: nil} = entry), do: entry

  defp detach_guard_monitor(entry) do
    Process.demonitor(entry.guard_monitor_ref, [:flush])
    %{entry | guard_monitor_ref: nil}
  end

  defp complete_without_waiter(owner_pid, result, %{required?: true} = entry, state) do
    {:reply, :ok, Map.put(state, owner_pid, %{entry | result: result})}
  end

  defp complete_without_waiter(owner_pid, _result, %{required?: false} = entry, state) do
    {:reply, :ok, delete_entry(state, owner_pid, entry)}
  end

  defp delete_entry(state, owner_pid, entry) do
    Process.demonitor(entry.monitor_ref, [:flush])
    detach_guard_monitor(entry)
    Map.delete(state, owner_pid)
  end
end
