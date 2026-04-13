defmodule CqrMcp.HandlerTest do
  use ExUnit.Case

  alias CqrMcp.Handler

  # Set agent scope to finance so we can resolve finance entities
  setup do
    old_scope = System.get_env("CQR_AGENT_SCOPE")
    System.put_env("CQR_AGENT_SCOPE", "scope:company:finance")

    on_exit(fn ->
      if old_scope,
        do: System.put_env("CQR_AGENT_SCOPE", old_scope),
        else: System.delete_env("CQR_AGENT_SCOPE")
    end)
  end

  describe "initialize" do
    test "returns server info and capabilities" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{}
        })

      assert response["id"] == 1
      result = response["result"]
      assert result["protocolVersion"] != nil
      assert result["capabilities"]["tools"] != nil
      assert result["capabilities"]["resources"] != nil
      assert result["serverInfo"]["name"] == "cqr_mcp"
    end
  end

  describe "notifications/initialized" do
    test "returns nil (no response for notifications)" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })

      assert response == nil
    end
  end

  describe "ping" do
    test "returns empty result" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "ping"
        })

      assert response["result"] == %{}
    end
  end

  describe "tools/list" do
    test "returns seven tools" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/list"
        })

      tools = response["result"]["tools"]
      assert length(tools) == 8

      names = Enum.map(tools, & &1["name"])
      assert "cqr_resolve" in names
      assert "cqr_discover" in names
      assert "cqr_certify" in names
      assert "cqr_assert" in names
      assert "cqr_assert_batch" in names
      assert "cqr_trace" in names
      assert "cqr_signal" in names
      assert "cqr_refresh" in names
    end

    test "each tool has name, description, and inputSchema" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/list"
        })

      for tool <- response["result"]["tools"] do
        assert tool["name"] != nil
        assert tool["description"] != nil
        assert tool["inputSchema"] != nil
        assert tool["inputSchema"]["type"] == "object"
      end
    end
  end

  describe "tools/call — cqr_resolve" do
    test "valid resolve returns result with quality" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => "tools/call",
          "params" => %{
            "name" => "cqr_resolve",
            "arguments" => %{"entity" => "entity:finance:arr"}
          }
        })

      assert response["result"] != nil
      refute response["result"]["isError"]
      content = hd(response["result"]["content"])
      assert content["type"] == "text"

      parsed = Jason.decode!(content["text"])
      assert parsed["data"] != nil
      assert parsed["quality"] != nil
      assert parsed["cost"] != nil
      assert parsed["sources"] != nil
    end

    test "resolve nonexistent entity returns error content" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "tools/call",
          "params" => %{
            "name" => "cqr_resolve",
            "arguments" => %{"entity" => "entity:finance:nonexistent"}
          }
        })

      result = response["result"]
      assert result["isError"] == true
    end
  end

  describe "tools/call — cqr_discover" do
    test "discover by entity reference" do
      System.put_env("CQR_AGENT_SCOPE", "scope:company:product")

      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 8,
          "method" => "tools/call",
          "params" => %{
            "name" => "cqr_discover",
            "arguments" => %{"topic" => "entity:product:churn_rate"}
          }
        })

      assert response["result"] != nil
      refute response["result"]["isError"]
    end

    test "discover by search term" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "tools/call",
          "params" => %{
            "name" => "cqr_discover",
            "arguments" => %{"topic" => "customer churn"}
          }
        })

      assert response["result"] != nil
    end

    test "discover with depth" do
      System.put_env("CQR_AGENT_SCOPE", "scope:company:product")

      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 10,
          "method" => "tools/call",
          "params" => %{
            "name" => "cqr_discover",
            "arguments" => %{
              "topic" => "entity:product:churn_rate",
              "depth" => 3
            }
          }
        })

      assert response["result"] != nil
    end
  end

  describe "tools/call — cqr_certify" do
    test "propose certification" do
      System.put_env("CQR_AGENT_SCOPE", "scope:company:hr")

      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 11,
          "method" => "tools/call",
          "params" => %{
            "name" => "cqr_certify",
            "arguments" => %{
              "entity" => "entity:hr:headcount",
              "status" => "proposed",
              "authority" => "hr_team"
            }
          }
        })

      assert response["result"] != nil
      refute response["result"]["isError"]
    end
  end

  describe "tools/call — errors" do
    test "unknown tool returns error" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 12,
          "method" => "tools/call",
          "params" => %{
            "name" => "unknown_tool",
            "arguments" => %{}
          }
        })

      result = response["result"]
      assert result["isError"] == true
    end

    test "missing params returns error" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 13,
          "method" => "tools/call",
          "params" => %{}
        })

      assert response["error"] != nil
      assert response["error"]["code"] == -32_602
    end
  end

  describe "resources/list" do
    test "returns five resources" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 14,
          "method" => "resources/list"
        })

      resources = response["result"]["resources"]
      assert length(resources) == 5

      uris = Enum.map(resources, & &1["uri"])
      assert "cqr://session" in uris
      assert "cqr://scopes" in uris
      assert "cqr://entities" in uris
      assert "cqr://policies" in uris
      assert "cqr://system_prompt" in uris
    end
  end

  describe "resources/read" do
    test "read scopes" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 15,
          "method" => "resources/read",
          "params" => %{"uri" => "cqr://scopes"}
        })

      contents = hd(response["result"]["contents"])
      parsed = Jason.decode!(contents["text"])
      assert length(parsed["hierarchy"]) == 6
    end

    test "read entities" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 16,
          "method" => "resources/read",
          "params" => %{"uri" => "cqr://entities"}
        })

      contents = hd(response["result"]["contents"])
      parsed = Jason.decode!(contents["text"])
      assert parsed["count"] >= 27
    end

    test "read policies" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 17,
          "method" => "resources/read",
          "params" => %{"uri" => "cqr://policies"}
        })

      contents = hd(response["result"]["contents"])
      parsed = Jason.decode!(contents["text"])
      assert parsed["governance"] != nil
      assert parsed["defaults"] != nil
    end

    test "read system prompt" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 18,
          "method" => "resources/read",
          "params" => %{"uri" => "cqr://system_prompt"}
        })

      contents = hd(response["result"]["contents"])
      text = Jason.decode!(contents["text"])
      assert text =~ "CQR Agent Generation Contract"
      assert text =~ "RESOLVE"
      assert text =~ "DISCOVER"
      assert text =~ "CERTIFY"
    end

    test "unknown resource returns error" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 19,
          "method" => "resources/read",
          "params" => %{"uri" => "cqr://unknown"}
        })

      assert response["error"] != nil
    end
  end

  describe "unknown method" do
    test "returns method not found error" do
      response =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 20,
          "method" => "unknown/method"
        })

      assert response["error"]["code"] == -32_601
    end
  end

  describe "MCP lifecycle" do
    test "initialize → tools/list → tools/call → resources/list → resources/read" do
      r1 =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 100,
          "method" => "initialize",
          "params" => %{}
        })

      assert r1["result"]["serverInfo"]["name"] == "cqr_mcp"

      assert nil ==
               Handler.handle_request(%{
                 "jsonrpc" => "2.0",
                 "method" => "notifications/initialized"
               })

      r3 =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 101,
          "method" => "tools/list"
        })

      assert length(r3["result"]["tools"]) == 8

      r4 =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 102,
          "method" => "tools/call",
          "params" => %{
            "name" => "cqr_resolve",
            "arguments" => %{"entity" => "entity:finance:arr"}
          }
        })

      assert r4["result"]["content"] != nil

      r5 =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 103,
          "method" => "resources/list"
        })

      assert length(r5["result"]["resources"]) == 5

      r6 =
        Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 104,
          "method" => "resources/read",
          "params" => %{"uri" => "cqr://scopes"}
        })

      assert r6["result"]["contents"] != nil
    end
  end
end
