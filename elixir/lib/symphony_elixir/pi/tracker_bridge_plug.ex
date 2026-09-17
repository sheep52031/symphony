defmodule SymphonyElixir.Pi.TrackerBridgePlug do
  @moduledoc false

  import Plug.Conn

  alias SymphonyElixir.Pi.TrackerBridge

  @max_body_bytes 1_048_576
  @tool_path "/v1/tool"

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "POST", request_path: @tool_path} = conn, opts) do
    bridge = Keyword.fetch!(opts, :bridge)

    with {:ok, token} <- bearer_token(conn),
         {:ok, body, conn} <- read_request_body(conn),
         {:ok, tool, arguments} <- decode_request(body),
         {:ok, result} <- TrackerBridge.execute(bridge, token, tool, arguments) do
      json_response(conn, 200, result)
    else
      {:error, :unauthorized} -> json_response(conn, 401, error_payload("unauthorized"))
      {:error, :request_too_large, conn} -> json_response(conn, 413, error_payload("request_too_large"))
      {:error, :invalid_request, conn} -> json_response(conn, 400, error_payload("invalid_request"))
      {:error, :invalid_request} -> json_response(conn, 400, error_payload("invalid_request"))
      {:error, :bridge_unavailable} -> json_response(conn, 503, error_payload("bridge_unavailable"))
    end
  end

  def call(%Plug.Conn{request_path: @tool_path} = conn, _opts) do
    conn
    |> put_resp_header("allow", "POST")
    |> json_response(405, error_payload("method_not_allowed"))
  end

  def call(conn, _opts), do: json_response(conn, 404, error_payload("not_found"))

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> {:error, :unauthorized}
    end
  end

  defp read_request_body(conn) do
    case Plug.Conn.read_body(conn, length: @max_body_bytes, read_length: 65_536) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _body, conn} -> {:error, :request_too_large, conn}
      {:error, _reason} -> {:error, :invalid_request, conn}
    end
  end

  defp decode_request(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"tool" => tool, "arguments" => arguments} = payload}
      when is_binary(tool) and is_map(arguments) ->
        if Map.keys(payload) |> Enum.all?(&(&1 in ["tool", "arguments"])) do
          {:ok, tool, arguments}
        else
          {:error, :invalid_request}
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp json_response(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(payload))
    |> halt()
  end

  defp error_payload(code), do: %{"error" => %{"code" => code}}
end
