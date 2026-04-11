defmodule Cqr.Integration.RefreshTest do
  @moduledoc """
  Integration tests for the REFRESH CHECK primitive.

  The seed dataset (see `Cqr.Repo.Seed`) carries per-entity freshness
  values that range from 1h (dau, deployment_frequency) to 2160h
  (compensation_ratio). These tests lean on those seeded values rather
  than asserting new fixtures, so the behaviour of the staleness scan
  is validated against a known baseline.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine
  alias Cqr.Grafeo.Server, as: GrafeoServer

  @root_context %{scope: ["company"], agent_id: "twin:refresh_root"}
  @product_context %{scope: ["company", "product"], agent_id: "twin:refresh_product"}
  @hr_context %{scope: ["company", "hr"], agent_id: "twin:refresh_hr"}

  setup do
    cleanup_fixtures()
    on_exit(&cleanup_fixtures/0)
    :ok
  end

  defp cleanup_fixtures do
    for ns <- ["test_refresh"] do
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'})-[r]-() DELETE r")
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'}) DELETE e")
      GrafeoServer.query("MATCH (r:AssertionRecord {entity_namespace: '#{ns}'}) DELETE r")
    end

    :ok
  end

  defp entity_names(result) do
    Enum.map(result.data, & &1.entity)
  end

  describe "REFRESH CHECK threshold behaviour" do
    test "threshold 1h returns most seeded entities (freshness > 1h)" do
      assert {:ok, result} =
               Engine.execute(
                 "REFRESH CHECK active_context WHERE age > 1h RETURN stale_items",
                 @root_context
               )

      # dau and deployment_frequency are seeded at 1h — they must NOT appear.
      entities = entity_names(result)
      refute "entity:product:dau" in entities
      refute "entity:engineering:deployment_frequency" in entities

      # At least one known stale entity must appear.
      assert "entity:product:nps" in entities
    end

    test "threshold 3000h returns empty (no seeded entity is that stale)" do
      assert {:ok, result} =
               Engine.execute(
                 "REFRESH CHECK active_context WHERE age > 3000h RETURN stale_items",
                 @root_context
               )

      assert result.data == []
    end

    test "threshold 24h surfaces time_to_value and nps but not dau" do
      assert {:ok, result} =
               Engine.execute(
                 "REFRESH CHECK active_context WHERE age > 24h RETURN stale_items",
                 @root_context
               )

      entities = entity_names(result)
      assert "entity:product:time_to_value" in entities
      assert "entity:product:nps" in entities
      refute "entity:product:dau" in entities
    end

    test "default REFRESH CHECK (no WHERE) uses 24h threshold" do
      assert {:ok, default_result} =
               Engine.execute("REFRESH CHECK active_context", @root_context)

      assert {:ok, explicit_result} =
               Engine.execute(
                 "REFRESH CHECK active_context WHERE age > 24h RETURN stale_items",
                 @root_context
               )

      assert entity_names(default_result) |> Enum.sort() ==
               entity_names(explicit_result) |> Enum.sort()
    end
  end

  describe "REFRESH CHECK scope narrowing" do
    test "WITHIN scope:company:product only returns product entities" do
      assert {:ok, result} =
               Engine.execute(
                 "REFRESH CHECK active_context WITHIN scope:company:product WHERE age > 24h RETURN stale_items",
                 @root_context
               )

      entities = entity_names(result)

      # Every returned entity must live in the product namespace.
      assert Enum.all?(entities, fn e -> String.starts_with?(e, "entity:product:") end)

      # Finance + HR entities must not appear.
      refute "entity:finance:revenue_growth" in entities
      refute "entity:hr:enps" in entities
    end
  end

  describe "REFRESH CHECK sorting" do
    test "results are sorted most-stale-first" do
      assert {:ok, result} =
               Engine.execute(
                 "REFRESH CHECK active_context WHERE age > 1h RETURN stale_items",
                 @root_context
               )

      freshnesses = Enum.map(result.data, & &1.freshness_hours_ago)
      assert freshnesses == Enum.sort(freshnesses, :desc)
    end
  end

  describe "REFRESH CHECK after ASSERT" do
    test "freshly asserted entity does NOT appear in stale list at 24h" do
      expr =
        ~s(ASSERT entity:test_refresh:r01_fresh TYPE observation ) <>
          ~s(DESCRIPTION "fresh assertion" ) <>
          ~s(INTENT "refresh test" ) <>
          ~s(DERIVED_FROM entity:product:churn_rate)

      assert {:ok, _} = Engine.execute(expr, @product_context)

      assert {:ok, result} =
               Engine.execute(
                 "REFRESH CHECK active_context WHERE age > 24h RETURN stale_items",
                 @product_context
               )

      entities = entity_names(result)
      refute "entity:test_refresh:r01_fresh" in entities
    end
  end

  describe "scope enforcement" do
    test "product agent only sees product entities in REFRESH results" do
      assert {:ok, result} =
               Engine.execute(
                 "REFRESH CHECK active_context WHERE age > 1h RETURN stale_items",
                 @product_context
               )

      entities = entity_names(result)
      assert Enum.all?(entities, fn e -> String.starts_with?(e, "entity:product:") end)
    end

    test "hr agent only sees hr entities" do
      assert {:ok, result} =
               Engine.execute(
                 "REFRESH CHECK active_context WHERE age > 1h RETURN stale_items",
                 @hr_context
               )

      entities = entity_names(result)
      assert Enum.all?(entities, fn e -> String.starts_with?(e, "entity:hr:") end)
      refute Enum.empty?(entities)
    end
  end
end
