defmodule CqrMcp.SSE.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias CqrMcp.SSE.Router

  @opts Router.init([])

  describe "POST /message" do
    test "dispatches JSON-RPC response to registered SSE clients and returns it in body" do
      {:ok, _} = Registry.register(CqrMcp.SSE.Registry, :clients, nil)

      body = ~s({"jsonrpc":"2.0","id":42,"method":"ping","params":{}})

      conn =
        :post
        |> conn("/message", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["id"] == 42

      assert_receive {:mcp_event, payload}, 1_000
      assert payload == conn.resp_body
    end

    test "returns 400 for empty body" do
      conn =
        :post
        |> conn("/message", "{}")
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
    end
  end

  describe "OPTIONS preflight" do
    test "returns permissive CORS headers" do
      conn =
        :options
        |> conn("/message")
        |> Router.call(@opts)

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end
end
