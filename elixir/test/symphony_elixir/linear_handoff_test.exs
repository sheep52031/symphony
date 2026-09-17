defmodule SymphonyElixir.Linear.HandoffTest do
  use ExUnit.Case

  alias SymphonyElixir.Linear.Handoff
  alias SymphonyElixir.Tracker.Issue

  test "resolves the target state inside the bound issue team and constructs the mutation host-side" do
    parent = self()
    settings = %{kind: "linear", api_key: "host-only-token"}
    binding = %{tracker_settings: settings}
    issue = %Issue{id: "issue-123", identifier: "JARVIS-123"}

    client = fn query, variables, opts ->
      send(parent, {:linear_handoff_call, query, variables, opts})

      if query =~ "SymphonyResolveIssueState" do
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{
                 "states" => %{
                   "nodes" => [
                     %{"id" => "state-progress", "name" => "In Progress"},
                     %{"id" => "state-review", "name" => "Human Review"}
                   ]
                 }
               }
             }
           }
         }}
      else
        {:ok,
         %{
           "data" => %{
             "issueUpdate" => %{
               "success" => true,
               "issue" => %{
                 "id" => "issue-123",
                 "state" => %{"id" => "state-review", "name" => "Human Review"}
               }
             }
           }
         }}
      end
    end

    result =
      Handoff.execute(binding, " Human Review ", issue, linear_client: client)

    assert result["success"]

    assert_receive {:linear_handoff_call, resolve_query, %{"issueId" => "issue-123"}, [tracker_settings: ^settings]}

    assert resolve_query =~ "states(first: 100)"

    assert_receive {:linear_handoff_call, transition_query, %{"issueId" => "issue-123", "stateId" => "state-review"}, [tracker_settings: ^settings]}

    assert transition_query =~ "issueUpdate"
    refute transition_query =~ "Human Review"
  end

  test "fails without mutating when the requested team state is missing or ambiguous" do
    issue = %Issue{id: "issue-456", identifier: "JARVIS-456"}
    binding = %{tracker_settings: %{kind: "linear"}}

    for nodes <- [
          [%{"id" => "todo", "name" => "Todo"}],
          [
            %{"id" => "review-1", "name" => "Human Review"},
            %{"id" => "review-2", "name" => "human review"}
          ]
        ] do
      counter = :counters.new(1, [])

      client = fn _query, _variables, _opts ->
        :counters.add(counter, 1, 1)
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => nodes}}}}}}
      end

      result = Handoff.execute(binding, "Human Review", issue, linear_client: client)
      refute result["success"]
      assert :counters.get(counter, 1) == 1
    end
  end

  test "fails when Linear does not confirm the exact requested state" do
    issue = %Issue{id: "issue-789", identifier: "JARVIS-789"}
    binding = %{tracker_settings: %{kind: "linear"}}

    client = fn query, _variables, _opts ->
      if query =~ "SymphonyResolveIssueState" do
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{
                 "states" => %{
                   "nodes" => [%{"id" => "state-review", "name" => "Human Review"}]
                 }
               }
             }
           }
         }}
      else
        {:ok,
         %{
           "data" => %{
             "issueUpdate" => %{
               "success" => true,
               "issue" => %{"state" => %{"id" => "done", "name" => "Done"}}
             }
           }
         }}
      end
    end

    result = Handoff.execute(binding, "Human Review", issue, linear_client: client)
    refute result["success"]
    assert result["output"] =~ "did not confirm"
  end
end
