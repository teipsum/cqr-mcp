defmodule CqrMcp.SSE.Router do
  @moduledoc """
  HTTP transport for MCP: SSE event stream plus JSON-RPC POST endpoint.

    * `GET /sse` - long-lived Server-Sent Events stream. Registers the
      process in `CqrMcp.SSE.Registry`, sends an initial `event: endpoint`
      carrying the absolute `/message` URL, then serves both
      `event: message` payloads dispatched from POST handlers and
      keep-alive comments every 15 seconds.
    * `POST /message` - accepts a JSON-RPC 2.0 request, dispatches it
      through `CqrMcp.Handler`, broadcasts the response as an
      `event: message` SSE event to every registered stream, and returns
      the same JSON-RPC response in the HTTP body for clients that read
      the POST body directly.
    * `OPTIONS *` - CORS preflight.

  MCP SSE clients (Claude Desktop, ollmcp, etc.) expect JSON-RPC responses
  on the `/sse` stream, not the POST body - returning the body too keeps
  simpler HTTP clients working. CORS is permissive (`*`) to allow
  browser-based MCP clients. Tighten per deployment if needed.
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

    {:ok, _} = Registry.register(CqrMcp.SSE.Registry, :clients, nil)

    {:ok, conn} = chunk(conn, "event: endpoint\ndata: #{message_endpoint(conn)}\n\n")

    Logger.info("MCP SSE: stream opened from #{format_peer(conn)}")
    event_loop(conn)
  end

  post "/message" do
    case conn.body_params do
      %{} = request when map_size(request) > 0 ->
        response = CqrMcp.Handler.handle_request(request) || %{}
        payload = Jason.encode!(response)

        broadcast_sse_event(payload)

        conn
        |> merge_resp_headers(@cors_headers)
        |> put_resp_content_type("application/json")
        |> send_resp(200, payload)

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

  # Dispatch a JSON-RPC response to every connected SSE stream. Each
  # registered stream process receives `{:mcp_event, payload}` and writes
  # an `event: message` chunk from `event_loop/1`.
  defp broadcast_sse_event(payload) do
    Registry.dispatch(CqrMcp.SSE.Registry, :clients, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:mcp_event, payload})
    end)
  end

  defp event_loop(conn) do
    receive do
      {:mcp_event, payload} ->
        case chunk(conn, "event: message\ndata: #{payload}\n\n") do
          {:ok, conn} -> event_loop(conn)
          {:error, reason} -> close_stream(conn, reason)
        end
    after
      15_000 ->
        case chunk(conn, ": keep-alive\n\n") do
          {:ok, conn} -> event_loop(conn)
          {:error, reason} -> close_stream(conn, reason)
        end
    end
  end

  defp close_stream(conn, reason) do
    Logger.info("MCP SSE: stream closed (#{inspect(reason)})")
    conn
  end

  # Absolute URL for the POST endpoint so that MCP clients which treat
  # the endpoint as a base URL (rather than resolving against the SSE
  # URL) still land on the correct host.
  defp message_endpoint(conn) do
    scheme = to_string(conn.scheme)
    host = conn.host
    port = conn.port
    "#{scheme}://#{host}:#{port}/message"
  end

  defp format_peer(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      other -> inspect(other)
    end
  end
end
