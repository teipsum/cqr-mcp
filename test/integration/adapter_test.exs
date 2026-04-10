defmodule Cqr.Integration.AdapterTest do
  use ExUnit.Case

  alias Cqr.Adapter.Grafeo, as: GrafeoAdapter

  @finance_scope %{visible_scopes: [["company", "finance"], ["company"]]}
  @engineering_scope %{visible_scopes: [["company", "engineering"], ["company"]]}

  describe "resolve/3" do
    test "resolves entity within visible scope" do
      expression = %Cqr.Resolve{entity: {"finance", "arr"}}
      {:ok, result} = GrafeoAdapter.resolve(expression, @finance_scope, [])

      assert %Cqr.Result{} = result
      assert length(result.data) == 1
      assert hd(result.data).name == "arr"
      assert "grafeo" in result.sources
    end

    test "returns quality metadata" do
      expression = %Cqr.Resolve{entity: {"finance", "arr"}}
      {:ok, result} = GrafeoAdapter.resolve(expression, @finance_scope, [])

      assert result.quality.reputation != nil
      assert result.quality.owner == "finance_team"
    end

    test "entity not visible from sibling scope" do
      expression = %Cqr.Resolve{entity: {"finance", "arr"}}
      {:error, error} = GrafeoAdapter.resolve(expression, @engineering_scope, [])

      assert error.code == :entity_not_found
    end

    test "nonexistent entity returns error with suggestions" do
      expression = %Cqr.Resolve{entity: {"finance", "nonexistent"}}
      {:error, error} = GrafeoAdapter.resolve(expression, @finance_scope, [])

      assert error.code == :entity_not_found
      assert error.retry_guidance != nil
    end
  end

  describe "discover/3" do
    test "discovers related entities" do
      expression = %Cqr.Discover{
        related_to: {:entity, {"product", "churn_rate"}},
        depth: 1
      }

      scope = %{visible_scopes: [["company", "product"], ["company"]]}
      {:ok, result} = GrafeoAdapter.discover(expression, scope, [])

      assert %Cqr.Result{} = result
      assert length(result.data) > 0
      assert "grafeo" in result.sources
    end

    test "respects scope visibility in discovery" do
      expression = %Cqr.Discover{
        related_to: {:entity, {"product", "churn_rate"}},
        depth: 1
      }

      # From engineering scope, product entities should not be visible
      {:ok, result} = GrafeoAdapter.discover(expression, @engineering_scope, [])

      # Related entities in product scope should be filtered out
      product_entities =
        Enum.filter(result.data, fn r ->
          elem(r.entity, 0) == "product"
        end)

      assert product_entities == []
    end

    test "search-based discovery returns empty for V1" do
      expression = %Cqr.Discover{related_to: {:search, "revenue"}}
      {:ok, result} = GrafeoAdapter.discover(expression, @finance_scope, [])
      assert result.data == []
    end
  end

  describe "health_check/0" do
    test "reports healthy" do
      {:ok, health} = GrafeoAdapter.health_check()
      assert health.adapter == "grafeo"
      assert health.status == :healthy
      assert health.version =~ "grafeo"
    end
  end

  describe "capabilities/0" do
    test "supports resolve and discover" do
      caps = GrafeoAdapter.capabilities()
      assert :resolve in caps
      assert :discover in caps
    end
  end
end
