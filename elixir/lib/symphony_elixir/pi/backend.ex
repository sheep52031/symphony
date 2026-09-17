defmodule SymphonyElixir.Pi.Backend do
  @moduledoc """
  Pi RPC execution backend.

  This adapter is intentionally local-only during the first integration slice. It keeps Pi's
  native session and event model behind the execution boundary instead of making the orchestrator
  speak a Codex-shaped protocol.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.{Config, Pi.Rpc, Pi.TrackerBridge}

  @receipt_schema_version 1
  @stderr_tail_bytes 8_192

  @type session :: %{
          rpc: Rpc.session(),
          session_id: String.t() | nil,
          session_state: map(),
          tracker_bridge: TrackerBridge.session() | nil
        }

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) ->
        {:error, {:unsupported_backend_worker_host, :pi, host}}

      _ ->
        start_local_session(workspace, opts)
    end
  end

  defp start_local_session(workspace, opts) do
    config = Config.settings!()
    stderr_path = Path.join(workspace, ".symphony/pi-rpc.stderr.log")
    bridge_opts = Keyword.get(opts, :tracker_bridge_opts, [])

    case TrackerBridge.start(workspace, bridge_opts) do
      {:ok, tracker_bridge} ->
        rpc_opts = [
          stderr_path: stderr_path,
          env: tracker_secret_port_env(config) ++ tracker_bridge_environment(tracker_bridge)
        ]

        case Rpc.start(workspace, pi_command(config.pi.command, tracker_bridge), rpc_opts) do
          {:ok, rpc} ->
            initialize_session(rpc, config, tracker_bridge)

          {:error, _reason} = error ->
            TrackerBridge.stop(tracker_bridge)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp initialize_session(rpc, config, tracker_bridge) do
    case Rpc.request(rpc, "get_state", %{}, timeout_ms: config.codex.read_timeout_ms) do
      {:ok, response} ->
        case session_id_from_state(response) do
          session_id when is_binary(session_id) ->
            {:ok,
             %{
               rpc: rpc,
               session_id: session_id,
               session_state: Map.get(response, "data", %{}),
               tracker_bridge: tracker_bridge
             }}

          _ ->
            Rpc.close(rpc)
            TrackerBridge.stop(tracker_bridge)
            {:error, {:invalid_session_state, :missing_session_id}}
        end

      {:error, reason} ->
        Rpc.close(rpc)
        TrackerBridge.stop(tracker_bridge)
        {:error, reason}
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          rpc: rpc,
          session_id: session_id,
          session_state: session_state,
          tracker_bridge: tracker_bridge
        },
        prompt,
        issue,
        opts
      )
      when is_binary(prompt) and is_map(issue) do
    config = Config.settings!()
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    timeout_ms = Keyword.get(opts, :timeout_ms, config.codex.turn_timeout_ms)
    session_name = "#{issue.identifier}: #{issue.title}"
    proof = session_proof(rpc, session_id, session_state, session_name)

    context = %{
      config: config,
      issue: issue,
      on_event: fn event -> emit_event(on_message, event) end,
      on_message: on_message,
      opts: opts,
      proof: proof,
      rpc: rpc,
      started_at: DateTime.utc_now(),
      tracker_bridge: tracker_bridge
    }

    case TrackerBridge.bind_issue(tracker_bridge, issue) do
      :ok ->
        on_message.(
          proof_update(
            %{
              event: :session_started,
              payload: proof,
              session_id: session_id,
              attempt_receipt_index: normalized_receipt_index(opts[:attempt], 0),
              turn_receipt_index: normalized_receipt_index(opts[:turn_number], 1),
              timestamp: context.started_at,
              backend: :pi
            },
            proof
          )
        )

        case Rpc.request(
               rpc,
               "set_session_name",
               %{"name" => session_name},
               timeout_ms: config.codex.read_timeout_ms,
               on_event: context.on_event
             ) do
          {:ok, _} -> run_prompt_turn(context, prompt, timeout_ms)
          {:error, reason} -> fail_turn(context, reason, :set_session_name_failed)
        end

      {:error, reason} ->
        fail_turn(context, reason, :tracker_bridge_bind_failed)
    end
  end

  defp run_prompt_turn(context, prompt, timeout_ms) do
    case Rpc.request(
           context.rpc,
           "prompt",
           %{"message" => prompt},
           timeout_ms: timeout_ms,
           on_event: context.on_event,
           until: &settled_event?/1
         ) do
      {:ok, prompt_response} -> complete_turn(context, prompt_response)
      {:error, :timeout} -> abort_after_timeout(context)
      {:error, reason} -> fail_turn(context, reason, :prompt_failed)
    end
  end

  defp complete_turn(context, prompt_response) do
    with {:ok, assistant_response} <-
           Rpc.request(
             context.rpc,
             "get_last_assistant_text",
             %{},
             timeout_ms: context.config.codex.read_timeout_ms,
             on_event: context.on_event
           ),
         {:ok, stats_response} <-
           Rpc.request(
             context.rpc,
             "get_session_stats",
             %{},
             timeout_ms: context.config.codex.read_timeout_ms,
             on_event: context.on_event
           ) do
      turn = %{
        result: assistant_response,
        session_id: context.proof.session_id,
        turn_id: Map.get(prompt_response, "id"),
        stats: stats_response,
        stderr_path: context.rpc.stderr_path,
        backend: :pi,
        model: context.proof.model,
        thinking_level: context.proof.thinking_level,
        backend_process_pid: context.proof.backend_process_pid
      }

      receipt =
        build_receipt(context, "completed", %{
          "assistant_text" => get_in(assistant_response, ["data", "text"]),
          "rpc_request_id" => turn.turn_id,
          "stats" => Map.get(stats_response, "data")
        })

      case persist_receipt(context, receipt) do
        {:ok, receipt_path} ->
          emit_usage(context.on_message, stats_response)

          context.on_message.(
            proof_update(
              %{
                event: :turn_completed,
                payload: Map.put(receipt, "receipt_path", receipt_path),
                session_id: context.proof.session_id,
                receipt_path: receipt_path,
                timestamp: DateTime.utc_now(),
                backend: :pi
              },
              context.proof
            )
          )

          complete_handoff(context, Map.put(turn, :receipt_path, receipt_path), receipt_path)

        {:error, reason} ->
          fail_turn_without_receipt(context, reason)
      end
    else
      {:error, reason} -> fail_turn(context, reason, :completion_read_failed)
    end
  end

  defp complete_handoff(context, turn, completion_receipt_path) do
    case TrackerBridge.commit_handoff(context.tracker_bridge) do
      {:ok, nil} ->
        {:ok, turn}

      {:ok, handoff} ->
        receipt =
          build_receipt(context, "handoff_completed", %{
            "completion_receipt_path" => completion_receipt_path,
            "handoff" => handoff
          })

        case persist_receipt(context, receipt) do
          {:ok, receipt_path} ->
            context.on_message.(
              proof_update(
                %{
                  event: :handoff_completed,
                  payload: Map.put(receipt, "receipt_path", receipt_path),
                  session_id: context.proof.session_id,
                  receipt_path: receipt_path,
                  timestamp: DateTime.utc_now(),
                  backend: :pi
                },
                context.proof
              )
            )

            {:ok,
             turn
             |> Map.put(:completion_receipt_path, completion_receipt_path)
             |> Map.put(:handoff_receipt_path, receipt_path)}

          {:error, reason} ->
            fail_turn_without_receipt(context, reason)
        end

      {:error, reason} ->
        fail_handoff(context, reason, completion_receipt_path)
    end
  end

  defp fail_handoff(context, reason, completion_receipt_path) do
    {handoff, tracker_result} =
      case reason do
        {:tracker_handoff_failed, staged_handoff, result} -> {staged_handoff, result}
        _ -> {nil, nil}
      end

    receipt =
      build_receipt(context, "handoff_failed", %{
        "completion_receipt_path" => completion_receipt_path,
        "handoff" => handoff,
        "tracker_result" => tracker_result,
        "reason" => inspect(reason)
      })

    case persist_receipt(context, receipt) do
      {:ok, receipt_path} ->
        context.on_message.(
          proof_update(
            %{
              event: :handoff_failed,
              payload: Map.put(receipt, "receipt_path", receipt_path),
              session_id: context.proof.session_id,
              receipt_path: receipt_path,
              timestamp: DateTime.utc_now(),
              backend: :pi
            },
            context.proof
          )
        )

        {:error, reason}

      {:error, receipt_reason} ->
        fail_turn_without_receipt(context, receipt_reason)
    end
  end

  defp abort_after_timeout(context) do
    outcome =
      case Rpc.request(
             context.rpc,
             "abort",
             %{},
             timeout_ms: context.config.codex.read_timeout_ms,
             on_event: context.on_event
           ) do
        {:ok, _response} -> :acknowledged
        {:error, reason} -> {:failed, reason}
      end

    reason =
      case outcome do
        :acknowledged -> {:turn_timeout, :abort_acknowledged}
        {:failed, abort_reason} -> {:turn_timeout, {:abort_failed, abort_reason}}
      end

    receipt =
      build_receipt(context, "aborted", %{
        "reason" => inspect(reason),
        "abort_outcome" => inspect(outcome)
      })

    case persist_receipt(context, receipt) do
      {:ok, receipt_path} ->
        context.on_message.(
          proof_update(
            %{
              event: :turn_aborted,
              payload: Map.put(receipt, "receipt_path", receipt_path),
              session_id: context.proof.session_id,
              receipt_path: receipt_path,
              timestamp: DateTime.utc_now(),
              backend: :pi
            },
            context.proof
          )
        )

        {:error, reason}

      {:error, receipt_reason} ->
        fail_turn_without_receipt(context, receipt_reason)
    end
  end

  defp fail_turn(context, reason, stage) do
    receipt =
      build_receipt(context, "failed", %{
        "stage" => Atom.to_string(stage),
        "reason" => inspect(reason)
      })

    case persist_receipt(context, receipt) do
      {:ok, receipt_path} ->
        emit_turn_error(context, reason, receipt, receipt_path)
        {:error, reason}

      {:error, receipt_reason} ->
        fail_turn_without_receipt(context, receipt_reason)
    end
  end

  defp fail_turn_without_receipt(context, reason) do
    failure = {:receipt_write_failed, reason}
    emit_turn_error(context, failure, nil, nil)
    {:error, failure}
  end

  defp emit_turn_error(context, reason, receipt, receipt_path) do
    payload =
      case receipt do
        %{} -> Map.put(receipt, "receipt_path", receipt_path)
        _ -> %{"reason" => inspect(reason)}
      end

    context.on_message.(
      proof_update(
        %{
          event: :turn_ended_with_error,
          payload: payload,
          session_id: context.proof.session_id,
          receipt_path: receipt_path,
          timestamp: DateTime.utc_now(),
          backend: :pi
        },
        context.proof
      )
    )
  end

  defp session_proof(rpc, session_id, state, session_name) do
    %{
      session_id: session_id,
      session_file: Map.get(state, "sessionFile"),
      session_name: session_name,
      model: model_summary(Map.get(state, "model")),
      thinking_level: Map.get(state, "thinkingLevel"),
      backend_process_pid: rpc.os_pid,
      backend_command: rpc.command,
      stderr_path: rpc.stderr_path
    }
  end

  defp model_summary(model) when is_map(model) do
    Map.take(model, ["id", "name", "api", "provider", "contextWindow", "maxTokens"])
  end

  defp model_summary(_model), do: nil

  defp proof_update(update, proof) do
    Map.merge(
      update,
      Map.take(proof, [
        :backend_command,
        :backend_process_pid,
        :model,
        :session_file,
        :stderr_path,
        :thinking_level
      ])
    )
  end

  defp build_receipt(context, outcome, details) do
    %{
      "schema_version" => @receipt_schema_version,
      "backend" => "pi",
      "outcome" => outcome,
      "attempt" => normalized_receipt_index(context.opts[:attempt], 0),
      "turn" => normalized_receipt_index(context.opts[:turn_number], 1),
      "started_at" => DateTime.to_iso8601(context.started_at),
      "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "issue" => %{
        "id" => Map.get(context.issue, :id),
        "identifier" => Map.get(context.issue, :identifier),
        "title" => Map.get(context.issue, :title)
      },
      "session" => %{
        "id" => context.proof.session_id,
        "file" => context.proof.session_file,
        "name" => context.proof.session_name,
        "model" => context.proof.model,
        "thinking_level" => context.proof.thinking_level
      },
      "runtime" => %{
        "command" => context.proof.backend_command,
        "pid" => context.proof.backend_process_pid,
        "stderr_path" => context.proof.stderr_path
      },
      "stderr_tail" => stderr_tail(context.rpc.stderr_path),
      "details" => details
    }
  end

  defp normalized_receipt_index(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalized_receipt_index(_value, default), do: default

  defp persist_receipt(context, receipt) do
    attempt = receipt["attempt"] |> Integer.to_string() |> String.pad_leading(4, "0")
    turn = receipt["turn"] |> Integer.to_string() |> String.pad_leading(4, "0")
    directory = Path.join(context.rpc.workspace, ".symphony/attempt-receipts")
    nonce = System.system_time(:microsecond)
    path = Path.join(directory, "attempt-#{attempt}-turn-#{turn}-#{nonce}.json")
    temporary_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(temporary_path, Jason.encode_to_iodata!(receipt, pretty: true)),
         :ok <- File.rename(temporary_path, path) do
      {:ok, path}
    else
      {:error, reason} ->
        File.rm(temporary_path)
        {:error, reason}
    end
  rescue
    error in [ArgumentError, File.Error] -> {:error, error}
  end

  defp stderr_tail(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} when byte_size(contents) > @stderr_tail_bytes ->
        binary_part(contents, byte_size(contents) - @stderr_tail_bytes, @stderr_tail_bytes)

      {:ok, contents} ->
        contents

      {:error, reason} ->
        "<stderr unavailable: #{inspect(reason)}>"
    end
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(%{rpc: rpc, tracker_bridge: tracker_bridge}) do
    Rpc.close(rpc)
    TrackerBridge.stop(tracker_bridge)
  end

  defp pi_command(command, nil), do: command

  defp pi_command(command, %{extension_path: extension_path}) do
    command <> " --extension " <> shell_escape(extension_path)
  end

  defp tracker_bridge_environment(%{environment: environment}) when is_list(environment),
    do: environment

  defp tracker_bridge_environment(_tracker_bridge), do: []

  defp tracker_secret_port_env(%{tracker: %{secret_environment_names: names}})
       when is_list(names) do
    names
    |> Enum.filter(fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
    |> Enum.map(&{String.to_charlist(&1), false})
  end

  defp tracker_secret_port_env(_config), do: []

  defp session_id_from_state(%{"data" => %{"sessionId" => session_id}}) when is_binary(session_id),
    do: session_id

  defp session_id_from_state(_response), do: nil

  defp settled_event?(%{"type" => "agent_settled"}), do: true
  defp settled_event?(%{"type" => "agent_end", "willRetry" => false}), do: true
  defp settled_event?(_event), do: false

  defp emit_event(on_message, event) when is_function(on_message, 1) and is_map(event) do
    update =
      %{
        event: event_name(event),
        payload: event,
        raw: Jason.encode!(event),
        timestamp: DateTime.utc_now(),
        backend: :pi
      }
      |> maybe_put_event_assistant_text(event)
      |> maybe_put_event_usage(event)

    on_message.(update)
  end

  defp maybe_put_event_assistant_text(update, %{"type" => "message_end", "message" => message}) do
    case assistant_message_text(message) do
      text when is_binary(text) and text != "" -> Map.put(update, :assistant_text, text)
      _ -> update
    end
  end

  defp maybe_put_event_assistant_text(
         update,
         %{
           "type" => "message_update",
           "assistantMessageEvent" => %{"type" => "text_delta", "delta" => delta}
         }
       )
       when is_binary(delta) do
    Map.put(update, :assistant_text_delta, delta)
  end

  defp maybe_put_event_assistant_text(update, _event), do: update

  defp assistant_message_text(%{"role" => "assistant", "content" => content}) when is_binary(content),
    do: content

  defp assistant_message_text(%{"role" => "assistant", "content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp assistant_message_text(_message), do: nil

  defp maybe_put_event_usage(update, %{"usage" => usage}) when is_map(usage) do
    normalized = normalize_usage(usage)
    if map_size(normalized) > 0, do: Map.put(update, :usage, normalized), else: update
  end

  defp maybe_put_event_usage(update, _event), do: update

  defp emit_usage(on_message, %{"data" => %{"tokens" => tokens}})
       when is_function(on_message, 1) and is_map(tokens) do
    usage = normalize_usage(tokens)

    if map_size(usage) > 0 do
      on_message.(%{
        event: :usage,
        payload: %{"usage" => usage},
        usage: usage,
        timestamp: DateTime.utc_now(),
        backend: :pi
      })
    end
  end

  defp emit_usage(_on_message, _response), do: :ok

  defp normalize_usage(tokens) do
    tokens
    |> copy_integer(tokens, "input", "input_tokens")
    |> copy_integer(tokens, "output", "output_tokens")
    |> copy_integer(tokens, "total", "total_tokens")
    |> copy_integer(tokens, "totalTokens", "total_tokens")
  end

  defp copy_integer(usage, tokens, source, target) do
    case Map.get(tokens, source) do
      value when is_integer(value) and value >= 0 -> Map.put(usage, target, value)
      _ -> usage
    end
  end

  defp event_name(%{"type" => "agent_start"}), do: :agent_started
  defp event_name(%{"type" => "agent_end"}), do: :agent_ended
  defp event_name(%{"type" => "agent_settled"}), do: :agent_settled
  defp event_name(%{"type" => "turn_start"}), do: :turn_started
  defp event_name(%{"type" => "turn_end"}), do: :turn_ended
  defp event_name(%{"type" => "message_start"}), do: :message_started
  defp event_name(%{"type" => "message_update"}), do: :message_update
  defp event_name(%{"type" => "message_end"}), do: :message_ended
  defp event_name(%{"type" => "tool_execution_start"}), do: :tool_execution_started
  defp event_name(%{"type" => "tool_execution_update"}), do: :tool_execution_updated
  defp event_name(%{"type" => "tool_execution_end"}), do: :tool_execution_ended
  defp event_name(%{"type" => "extension_ui_request"}), do: :extension_ui_request
  defp event_name(%{"type" => type}) when is_binary(type), do: :notification
  defp event_name(_event), do: :notification

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok
end
