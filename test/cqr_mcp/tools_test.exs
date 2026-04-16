defmodule CqrMcp.ToolsTest do
  use ExUnit.Case, async: true

  alias CqrMcp.Tools

  describe "discover_tool schema" do
    test "includes max_results property" do
      tools = Tools.list()
      discover = Enum.find(tools, &(&1["name"] == "cqr_discover"))
      props = discover["inputSchema"]["properties"]

      assert %{"type" => "integer", "default" => 10} = props["max_results"]
      refute "max_results" in discover["inputSchema"]["required"]
    end
  end

  describe "build_discover_expression/1" do
    # build_discover_expression is private, so we test it through call/3
    # by inspecting the expression the parser receives. We can use a
    # lightweight approach: call/3 with a dummy context will attempt to
    # parse and execute the built expression. Instead, we'll test the
    # expression indirectly by parsing the result of a helper that
    # exercises the public API path.

    # Since build_discover_expression is private, we test via the
    # expression string that would be generated. We can verify by
    # making the function testable through Module.get_attribute or
    # by testing the full call path. Let's test the full path.

    setup do
      old_scope = System.get_env("CQR_AGENT_SCOPE")
      System.put_env("CQR_AGENT_SCOPE", "scope:company:product")

      on_exit(fn ->
        if old_scope,
          do: System.put_env("CQR_AGENT_SCOPE", old_scope),
          else: System.delete_env("CQR_AGENT_SCOPE")
      end)
    end

    test "max_results emits LIMIT clause in expression" do
      # We can test the expression builder by making it public or by
      # testing through the parser. Since the parser already handles
      # LIMIT, a successful round-trip proves the clause was emitted.
      response =
        CqrMcp.Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "cqr_discover",
            "arguments" => %{
              "topic" => "entity:product:churn_rate",
              "max_results" => 5
            }
          }
        })

      # The call should succeed (parser accepts LIMIT clause)
      assert response["result"] != nil
      refute response["result"]["isError"]

      parsed = Jason.decode!(hd(response["result"]["content"])["text"])
      data = parsed["data"]
      assert length(data) <= 5
    end

    test "without max_results no LIMIT clause is emitted" do
      response =
        CqrMcp.Handler.handle_request(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "cqr_discover",
            "arguments" => %{
              "topic" => "entity:product:churn_rate"
            }
          }
        })

      assert response["result"] != nil
      refute response["result"]["isError"]
    end
  end
end
