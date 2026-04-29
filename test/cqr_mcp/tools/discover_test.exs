defmodule CqrMcp.Tools.DiscoverTest do
  use ExUnit.Case

  alias CqrMcp.Tools

  @product_context %{
    scope: ["company", "product"],
    agent_id: "test:discover_tool"
  }

  @company_context %{
    scope: ["company"],
    agent_id: "test:discover_tool"
  }

  describe "tool descriptor" do
    test "is registered in CqrMcp.Tools.list/0" do
      tool = Enum.find(Tools.list(), &(&1["name"] == "cqr_discover"))
      assert tool != nil
      assert "topic" in tool["inputSchema"]["required"]
    end

    test "exposes near as an optional input property" do
      tool = Enum.find(Tools.list(), &(&1["name"] == "cqr_discover"))
      props = tool["inputSchema"]["properties"]

      assert Map.has_key?(props, "near")
      assert props["near"]["type"] == "string"
      refute "near" in tool["inputSchema"]["required"]
    end
  end

  describe "free-text search with near" do
    test "produces near_distance in result rows" do
      args = %{
        "topic" => "rate",
        "near" => "entity:product:churn_rate"
      }

      {:ok, result} = Tools.call("cqr_discover", args, @product_context)

      assert is_list(result["data"])
      assert Enum.any?(result["data"], &Map.has_key?(&1, "near_distance"))
      Enum.each(result["data"], fn row -> assert Map.has_key?(row, "near_distance") end)
    end

    test "near argument without entity: prefix is normalized and accepted" do
      args = %{
        "topic" => "rate",
        "near" => "product:churn_rate"
      }

      {:ok, result} = Tools.call("cqr_discover", args, @product_context)

      assert is_list(result["data"])
      Enum.each(result["data"], fn row -> assert Map.has_key?(row, "near_distance") end)
    end
  end

  describe "free-text search without near" do
    test "produces no near_distance field on any row" do
      args = %{"topic" => "rate"}
      {:ok, result} = Tools.call("cqr_discover", args, @product_context)

      assert is_list(result["data"])
      assert result["data"] != []
      Enum.each(result["data"], fn row -> refute Map.has_key?(row, "near_distance") end)
    end
  end

  describe "anchor mode with near" do
    test "ignores the near argument (anchor traversal output unchanged)" do
      base_args = %{"topic" => "entity:product:churn_rate", "depth" => 1}

      {:ok, without} = Tools.call("cqr_discover", base_args, @company_context)

      {:ok, with_near} =
        Tools.call(
          "cqr_discover",
          Map.put(base_args, "near", "entity:product:retention_rate"),
          @company_context
        )

      Enum.each(without["data"], fn row -> refute Map.has_key?(row, "near_distance") end)
      Enum.each(with_near["data"], fn row -> refute Map.has_key?(row, "near_distance") end)

      assert with_near["data"] == without["data"]
    end
  end

  describe "malformed near degrades gracefully" do
    test "garbage near string does not reject the call" do
      args = %{"topic" => "rate", "near" => "garbage_no_colons"}
      {:ok, result} = Tools.call("cqr_discover", args, @product_context)

      assert is_list(result["data"])
      Enum.each(result["data"], fn row -> refute Map.has_key?(row, "near_distance") end)
    end

    test "near with disallowed characters degrades to no-near" do
      args = %{"topic" => "rate", "near" => "entity:Bad-Name:bar"}
      {:ok, result} = Tools.call("cqr_discover", args, @product_context)

      assert is_list(result["data"])
      Enum.each(result["data"], fn row -> refute Map.has_key?(row, "near_distance") end)
    end
  end
end
