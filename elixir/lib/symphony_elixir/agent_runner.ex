defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with the configured execution backend.
  """

  require Logger
  alias SymphonyElixir.{AgentBackend, Config, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    if Config.issue_identifier_allowed?(issue.identifier) do
      run_allowed_issue(issue, codex_update_recipient, opts)
    else
      Logger.warning("Skipping agent run; issue identifier is not allowed: #{issue_context(issue)}")
      :ok
    end
  end

  defp run_allowed_issue(issue, codex_update_recipient, opts) do
    with {:ok, backend_name} <- selected_backend_name(issue, opts),
         {:ok, worker_host} <- selected_worker_host(backend_name, opts) do
      Logger.info("Starting agent run for #{issue_context(issue)} backend=#{backend_name} worker_host=#{worker_host_for_log(worker_host)}")

      case run_on_worker_host(issue, codex_update_recipient, Keyword.put(opts, :backend, backend_name), worker_host) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
          raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
      end
    else
      {:error, reason} ->
        Logger.error("Refusing incompatible agent route for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Refusing incompatible agent route for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp agent_message_handler(recipient, issue, backend_name) do
    fn message ->
      case AgentBackend.validate_update(message) do
        :ok ->
          send_codex_update(recipient, issue, Map.put_new(message, :backend, backend_name))

        {:error, reason} ->
          throw({:backend_contract_violation, backend_name, reason})
      end
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    with {:ok, backend_name, backend} <- resolve_backend(opts),
         {:ok, session} <-
           backend.start_session(workspace, worker_host: worker_host, issue: issue)
           |> AgentBackend.validate_start_result() do
      try do
        do_run_agent_turns(
          %{
            backend: backend,
            backend_name: backend_name,
            app_session: session,
            workspace: workspace,
            issue: issue,
            recipient: codex_update_recipient,
            opts: opts,
            issue_state_fetcher: issue_state_fetcher,
            max_turns: max_turns
          },
          1
        )
      after
        case backend.stop_session(session) |> AgentBackend.validate_stop_result() do
          :ok -> :ok
          {:error, reason} -> raise RuntimeError, "Backend stop contract failed: #{inspect(reason)}"
        end
      end
    end
  end

  defp do_run_agent_turns(
         %{
           backend: backend,
           backend_name: backend_name,
           app_session: app_session,
           workspace: workspace,
           issue: issue,
           recipient: codex_update_recipient,
           opts: opts,
           issue_state_fetcher: issue_state_fetcher,
           max_turns: max_turns
         } = context,
         turn_number
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           run_backend_turn(
             backend,
             backend_name,
             app_session,
             prompt,
             issue,
             on_message: agent_message_handler(codex_update_recipient, issue, backend_name),
             attempt: Keyword.get(opts, :attempt),
             turn_number: turn_number
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session.session_id} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_agent_turns(
            %{context | issue: refreshed_issue},
            turn_number + 1
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_backend_turn(backend, backend_name, session, prompt, issue, opts) do
    result = backend.run_turn(session, prompt, issue, opts)

    case result do
      {:ok, turn_result} ->
        case AgentBackend.validate_turn_result(turn_result) do
          :ok -> {:ok, turn_result}
          {:error, reason} -> {:error, {:backend_contract_violation, backend_name, reason}}
        end

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:backend_contract_violation, backend_name, {:invalid_backend_turn_result, other}}}
    end
  catch
    :throw, {:backend_contract_violation, ^backend_name, reason} ->
      {:error, {:backend_contract_violation, backend_name, reason}}
  end

  defp resolve_backend(opts) do
    backend_name = Keyword.get(opts, :backend, Config.settings!().agent.backend)
    AgentBackend.resolve(backend_name)
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) and
             Config.issue_identifier_allowed?(refreshed_issue.identifier) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_backend_name(issue, opts) do
    with {:ok, configured_backend} <- Config.issue_backend(issue.identifier),
         {:ok, requested_backend} <- requested_backend_name(opts, configured_backend) do
      if requested_backend == configured_backend do
        {:ok, configured_backend}
      else
        {:error, {:backend_route_mismatch, configured_backend, requested_backend}}
      end
    end
  end

  defp requested_backend_name(opts, configured_backend) do
    case Keyword.fetch(opts, :backend) do
      :error ->
        {:ok, configured_backend}

      {:ok, backend} ->
        case AgentBackend.resolve(backend) do
          {:ok, backend_id, _module} -> {:ok, Atom.to_string(backend_id)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp selected_worker_host(backend_name, opts) do
    result =
      case Keyword.fetch(opts, :worker_host) do
        {:ok, worker_host} ->
          if Config.worker_host_binding_current?(backend_name, worker_host) do
            {:ok, worker_host}
          else
            {:error, {:incompatible_or_unconfigured_worker_host, backend_name, worker_host}}
          end

        :error ->
          Config.default_worker_host(backend_name)
      end

    case result do
      {:ok, worker_host} ->
        if AgentBackend.worker_host_compatible?(backend_name, worker_host) do
          {:ok, worker_host}
        else
          {:error, {:incompatible_worker_host, backend_name, worker_host}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
