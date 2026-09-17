defmodule SymphonyElixir.Linear.Handoff do
  @moduledoc """
  Host-owned Linear state handoff for a session-bound issue.

  The agent supplies only the target state name. Symphony resolves that name inside the issue's
  team and constructs the `issueUpdate` mutation after the Pi completion receipt is durable.
  """

  alias SymphonyElixir.Linear.Client

  @resolve_state_query """
  query SymphonyResolveIssueState($issueId: String!) {
    issue(id: $issueId) {
      id
      team {
        states(first: 100) {
          nodes {
            id
            name
          }
        }
      }
    }
  }
  """

  @transition_query """
  mutation SymphonyTransitionIssue($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
      issue {
        id
        state {
          id
          name
        }
      }
    }
  }
  """

  @spec execute(map(), String.t(), map(), keyword()) :: map()
  def execute(binding, target_state, issue, opts \\ [])
      when is_map(binding) and is_binary(target_state) and is_map(issue) and is_list(opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    tracker_settings = Map.fetch!(binding, :tracker_settings)
    client_opts = [tracker_settings: tracker_settings]

    with {:ok, issue_id} <- issue_id(issue),
         {:ok, resolve_response} <-
           linear_client.(@resolve_state_query, %{"issueId" => issue_id}, client_opts),
         {:ok, state_id} <- resolve_state_id(resolve_response, target_state),
         {:ok, transition_response} <-
           linear_client.(
             @transition_query,
             %{"issueId" => issue_id, "stateId" => state_id},
             client_opts
           ),
         :ok <- validate_transition_response(transition_response, target_state) do
      tool_result(true, %{
        "target_state" => String.trim(target_state),
        "response" => transition_response
      })
    else
      {:error, reason} -> tool_result(false, %{"error" => handoff_error(reason)})
    end
  rescue
    error -> tool_result(false, %{"error" => %{"message" => Exception.message(error)}})
  end

  defp issue_id(issue) do
    case Map.get(issue, :id) || Map.get(issue, "id") do
      id when is_binary(id) ->
        case String.trim(id) do
          "" -> {:error, :missing_bound_issue_id}
          value -> {:ok, value}
        end

      _ ->
        {:error, :missing_bound_issue_id}
    end
  end

  defp resolve_state_id(response, target_state) do
    with :ok <- reject_graphql_errors(response),
         nodes when is_list(nodes) <- get_in(response, ["data", "issue", "team", "states", "nodes"]),
         [state] <- Enum.filter(nodes, &state_name_matches?(&1, target_state)),
         state_id when is_binary(state_id) <- Map.get(state, "id"),
         true <- String.trim(state_id) != "" do
      {:ok, state_id}
    else
      {:error, _reason} = error -> error
      [] -> {:error, {:target_state_not_found, String.trim(target_state)}}
      [_ | _] -> {:error, {:target_state_not_unique, String.trim(target_state)}}
      _ -> {:error, :invalid_state_resolution_response}
    end
  end

  defp state_name_matches?(state, target_state) when is_map(state) do
    normalize_state(Map.get(state, "name")) == normalize_state(target_state)
  end

  defp state_name_matches?(_state, _target_state), do: false

  defp validate_transition_response(response, target_state) do
    with :ok <- reject_graphql_errors(response),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true,
         state_name when is_binary(state_name) <-
           get_in(response, ["data", "issueUpdate", "issue", "state", "name"]),
         true <- normalize_state(state_name) == normalize_state(target_state) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:transition_not_confirmed, String.trim(target_state)}}
    end
  end

  defp reject_graphql_errors(%{"errors" => errors}) when is_list(errors) and errors != [] do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp reject_graphql_errors(_response), do: :ok

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp handoff_error(:missing_bound_issue_id) do
    %{"message" => "Linear handoff requires the session-bound issue ID."}
  end

  defp handoff_error({:target_state_not_found, target_state}) do
    %{"message" => "Linear target state was not found in the bound issue's team.", "target_state" => target_state}
  end

  defp handoff_error({:target_state_not_unique, target_state}) do
    %{"message" => "Linear target state name is not unique in the bound issue's team.", "target_state" => target_state}
  end

  defp handoff_error({:transition_not_confirmed, target_state}) do
    %{"message" => "Linear did not confirm the requested issue state transition.", "target_state" => target_state}
  end

  defp handoff_error({:linear_graphql_errors, errors}) do
    %{"message" => "Linear returned GraphQL errors during handoff.", "errors" => errors}
  end

  defp handoff_error({:linear_api_status, status}) do
    %{"message" => "Linear handoff failed with HTTP #{status}.", "status" => status}
  end

  defp handoff_error({:linear_api_request, _reason}) do
    %{"message" => "Linear handoff failed before receiving a successful response."}
  end

  defp handoff_error(:invalid_state_resolution_response) do
    %{"message" => "Linear returned an invalid workflow-state response during handoff."}
  end

  defp handoff_error(reason) do
    %{"message" => "Linear handoff failed.", "reason" => inspect(reason)}
  end

  defp tool_result(success, payload) do
    output = Jason.encode!(payload, pretty: true)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
