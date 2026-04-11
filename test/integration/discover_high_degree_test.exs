defmodule Cqr.Integration.DiscoverHighDegreeTest do
  @moduledoc """
  Regression tests for the "DISCOVER outbound hangs on high-edge-count
  entities" bug.

  The root cause was an N+1 query pattern in `Cqr.Repo.Semantic`: for
  every row returned by the traversal MATCH, a second Cypher query ran
  to check scope visibility. A hub entity with N outbound edges fired
  N+1 round trips through the NIF. Past roughly 10,000 edges — and
  much earlier on slower Cypher plans — the accumulated cost pushed
  DISCOVER past the GenServer call timeout and the request appeared
  to hang indefinitely.

  The fix inlines the scope join into the traversal MATCH, uses
  `DISTINCT` to collapse the Cartesian product that a multi-scope
  target would otherwise produce, and enforces a hard `LIMIT` on the
  traversal. Every DISCOVER now runs as a single Cypher query
  regardless of edge count.

  These tests assert the end-to-end invariant: outbound DISCOVER on a
  hub entity with 100, 1_000, and 10_000 DERIVED_FROM edges must
  return within a 5-second `Task.await` window and must not include
  duplicate rows for targets reached by multiple edges.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine
  alias Cqr.Grafeo.Server, as: GrafeoServer

  @company_context %{scope: ["company"], agent_id: "twin:hd_test"}

  # Seven real entities from the seed, all in scopes visible to the
  # company-root agent. The hub's DERIVED_FROM list is built by cycling
  # through these so we can scale edge count independently of target
  # diversity.
  @seed_targets [
    "entity:product:churn_rate",
    "entity:finance:arr",
    "entity:product:nps",
    "entity:product:dau",
    "entity:product:retention_rate",
    "entity:product:time_to_value",
    "entity:product:feature_adoption"
  ]

  # Shared cleanup: test_hd hubs wire DERIVED_FROM edges into real seed
  # entities (product:churn_rate, finance:arr, …), so any lingering hub
  # would surface as an inbound neighbor on those targets and pollute
  # unrelated DISCOVER tests. Clean before every test AND on exit.
  setup do
    cleanup_test_hd()
    on_exit(&cleanup_test_hd/0)
    :ok
  end

  defp cleanup_test_hd do
    GrafeoServer.query("MATCH (e:Entity {namespace: 'test_hd'})-[r]-() DELETE r")
    GrafeoServer.query("MATCH (e:Entity {namespace: 'test_hd'}) DELETE e")

    GrafeoServer.query("MATCH (r:AssertionRecord {entity_namespace: 'test_hd'}) DELETE r")
  end

  defp assert_hub(name, edge_count) do
    derived =
      Enum.map_join(1..edge_count, ",", fn i ->
        Enum.at(@seed_targets, rem(i, length(@seed_targets)))
      end)

    expr =
      "ASSERT entity:test_hd:#{name} " <>
        "TYPE observation " <>
        "DESCRIPTION \"High-degree hub #{name}\" " <>
        "INTENT \"DISCOVER high-degree regression\" " <>
        "DERIVED_FROM " <> derived

    assert {:ok, _} = Engine.execute(expr, @company_context)
  end

  defp discover_outbound(name, timeout_ms \\ 5_000) do
    task =
      Task.async(fn ->
        Engine.execute(
          "DISCOVER concepts RELATED TO entity:test_hd:#{name} DEPTH 1 DIRECTION outbound",
          @company_context
        )
      end)

    Task.await(task, timeout_ms)
  end

  describe "high-degree outbound DISCOVER" do
    test "100 DERIVED_FROM edges: completes within Task.await timeout" do
      assert_hub("hub_100", 100)

      # Confirm the writes landed at the storage layer.
      {:ok, edges} =
        GrafeoServer.query(
          "MATCH (a:Entity {namespace: 'test_hd', name: 'hub_100'})-[r]->(b:Entity) " <>
            "RETURN b.name"
        )

      assert length(edges) == 100

      # The bug: this used to hang. The 5s timeout catches regressions
      # with a wide margin — the fixed path completes in well under
      # 100ms.
      {elapsed_us, result} = :timer.tc(fn -> discover_outbound("hub_100") end)
      elapsed_ms = elapsed_us / 1_000

      assert {:ok, %Cqr.Result{data: data}} = result

      # 100 edges cycle through 7 unique targets, so the deduplicated
      # result is exactly 7 rows — the DISTINCT projection in the
      # traversal query collapses parallel edges to the same target.
      assert length(data) == 7,
             "expected 7 distinct targets after DISTINCT, got #{length(data)}"

      target_names = data |> Enum.map(& &1.entity) |> Enum.sort()

      expected =
        @seed_targets
        |> Enum.map(fn "entity:" <> rest ->
          [ns, name] = String.split(rest, ":")
          {ns, name}
        end)
        |> Enum.sort()

      assert target_names == expected

      # Ship budget: 1s well above the observed ~1-5ms. If a future
      # regression blows this it will show up as a clear perf signal
      # without making the test flaky on slow CI.
      assert elapsed_ms < 1_000,
             "outbound DISCOVER on 100-edge hub took #{Float.round(elapsed_ms, 2)}ms " <>
               "(budget: 1000ms)"
    end

    test "1_000 DERIVED_FROM edges: completes in under 1 second" do
      assert_hub("hub_1k", 1_000)

      {elapsed_us, result} = :timer.tc(fn -> discover_outbound("hub_1k") end)
      elapsed_ms = elapsed_us / 1_000

      assert {:ok, %Cqr.Result{data: data}} = result
      assert length(data) == 7

      assert elapsed_ms < 1_000,
             "outbound DISCOVER on 1_000-edge hub took #{Float.round(elapsed_ms, 2)}ms"
    end

    test "10_000 DERIVED_FROM edges: completes in under 1 second" do
      # The hard scale test. The old N+1 path would fire 10_001 NIF
      # queries for this one DISCOVER — a pathological fan-out that
      # blew past the GenServer call timeout. The single-query path
      # is independent of edge count and returns in tens of
      # milliseconds.
      assert_hub("hub_10k", 10_000)

      {elapsed_us, result} = :timer.tc(fn -> discover_outbound("hub_10k") end)
      elapsed_ms = elapsed_us / 1_000

      assert {:ok, %Cqr.Result{data: data}} = result
      assert length(data) == 7

      assert elapsed_ms < 1_000,
             "outbound DISCOVER on 10_000-edge hub took #{Float.round(elapsed_ms, 2)}ms " <>
               "(budget: 1000ms) — likely regression to the N+1 scope-check pattern"
    end

    test "depth 2 on high-degree hub also completes without timeout" do
      # Variable-length path on a high-degree anchor must not hang
      # either. The regression target here is the same N+1 pattern;
      # depth 2 compounds it because each outbound traversal row
      # triggers its own scope check.
      assert_hub("hub_depth2", 1_000)

      task =
        Task.async(fn ->
          Engine.execute(
            "DISCOVER concepts RELATED TO entity:test_hd:hub_depth2 DEPTH 2 DIRECTION outbound",
            @company_context
          )
        end)

      assert {:ok, %Cqr.Result{}} = Task.await(task, 10_000)
    end
  end

  describe "no regressions for small-degree entities" do
    test "seed entity churn_rate still returns its 1-hop outbound neighborhood" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 1 DIRECTION outbound",
                 @company_context
               )

      entities = Enum.map(data, & &1.entity)
      assert {"product", "nps"} in entities
      assert {"finance", "arr"} in entities
    end

    test "free-text DISCOVER is unaffected by the traversal refactor" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "revenue"), @company_context)

      assert [_ | _] = data
    end
  end
end
