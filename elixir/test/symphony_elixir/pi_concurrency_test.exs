defmodule SymphonyElixir.Pi.ConcurrencyTest do
  use SymphonyElixir.TestSupport

  test "one controller admits three overlapping exact-routed Pi workers" do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-pi-three-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}")
    workspace_root = Path.join(root, "workspaces")
    barrier_root = Path.join(root, "barrier")
    script = Path.join(root, "fake-pi-barrier")
    runtime_name = Module.concat(__MODULE__, "Runtime#{suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "Tasks#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "Orchestrator#{suffix}")
    previous_secret = System.get_env("PI_BARRIER_SECRET")

    File.mkdir_p!(barrier_root)
    write_barrier_pi!(script)
    System.put_env("PI_BARRIER_SECRET", "must-not-reach-fake-pi")

    issues =
      for number <- 1..4 do
        %Issue{
          id: "pi-three-#{number}",
          identifier: "PI-#{number}",
          title: "Pi barrier #{number}",
          state: "Todo",
          url: "https://example.invalid/PI-#{number}",
          dispatchable: true
        }
      end

    on_exit(fn ->
      File.touch(Path.join(barrier_root, "release"))

      if Process.whereis(task_supervisor_name) do
        eventually_value(fn ->
          if Task.Supervisor.children(task_supervisor_name) == [], do: true
        end)
      end

      if pid = Process.whereis(runtime_name), do: GenServer.stop(pid)
      restore_env("PI_BARRIER_SECRET", previous_secret)
      restart_default_runtime!()
      File.rm_rf(root)
    end)

    stop_default_runtime!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      poll_interval_ms: 30_000,
      agent_backend: "pi",
      pi_command: "#{script} #{barrier_root}",
      max_concurrent_agents: 3,
      max_concurrent_agents_by_state: %{"Todo" => 3},
      issue_backends: Map.new(1..4, fn number -> {"PI-#{number}", "pi"} end),
      max_turns: 1
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

    assert {:ok, runtime_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_name,
               task_supervisor_name: task_supervisor_name,
               orchestrator_name: orchestrator_name
             )

    Process.unlink(runtime_pid)

    records =
      eventually_value(fn ->
        case barrier_records(barrier_root) do
          records when length(records) == 3 -> records
          _ -> nil
        end
      end)

    assert length(records) == 3

    # get_state writes the barrier before AgentRunner publishes its backend proof.
    # A fixed 100ms sleep races that publication when process startup is slower.
    snapshot =
      eventually_value(fn ->
        case Orchestrator.snapshot(orchestrator_name, 1_000) do
          %{running: running} = snapshot when length(running) == 3 ->
            if Enum.all?(running, &(&1.backend == :pi)), do: snapshot

          _ ->
            nil
        end
      end)

    assert snapshot
    assert length(snapshot.running) == 3
    assert length(barrier_records(barrier_root)) == 3
    assert length(Task.Supervisor.children(task_supervisor_name)) == 3

    assert records |> Enum.map(& &1["pid"]) |> Enum.uniq() |> length() == 3
    assert records |> Enum.map(& &1["session_id"]) |> Enum.uniq() |> length() == 3
    assert records |> Enum.map(& &1["workspace"]) |> Enum.uniq() |> length() == 3

    started_identifiers = MapSet.new(records, & &1["identifier"])
    assert MapSet.size(started_identifiers) == 3
    assert MapSet.size(MapSet.difference(MapSet.new(["PI-1", "PI-2", "PI-3", "PI-4"]), started_identifiers)) == 1
    refute File.exists?(Path.join(barrier_root, "secret-leak"))

    terminal_issues = Enum.map(issues, &%{&1 | state: "Done"})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, terminal_issues)
    File.touch!(Path.join(barrier_root, "release"))

    assert eventually_value(fn ->
             if Task.Supervisor.children(task_supervisor_name) == [], do: true
           end)

    assert eventually_value(fn ->
             case Orchestrator.snapshot(orchestrator_name, 1_000) do
               %{running: []} -> true
               _ -> nil
             end
           end)

    for %{"pid" => pid} <- records do
      refute eventually_process_alive?(pid)
    end
  end

  defp write_barrier_pi!(path) do
    File.write!(path, """
    #!/bin/sh
    barrier=$1
    if [ -n "${PI_BARRIER_SECRET:-}" ] || [ -n "${LINEAR_API_KEY:-}" ]; then
      : > "$barrier/secret-leak"
      exit 12
    fi
    identifier=${PWD##*/}
    session_id="session-$identifier"
    while IFS= read -r line; do
      id=${line#*'"id":"'}
      id=${id%%'"'*}
      case "$line" in
        *'"type":"get_state"'*)
          printf '{"identifier":"%s","pid":%s,"session_id":"%s","workspace":"%s"}\\n' "$identifier" "$$" "$session_id" "$PWD" > "$barrier/$identifier.json"
          printf '{"type":"response","id":"%s","success":true,"data":{"sessionId":"%s","model":{"id":"fake-pi"}}}\\n' "$id" "$session_id"
          ;;
        *'"type":"set_session_name"'*) printf '{"type":"response","id":"%s","success":true}\\n' "$id" ;;
        *'"type":"prompt"'*)
          while [ ! -f "$barrier/release" ]; do sleep 0.01; done
          printf '%s\\n' '{"type":"agent_start"}'
          printf '%s\\n' '{"type":"agent_settled"}'
          printf '{"type":"response","id":"%s","success":true}\\n' "$id"
          ;;
        *'"type":"get_last_assistant_text"'*) printf '{"type":"response","id":"%s","success":true,"data":{"text":"done"}}\\n' "$id" ;;
        *'"type":"get_session_stats"'*) printf '{"type":"response","id":"%s","success":true,"data":{"tokens":{"total":1}}}\\n' "$id" ;;
        *'"type":"abort"'*) printf '{"type":"response","id":"%s","success":true}\\n' "$id" ;;
        *) exit 9 ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp barrier_records(root) do
    root
    |> Path.join("PI-*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      with {:ok, contents} <- File.read(path),
           {:ok, record} <- Jason.decode(contents) do
        [record]
      else
        _ -> []
      end
    end)
  end

  defp stop_default_runtime! do
    if Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) do
      :ok =
        Supervisor.terminate_child(
          SymphonyElixir.Supervisor,
          SymphonyElixir.AgentRuntimeSupervisor
        )
    end
  end

  defp restart_default_runtime! do
    if is_nil(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)) do
      case Supervisor.restart_child(
             SymphonyElixir.Supervisor,
             SymphonyElixir.AgentRuntimeSupervisor
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  defp eventually_value(fun) do
    await_value(fun, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_value(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await_value(fun, deadline)
        end

      value ->
        value
    end
  end

  defp eventually_process_alive?(pid, attempts \\ 100)
  defp eventually_process_alive?(pid, 0), do: process_alive?(pid)

  defp eventually_process_alive?(pid, attempts) do
    if process_alive?(pid) do
      Process.sleep(10)
      eventually_process_alive?(pid, attempts - 1)
    else
      false
    end
  end

  defp process_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end
end
