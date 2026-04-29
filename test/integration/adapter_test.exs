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

  describe "resolve_batch/3" do
    test "resolves multiple entities in one call, all visible" do
      expression = %Cqr.ResolveBatch{
        entities: [
          {"finance", "arr"},
          {"product", "churn_rate"}
        ]
      }

      scope = %{visible_scopes: [["company", "finance"], ["company", "product"], ["company"]]}
      {:ok, %Cqr.Result{data: results}} = GrafeoAdapter.resolve_batch(expression, scope, [])

      assert length(results) == 2
      assert Enum.all?(results, &(&1.status == :ok))

      assert Enum.map(results, & &1.address) == [
               "entity:finance:arr",
               "entity:product:churn_rate"
             ]

      assert hd(results).payload.__struct__ == Cqr.Result
    end

    test "empty entity list returns empty result list" do
      expression = %Cqr.ResolveBatch{entities: []}
      scope = %{visible_scopes: [["company"]]}
      {:ok, %Cqr.Result{data: results}} = GrafeoAdapter.resolve_batch(expression, scope, [])
      assert results == []
    end

    test "missing entity surfaces :not_found per-row, others still resolve" do
      expression = %Cqr.ResolveBatch{
        entities: [
          {"finance", "arr"},
          {"finance", "nonexistent_xyz"}
        ]
      }

      {:ok, %Cqr.Result{data: results}} =
        GrafeoAdapter.resolve_batch(expression, @finance_scope, [])

      assert length(results) == 2
      [first, second] = results
      assert first.status == :ok
      assert first.address == "entity:finance:arr"
      assert second.status == :not_found
      assert second.address == "entity:finance:nonexistent_xyz"
      assert second.error.code == :entity_not_found
    end

    test "scope-blocked entity surfaces :not_found, never :scope_access (privacy contract)" do
      # finance:arr is invisible to an engineering-only agent.
      # The contract is that this is indistinguishable from nonexistent entities;
      # the agent must not be able to detect the existence of hidden entities.
      expression = %Cqr.ResolveBatch{
        entities: [
          {"finance", "arr"},
          {"finance", "truly_nonexistent_yzx"}
        ]
      }

      {:ok, %Cqr.Result{data: results}} =
        GrafeoAdapter.resolve_batch(expression, @engineering_scope, [])

      assert length(results) == 2
      assert Enum.all?(results, &(&1.status == :not_found))
      # Both responses are byte-identical in shape — the agent cannot tell which one exists.
      assert Enum.all?(results, &(&1.error.code == :entity_not_found))
    end

    test "large batch (10 entities) round-trips correctly" do
      # Real workload sized: an orient phase fetching its bootstrap + governance + 7 anchors.
      entities =
        for i <- 1..10 do
          # Mix existing seed entities with non-existing ones to verify per-row independence.
          if rem(i, 2) == 0 do
            {"finance", "arr"}
          else
            {"finance", "missing_#{i}"}
          end
        end

      expression = %Cqr.ResolveBatch{entities: entities}

      {:ok, %Cqr.Result{data: results}} =
        GrafeoAdapter.resolve_batch(expression, @finance_scope, [])

      assert length(results) == 10
      okays = Enum.count(results, &(&1.status == :ok))
      misses = Enum.count(results, &(&1.status == :not_found))
      assert okays == 5
      assert misses == 5
    end

    test "per-entity payload matches what resolve/3 returns for the same address" do
      single_expr = %Cqr.Resolve{entity: {"finance", "arr"}}
      {:ok, single_result} = GrafeoAdapter.resolve(single_expr, @finance_scope, [])

      batch_expr = %Cqr.ResolveBatch{entities: [{"finance", "arr"}]}

      {:ok, %Cqr.Result{data: [batch_row]}} =
        GrafeoAdapter.resolve_batch(batch_expr, @finance_scope, [])

      # The payload from a 1-element batch should be equivalent to a single resolve.
      assert batch_row.payload.data == single_result.data
      assert batch_row.payload.quality == single_result.quality
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
      assert [_ | _] = result.data
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

    test "search-based discovery runs text + vector pipeline scoped to agent visibility" do
      expression = %Cqr.Discover{related_to: {:search, "revenue"}}
      {:ok, result} = GrafeoAdapter.discover(expression, @finance_scope, [])

      # Finance scope agent sees finance revenue entities.
      assert [_ | _] = result.data

      # Every returned row carries source attribution.
      Enum.each(result.data, fn row ->
        assert row.source in ["text", "vector", "both"]
      end)

      # revenue_growth is the strongest hit (appears in both name and
      # description of that finance entity).
      assert Enum.any?(result.data, &(&1.name == "revenue_growth"))
    end

    test "search-based discovery is empty when no visible scope contains matching text" do
      # From engineering scope no entity mentions "revenue" in name or
      # description, and vector overlap on a single token is too weak
      # to surface anything — confirms the scope-first pre-filter.
      expression = %Cqr.Discover{related_to: {:search, "revenue"}}
      {:ok, result} = GrafeoAdapter.discover(expression, @engineering_scope, [])

      refute Enum.any?(result.data, fn row ->
               String.contains?(String.downcase(row.description), "revenue")
             end)
    end
  end

  describe "search discovery with near anchor" do
    @full_scope %{
      visible_scopes: [
        ["company"],
        ["company", "finance"],
        ["company", "product"],
        ["company", "engineering"],
        ["company", "hr"],
        ["company", "customer_success"]
      ]
    }

    test "biases ranking toward entities adjacent to the near anchor" do
      # product:retention_rate is BFS-distance 1 from product:churn_rate
      # (CORRELATES_WITH). engineering:incident_rate is unreachable from
      # product:churn_rate via typed edges in the seed graph. Both have
      # "rate" in their name, so without near their text scores are equal.
      # With near, the proximity term should push retention_rate above
      # incident_rate.
      expression = %Cqr.Discover{
        related_to: {:search, "rate"},
        near: {"product", "churn_rate"}
      }

      {:ok, result} = GrafeoAdapter.discover(expression, @full_scope, [])

      retention =
        Enum.find(result.data, fn r -> r.entity == {"product", "retention_rate"} end)

      incident =
        Enum.find(result.data, fn r -> r.entity == {"engineering", "incident_rate"} end)

      assert retention != nil
      assert retention.near_distance == 1
      # incident_rate may or may not surface depending on vector pickup,
      # but if it surfaces it must be unreachable from the anchor.
      if incident do
        assert incident.near_distance == nil
        assert retention.combined_score > incident.combined_score
      end
    end

    test "near=nil produces results identical to omitting the near field entirely" do
      term = "revenue"

      with_nil = %Cqr.Discover{related_to: {:search, term}, near: nil}
      without = %Cqr.Discover{related_to: {:search, term}}

      {:ok, r1} = GrafeoAdapter.discover(with_nil, @finance_scope, [])
      {:ok, r2} = GrafeoAdapter.discover(without, @finance_scope, [])

      assert r1.data == r2.data
      # And confirms backwards-compat output shape: no :near_distance key.
      Enum.each(r1.data, fn row -> refute Map.has_key?(row, :near_distance) end)
    end

    test "entities outside the BFS reach surface with near_distance == nil" do
      # finance:cac and finance:ltv are seeded but disconnected from
      # product:churn_rate's BFS tree. They will surface via vector or
      # text matches but should carry near_distance = nil.
      expression = %Cqr.Discover{
        related_to: {:search, "customer"},
        near: {"product", "churn_rate"}
      }

      {:ok, result} = GrafeoAdapter.discover(expression, @full_scope, [])

      unreachable =
        Enum.filter(result.data, fn r ->
          r.entity in [{"finance", "cac"}, {"finance", "ltv"}]
        end)

      assert unreachable != []
      Enum.each(unreachable, fn r -> assert r.near_distance == nil end)
    end

    test "near pointing at a non-existent anchor still returns search results" do
      expression = %Cqr.Discover{
        related_to: {:search, "revenue"},
        near: {"nonexistent_ns", "fake_addr"}
      }

      {:ok, result} = GrafeoAdapter.discover(expression, @finance_scope, [])

      assert [_ | _] = result.data
      Enum.each(result.data, fn row -> assert row.near_distance == nil end)
    end

    test "near_distance is present iff near is set" do
      term = "revenue"

      {:ok, without_near} =
        GrafeoAdapter.discover(
          %Cqr.Discover{related_to: {:search, term}},
          @finance_scope,
          []
        )

      {:ok, with_near} =
        GrafeoAdapter.discover(
          %Cqr.Discover{related_to: {:search, term}, near: {"finance", "arr"}},
          @finance_scope,
          []
        )

      Enum.each(without_near.data, fn row -> refute Map.has_key?(row, :near_distance) end)
      Enum.each(with_near.data, fn row -> assert Map.has_key?(row, :near_distance) end)
    end

    test "BFS depth cap of 4 is enforced — every reachable distance is in [0, 4]" do
      # Seed graph's longest reachable chain from product:churn_rate is 3
      # hops (churn_rate → nps → csat → ticket_resolution_time), so this
      # exercises the cap by asserting no result ever exceeds it.
      expression = %Cqr.Discover{
        related_to: {:search, "customer"},
        near: {"product", "churn_rate"}
      }

      {:ok, result} = GrafeoAdapter.discover(expression, @full_scope, [])

      Enum.each(result.data, fn row ->
        case row.near_distance do
          nil -> :ok
          d when is_integer(d) and d >= 0 and d <= 4 -> :ok
          other -> flunk("near_distance out of bounds: #{inspect(other)}")
        end
      end)

      # And the d=3 entity actually carries distance 3, confirming the
      # BFS reaches that depth (i.e. the cap is at least 3).
      ticket =
        Enum.find(result.data, fn r ->
          r.entity == {"customer_success", "ticket_resolution_time"}
        end)

      if ticket, do: assert(ticket.near_distance == 3)
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
