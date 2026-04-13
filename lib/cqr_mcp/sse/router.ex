defmodule CqrMcp.SSE.Router do
  @moduledoc """
  HTTP transport for MCP: SSE event stream plus JSON-RPC POST endpoint.

    * `GET /sse` — long-lived Server-Sent Events stream. Sends an initial
      `event: endpoint` pointing at `/message`, then keep-alive comments
      every 15 seconds. Reserved for future server-initiated notifications.
    * `POST /message` — accepts a JSON-RPC 2.0 request, dispatches it
      through `CqrMcp.Handler`, and returns the JSON-RPC response in the
      HTTP response body. Shares the same handler pipeline as the stdio
      transport, so tools and resources behave identically.
    * `OPTIONS *` — CORS preflight.

  CORS is permissive (`*`) to allow browser-based MCP clients. Tighten
  per deployment if needed.
  """

  use Plug.Router

  require Logger

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  @cors_headers [
    {"access-control-allow-origin", "*"},
    {"access-control-allow-methods", "GET, POST, OPTIONS"},
    {"access-control-allow-headers", "content-type"}
  ]

  options _ do
    conn
    |> merge_resp_headers(@cors_headers)
    |> send_resp(204, "")
  end

  get "/sse" do
    conn =
      conn
      |> merge_resp_headers(@cors_headers)
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "event: endpoint\ndata: /message\n\n")

    Logger.info("MCP SSE: stream opened from #{format_peer(conn)}")
    keep_alive_loop(conn)
  end

  post "/message" do
    case conn.body_params do
      %{} = request when map_size(request) > 0 ->
        response = CqrMcp.Handler.handle_request(request) || %{}

        conn
        |> merge_resp_headers(@cors_headers)
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response))

      _ ->
        conn
        |> merge_resp_headers(@cors_headers)
        |> put_resp_content_type("application/json")
        |> send_resp(400, ~s({"error":"invalid JSON-RPC body"}))
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp keep_alive_loop(conn) do
    receive do
    after
      15_000 ->
        case chunk(conn, ": keep-alive\n\n") do
          {:ok, conn} ->
            keep_alive_loop(conn)

          {:error, reason} ->
            Logger.info("MCP SSE: stream closed (#{inspect(reason)})")
            conn
        end
    end
  end

  defp format_peer(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      other -> inspect(other)
    end
  end
end
