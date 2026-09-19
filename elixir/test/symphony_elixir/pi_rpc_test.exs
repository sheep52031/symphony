defmodule SymphonyElixir.Pi.RpcTest do
  use ExUnit.Case

  alias SymphonyElixir.Pi.Rpc

  test "correlates responses, forwards async events, and keeps stderr separate" do
    test_root = temp_root!()
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    stderr_path = Path.join(test_root, "stderr.log")
    File.mkdir_p!(workspace)

    write_script!(script, """
    #!/bin/sh
    printf '%s\\n' 'warning: fake Pi diagnostic' >&2
    while IFS= read -r line; do
      id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
      case "$line" in
        *'"type":"get_state"'*)
          printf '%s\\n' '{"type":"agent_start"}'
          printf '%s\\n' '{"type":"agent_settled"}'
          printf '{"type":"response","id":"%s","success":true,"data":{"isStreaming":false}}\\r\\n' "$id"
          ;;
        *)
          printf '{"type":"response","id":"%s","success":false,"error":"unexpected"}\\n' "$id"
          ;;
      esac
    done
    """)

    assert {:ok, session} = Rpc.start(workspace, script, stderr_path: stderr_path)

    on_event = fn event -> send(self(), {:pi_event, event}) end

    assert {:ok, %{"success" => true, "data" => %{"isStreaming" => false}}} =
             Rpc.request(session, "get_state", %{},
               on_event: on_event,
               until: fn event -> event["type"] == "agent_settled" end
             )

    assert_receive {:pi_event, %{"type" => "agent_start"}}
    assert_receive {:pi_event, %{"type" => "agent_settled"}}
    assert {:ok, "warning: fake Pi diagnostic\n"} = Rpc.stderr(session)
    assert :ok = Rpc.close(session)

    File.rm_rf!(test_root)
  end

  test "auto-cancels unattended extension UI requests before returning the command response" do
    test_root = temp_root!()
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)

    write_script!(script, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"type":"prompt"'*)
          id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
          printf '%s\\n' '{"type":"extension_ui_request","id":"ui-1","method":"select"}'
          IFS= read -r ui_response
          if printf '%s\\n' "$ui_response" | grep -q '"id":"ui-1"' &&
             printf '%s\\n' "$ui_response" | grep -q '"cancelled":true'; then
            printf '%s\\n' '{"type":"agent_end"}'
            printf '{"type":"response","id":"%s","success":true}\\n' "$id"
          else
            exit 7
          fi
          ;;
      esac
    done
    """)

    assert {:ok, session} = Rpc.start(workspace, script)
    on_event = fn event -> send(self(), {:pi_event, event}) end

    assert {:ok, %{"success" => true}} =
             Rpc.request(session, "prompt", %{"message" => "fixture prompt"}, on_event: on_event)

    assert_receive {:pi_event, %{"type" => "extension_ui_request", "handled" => "cancelled"}}
    assert_receive {:pi_event, %{"type" => "agent_end"}}
    assert :ok = Rpc.close(session)

    File.rm_rf!(test_root)
  end

  test "records fire-and-forget extension UI requests without sending a response" do
    test_root = temp_root!()
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)

    write_script!(script, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"type":"prompt"'*)
          id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
          printf '%s\\n' '{"type":"extension_ui_request","id":"ui-notify","method":"notify","message":"working"}'
          printf '%s\\n' '{"type":"agent_settled"}'
          printf '{"type":"response","id":"%s","success":true}\\n' "$id"
          ;;
        *'"type":"extension_ui_response"'*)
          exit 8
          ;;
      esac
    done
    """)

    assert {:ok, session} = Rpc.start(workspace, script)
    on_event = fn event -> send(self(), {:pi_event, event}) end

    assert {:ok, %{"success" => true}} =
             Rpc.request(session, "prompt", %{"message" => "fixture prompt"},
               on_event: on_event,
               until: fn event -> event["type"] == "agent_settled" end
             )

    assert_receive {:pi_event,
                    %{
                      "type" => "extension_ui_request",
                      "method" => "notify",
                      "handled" => "observed"
                    }}

    assert_receive {:pi_event, %{"type" => "agent_settled"}}
    assert :ok = Rpc.close(session)

    File.rm_rf!(test_root)
  end

  test "rejects unknown extension UI methods instead of guessing response semantics" do
    test_root = temp_root!()
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)

    write_script!(script, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"type":"prompt"'*)
          printf '%s\\n' '{"type":"extension_ui_request","id":"ui-future","method":"futureMethod"}'
          ;;
      esac
    done
    """)

    assert {:ok, session} = Rpc.start(workspace, script)

    assert {:error, {:unsupported_extension_ui_method, "futureMethod"}} =
             Rpc.request(session, "prompt", %{"message" => "fixture prompt"})

    assert :ok = Rpc.close(session)
    File.rm_rf!(test_root)
  end

  test "returns timeout and then permits a graceful abort request" do
    test_root = temp_root!()
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)

    write_script!(script, """
    #!/bin/sh
    blocker_pid=""
    while IFS= read -r line; do
      case "$line" in
        *'"type":"prompt"'*)
          sleep 30 &
          blocker_pid=$!
          ;;
        *'"type":"abort"'*)
          if [ -n "$blocker_pid" ]; then kill "$blocker_pid" 2>/dev/null || true; fi
          id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":"\\([^\"]*\\)".*/\\1/p')
          printf '{"type":"response","id":"%s","success":true}\\n' "$id"
          ;;
      esac
    done
    """)

    assert {:ok, session} = Rpc.start(workspace, script)

    assert {:error, :timeout} = Rpc.request(session, "prompt", %{"message" => "hang"}, timeout_ms: 30)
    assert {:ok, %{"success" => true}} = Rpc.request(session, "abort", %{}, timeout_ms: 1_000)
    assert :ok = Rpc.close(session)

    File.rm_rf!(test_root)
  end

  test "uses an absolute deadline even while valid protocol chatter continues" do
    test_root = temp_root!()
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)

    write_script!(script, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"type":"prompt"'*)
          i=0
          while [ "$i" -lt 50 ]; do
            printf '%s\\n' '{"type":"heartbeat"}'
            sleep 0.01
            i=$((i + 1))
          done
          ;;
      esac
    done
    """)

    assert {:ok, session} = Rpc.start(workspace, script)
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             Rpc.request(session, "prompt", %{"message" => "chatter"}, timeout_ms: 60)

    assert System.monotonic_time(:millisecond) - started_at < 300
    assert :ok = Rpc.close(session)
    File.rm_rf!(test_root)
  end

  test "classifies a bounded first-event timeout" do
    test_root = temp_root!()
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    File.mkdir_p!(workspace)

    write_script!(script, """
    #!/bin/sh
    while IFS= read -r _line; do sleep 30; done
    """)

    assert {:ok, session} = Rpc.start(workspace, script)

    assert {:error, {:timeout, :first_event}} =
             Rpc.request(session, "prompt", %{"message" => "silent"},
               timeout_ms: 1_000,
               first_event_timeout_ms: 40
             )

    assert :ok = Rpc.close(session)
    File.rm_rf!(test_root)
  end

  test "close terminates the dedicated Pi process group" do
    test_root = temp_root!()
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    child_pid_path = Path.join(test_root, "child.pid")
    File.mkdir_p!(workspace)

    write_script!(script, """
    #!/bin/sh
    sleep 30 &
    child_pid=$!
    printf '%s' "$child_pid" > #{inspect(child_pid_path)}
    while IFS= read -r _line; do :; done
    """)

    assert {:ok, session} = Rpc.start(workspace, script)
    assert is_integer(session.process_group_id)
    child_pid = eventually_read_pid!(child_pid_path)
    assert process_alive?(child_pid)
    assert :ok = Rpc.close(session)
    refute eventually_process_alive?(child_pid)
    File.rm_rf!(test_root)
  end

  test "owner death triggers bounded orphan process-group cleanup" do
    test_root = temp_root!()
    workspace = Path.join(test_root, "workspace")
    script = Path.join(test_root, "fake-pi")
    child_pid_path = Path.join(test_root, "child.pid")
    File.mkdir_p!(workspace)

    write_script!(script, """
    #!/bin/sh
    sleep 30 &
    printf '%s' "$!" > #{inspect(child_pid_path)}
    while IFS= read -r _line; do :; done
    """)

    test_pid = self()

    owner_pid =
      spawn(fn ->
        {:ok, session} = Rpc.start(workspace, script)
        send(test_pid, {:rpc_session, session})
        Process.sleep(:infinity)
      end)

    assert_receive {:rpc_session, session}, 1_000
    child_pid = eventually_read_pid!(child_pid_path)
    assert process_alive?(session.os_pid)
    assert process_alive?(child_pid)
    Process.exit(owner_pid, :kill)
    refute eventually_process_alive?(session.os_pid)
    refute eventually_process_alive?(child_pid)
    File.rm_rf!(test_root)
  end

  defp temp_root! do
    root = Path.join(System.tmp_dir!(), "symphony-pi-rpc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end

  defp write_script!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp eventually_read_pid!(path, attempts \\ 100)

  defp eventually_read_pid!(_path, 0), do: flunk("timed out waiting for child pid")

  defp eventually_read_pid!(path, attempts) do
    case File.read(path) do
      {:ok, value} ->
        String.trim(value) |> String.to_integer()

      _ ->
        Process.sleep(10)
        eventually_read_pid!(path, attempts - 1)
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
