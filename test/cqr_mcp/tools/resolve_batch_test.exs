defmodule CqrMcp.Tools.ResolveBatchTest do
  use ExUnit.Case

  alias CqrMcp.Tools

  @finance_context %{
    scope: ["company", "finance"],
    agent_id: "test:resolve_batch_tool"
  }
  @engineering_context %{
    scope: ["company", "engineering"],
    agent_id: "test:resolve_batch_tool"
  }

  describe "tool descriptor" do
    test "is registered in CqrMcp.Tools.list/0" do
      tool = Enum.find(Tools.list(), &(&1["name"] == "cqr_resolve_batch"))

      assert tool != nil
      assert "entities" in tool["inputSchema"]["required"]
    end
  end

  describe "call/3" do
    test "resolves multiple entities in one call, all visible" do
      args = %{"entities" => ["entity:finance:arr", "entity:finance:cac"]}
      {:ok, result} = Tools.call("cqr_resolve_batch", args, @finance_context)

      assert length(result["data"]) == 2
      assert Enum.all?(result["data"], &(&1["status"] == "ok"))

      assert Enum.map(result["data"], & &1["address"]) == [
               "entity:finance:arr",
               "entity:finance:cac"
             ]

      [first | _] = result["data"]
      assert is_map(first["payload"])
      refute is_struct(first["payload"])
      assert Map.has_key?(first["payload"], "data")
      assert Map.has_key?(first["payload"], "quality")
    end

    test "missing entity surfaces status:not_found per-row" do
      args = %{"entities" => ["entity:finance:arr", "entity:finance:nonexistent_xyz"]}
      {:ok, result} = Tools.call("cqr_resolve_batch", args, @finance_context)

      assert [%{"status" => "ok"}, %{"status" => "not_found"}] = result["data"]
    end

    test "scope-blocked entity shows as not_found, indistinguishable (privacy contract)" do
      args = %{"entities" => ["entity:finance:arr", "entity:finance:doesnt_exist_zzz"]}
      {:ok, result} = Tools.call("cqr_resolve_batch", args, @engineering_context)

      assert [%{"status" => "not_found"}, %{"status" => "not_found"}] = result["data"]
    end

    test "empty entities array returns empty result list" do
      args = %{"entities" => []}
      {:ok, result} = Tools.call("cqr_resolve_batch", args, @finance_context)

      assert result["data"] == []
    end

    test "missing entities field returns -32_602" do
      {:error, error} = Tools.call("cqr_resolve_batch", %{}, @finance_context)

      assert error["code"] == -32_602
    end

    test "non-list entities returns -32_602" do
      {:error, error} =
        Tools.call("cqr_resolve_batch", %{"entities" => "not_a_list"}, @finance_context)

      assert error["code"] == -32_602
    end

    test "invalid entity address returns -32_602" do
      args = %{"entities" => ["entity:finance:arr", "garbage_no_colons"]}
      {:error, error} = Tools.call("cqr_resolve_batch", args, @finance_context)

      assert error["code"] == -32_602
    end
  end
end
