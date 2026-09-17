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

  defp temp_root! do
    root = Path.join(System.tmp_dir!(), "symphony-pi-rpc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end

  defp write_script!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end
