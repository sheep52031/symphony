defmodule SymphonyElixir.Pi.TrackerBridgeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pi.TrackerBridge

  test "uses a per-session loopback capability and keeps issue context host-side" do
    test_root = temp_root!()
    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    parent = self()

    executor = fn _binding, tool, arguments, issue ->
      send(parent, {:executed, tool, arguments, issue})
      tool_result(true, %{"data" => %{"ok" => true}})
    end

    assert {:ok, bridge} =
             TrackerBridge.start(workspace,
               binding: fixture_binding(),
               tool_executor: executor
             )

    capability = bridge_environment(bridge, "SYMPHONY_PI_TRACKER_BRIDGE_CAPABILITY")
    assert String.starts_with?(bridge.url, "http://127.0.0.1:")
    assert File.regular?(bridge.extension_path)
    assert Bitwise.band(File.stat!(bridge.extension_path).mode, 0o777) == 0o600
    extension = File.read!(bridge.extension_path)
    refute extension =~ capability
    assert extension =~ "delete process.env.SYMPHONY_PI_TRACKER_BRIDGE_CAPABILITY"
    assert extension =~ "delete process.env.SYMPHONY_PI_TRACKER_BRIDGE_URL"
    assert extension =~ "delete process.env.SYMPHONY_PI_TRACKER_BRIDGE_TOOL_SPECS"
    assert bridge.tool_names == ["linear_graphql", "symphony_handoff"]

    encoded_specs = bridge_environment(bridge, "SYMPHONY_PI_TRACKER_BRIDGE_TOOL_SPECS")
    specs = encoded_specs |> Base.url_decode64!(padding: false) |> Jason.decode!()
    handoff_spec = Enum.find(specs, &(&1["name"] == "symphony_handoff"))
    assert handoff_spec["inputSchema"]["required"] == ["target_state"]
    assert Map.keys(handoff_spec["inputSchema"]["properties"]) == ["target_state"]

    issue = %{id: "issue-bridge", identifier: "JARVIS-BRIDGE", title: "Bridge scope"}
    assert :ok = TrackerBridge.bind_issue(bridge, issue)

    assert %{status: 401, body: %{"error" => %{"code" => "unauthorized"}}} =
             post_tool(bridge.url, "wrong-capability", "linear_graphql", %{
               "query" => "query { viewer { id } }"
             })

    assert %{status: 400, body: %{"error" => %{"code" => "invalid_request"}}} =
             Req.post!(bridge.url,
               headers: authorization_header(capability),
               json: %{
                 "tool" => "linear_graphql",
                 "arguments" => %{"query" => "query { viewer { id } }"},
                 "issue_id" => "different-issue"
               }
             )

    assert %{status: 405, body: %{"error" => %{"code" => "method_not_allowed"}}} =
             Req.get!(bridge.url, headers: authorization_header(capability))

    oversized_body =
      Jason.encode!(%{
        "tool" => "linear_graphql",
        "arguments" => %{"query" => String.duplicate("x", 1_100_000)}
      })

    assert %{status: 413, body: %{"error" => %{"code" => "request_too_large"}}} =
             Req.post!(bridge.url,
               headers: [
                 {"authorization", "Bearer #{capability}"},
                 {"content-type", "application/json"}
               ],
               body: oversized_body
             )

    response =
      post_tool(bridge.url, capability, "linear_graphql", %{
        "query" => "query { viewer { id } }"
      })

    assert response.status == 200
    assert response.body["success"]

    assert_receive {:executed, "linear_graphql", %{"query" => "query { viewer { id } }"}, ^issue}
    assert :ok = TrackerBridge.stop(bridge)
    File.rm_rf!(test_root)
  end

  test "blocks direct Linear state transitions and commits a staged handoff only when asked" do
    test_root = temp_root!()
    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    parent = self()

    executor = fn _binding, target_state, issue ->
      send(parent, {:handoff_executed, target_state, issue})
      tool_result(true, %{"data" => %{"issueUpdate" => %{"success" => true}}})
    end

    assert {:ok, bridge} =
             TrackerBridge.start(workspace,
               binding: fixture_binding(),
               handoff_executor: executor
             )

    capability = bridge_environment(bridge, "SYMPHONY_PI_TRACKER_BRIDGE_CAPABILITY")
    issue = %{id: "issue-handoff", identifier: "JARVIS-HANDOFF", title: "Handoff order"}
    assert :ok = TrackerBridge.bind_issue(bridge, issue)

    transition_arguments = %{
      "query" => "mutation Move($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }",
      "variables" => %{
        "id" => issue.id,
        "input" => %{"stateId" => "human-review-state"}
      }
    }

    direct = post_tool(bridge.url, capability, "linear_graphql", transition_arguments)
    assert direct.status == 200
    refute direct.body["success"]
    assert direct.body["output"] =~ "symphony_handoff"
    refute_receive {:handoff_executed, _, _}

    unsafe_payload =
      post_tool(bridge.url, capability, "symphony_handoff", %{
        "target_state" => "Human Review",
        "tool" => "linear_graphql",
        "arguments" => transition_arguments
      })

    refute unsafe_payload.body["success"]
    assert unsafe_payload.body["output"] =~ "constructs the provider mutation host-side"

    active_target =
      post_tool(bridge.url, capability, "symphony_handoff", %{
        "target_state" => "In Progress"
      })

    refute active_target.body["success"]
    assert active_target.body["output"] =~ "must not be an active tracker state"

    staged =
      post_tool(bridge.url, capability, "symphony_handoff", %{
        "target_state" => "Human Review"
      })

    assert staged.body["success"]
    refute_receive {:handoff_executed, _, _}

    assert {:ok,
            %{
              request: %{target_state: "Human Review"},
              result: %{"success" => true}
            }} = TrackerBridge.commit_handoff(bridge)

    assert_receive {:handoff_executed, "Human Review", ^issue}

    assert {:ok, %{result: %{"success" => true}}} = TrackerBridge.commit_handoff(bridge)
    refute_receive {:handoff_executed, _, _}

    assert :ok = TrackerBridge.stop(bridge)
    File.rm_rf!(test_root)
  end

  test "does not advertise a handoff for providers without a host-owned implementation" do
    test_root = temp_root!()
    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)

    binding = put_in(fixture_binding(), [:tracker_settings, :kind], "github")
    assert {:ok, bridge} = TrackerBridge.start(workspace, binding: binding)
    assert bridge.tool_names == ["linear_graphql"]

    capability = bridge_environment(bridge, "SYMPHONY_PI_TRACKER_BRIDGE_CAPABILITY")
    assert :ok = TrackerBridge.bind_issue(bridge, %{id: "issue-no-handoff", identifier: "NO-HANDOFF"})

    response =
      post_tool(bridge.url, capability, "symphony_handoff", %{"target_state" => "Human Review"})

    refute response.body["success"]
    assert response.body["output"] =~ "not implemented"
    assert :ok = TrackerBridge.stop(bridge)
    File.rm_rf!(test_root)
  end

  test "rejects issue rebinding and unsupported tool names without invoking the adapter" do
    test_root = temp_root!()
    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    parent = self()

    executor = fn _binding, tool, arguments, issue ->
      send(parent, {:unexpected_execution, tool, arguments, issue})
      tool_result(true, %{})
    end

    assert {:ok, bridge} =
             TrackerBridge.start(workspace,
               binding: fixture_binding(),
               tool_executor: executor
             )

    capability = bridge_environment(bridge, "SYMPHONY_PI_TRACKER_BRIDGE_CAPABILITY")
    assert :ok = TrackerBridge.bind_issue(bridge, %{id: "issue-one", identifier: "ONE"})

    assert {:error, {:tracker_bridge_issue_mismatch, "issue-one", "issue-two"}} =
             TrackerBridge.bind_issue(bridge, %{id: "issue-two", identifier: "TWO"})

    unsupported = post_tool(bridge.url, capability, "not_advertised", %{})
    refute unsupported.body["success"]
    assert unsupported.body["output"] =~ "Unsupported tracker tool"
    refute_receive {:unexpected_execution, _, _, _}

    assert :ok = TrackerBridge.stop(bridge)
    File.rm_rf!(test_root)
  end

  defp fixture_binding do
    %{
      adapter: :fixture,
      tracker_settings: %{
        kind: "linear",
        active_states: ["Todo", "In Progress"],
        terminal_states: ["Done", "Cancelled"]
      },
      tool_specs: [
        %{
          "name" => "linear_graphql",
          "description" => "Fixture Linear GraphQL tool",
          "inputSchema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["query"],
            "properties" => %{"query" => %{"type" => "string"}}
          }
        }
      ],
      secret_environment_names: ["LINEAR_API_KEY"]
    }
  end

  defp post_tool(url, capability, tool, arguments) do
    Req.post!(url,
      headers: authorization_header(capability),
      json: %{"tool" => tool, "arguments" => arguments}
    )
  end

  defp authorization_header(capability), do: [{"authorization", "Bearer #{capability}"}]

  defp bridge_environment(bridge, name) do
    bridge.environment
    |> Enum.find_value(fn {key, value} ->
      if to_string(key) == name, do: to_string(value)
    end)
  end

  defp tool_result(success, payload) do
    output = Jason.encode!(payload)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp temp_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-pi-tracker-bridge-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    root
  end
end
