defmodule Cqr.Integration.AwarenessTest do
  @moduledoc """
  Integration tests for the AWARENESS primitive.

  Covers the full path: parser -> Cqr.Engine -> Cqr.Engine.Awareness ->
  Cqr.Adapter.Grafeo -> Grafeo audit-node reads -> %Cqr.Result{} with
  one row per agent observed in the visible scopes.

  The fixtures write ASSERT / SIGNAL audit nodes into the
  `test_awareness` namespace so reruns are deterministic.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine
  alias Cqr.Grafeo.Server, as: GrafeoServer

  @root_context %{scope: ["company"], agent_id: "twin:awareness_root"}
  @product_context %{scope: ["company", "product"], agent_id: "twin:awareness_product"}
  @hr_context %{scope: ["company", "hr"], agent_id: "twin:awareness_hr"}

  setup do
    cleanup()
    on_exit(&cleanup/0)
    :ok
  end

  defp cleanup do
    for ns <- ["test_awareness"] do
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'})-[r]-() DELETE r")
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'}) DELETE e")
      GrafeoServer.query("MATCH (r:AssertionRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:CertificationRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:SignalRecord {entity_namespace: '#{ns}'}) DELETE r")
    end

    # Roll back side-effects on seeded entities used as SIGNAL targets,
    # so cross-test isolation holds and TRACE on churn_rate stays clean.
    GrafeoServer.query(
      "MATCH (e:Entity {namespace: 'product', name: 'churn_rate'})" <>
        "-[r:SIGNAL_EVENT]->(sr:SignalRecord) DELETE r"
    )

    GrafeoServer.query("MATCH (sr:SignalRecord) WHERE sr.agent_id CONTAINS 'awareness' DELETE sr")

    GrafeoServer.query(
      "MATCH (e:Entity {namespace: 'product', name: 'churn_rate'}) SET e.reputation = 0.87"
    )

    :ok
  end

  defp assert_fixture(name, opts) do
    derived = Keyword.get(opts, :derived_from, ["entity:product:churn_rate"])
    context = Keyword.fetch!(opts, :context)
    description = Keyword.get(opts, :description, "awareness fixture #{name}")
    intent = Keyword.get(opts, :intent, "awareness test fixture")

    expr =
      ~s(ASSERT entity:test_awareness:#{name} TYPE observation ) <>
        ~s(DESCRIPTION "#{description}" ) <>
        ~s(INTENT "#{intent}" ) <>
        ~s(DERIVED_FROM #{Enum.join(derived, ", ")})

    Engine.execute(expr, context)
  end

  defp agent_ids(result), do: Enum.map(result.data, & &1.agent_id)

  describe "AWARENESS — empty graph" do
    test "returns empty data when no audit records exist for visible scopes" do
      assert {:ok, %Cqr.Result{} = result} =
               Engine.execute("AWARENESS active_agents", @hr_context)

      refute Enum.any?(result.data, fn row ->
               row.agent_id == "twin:awareness_product"
             end)
    end
  end

  describe "AWARENESS — observes ASSERT activity" do
    test "asserter shows up with the entity touched and the intent declared" do
      assert {:ok, _} =
               assert_fixture("a01_asserted",
                 context: @product_context,
                 intent: "investigate retention drop"
               )

      assert {:ok, %Cqr.Result{} = result} =
               Engine.execute("AWARENESS active_agents", @product_context)

      row =
        Enum.find(result.data, fn r -> r.agent_id == "twin:awareness_product" end)

      assert row != nil
      assert "entity:test_awareness:a01_asserted" in row.entities_touched
      assert "investigate retention drop" in row.intents
      assert row.activity_count >= 1
      assert is_binary(row.last_seen)
    end

    test "two agents asserting in the same scope both appear" do
      assert {:ok, _} =
               assert_fixture("a02_one",
                 context: %{
                   scope: ["company", "product"],
                   agent_id: "twin:awareness_alpha"
                 }
               )

      assert {:ok, _} =
               assert_fixture("a02_two",
                 context: %{
                   scope: ["company", "product"],
                   agent_id: "twin:awareness_beta"
                 }
               )

      assert {:ok, %Cqr.Result{} = result} =
               Engine.execute("AWARENESS active_agents", @root_context)

      ids = agent_ids(result)
      assert "twin:awareness_alpha" in ids
      assert "twin:awareness_beta" in ids
    end
  end

  describe "AWARENESS — observes SIGNAL activity" do
    test "signaler is surfaced with the signal payload" do
      assert {:ok, _} =
               Engine.execute(
                 ~s(SIGNAL reputation ON entity:product:churn_rate ) <>
                   ~s(SCORE 0.92 EVIDENCE "validated against fresh pipeline"),
                 @product_context
               )

      assert {:ok, %Cqr.Result{} = result} =
               Engine.execute("AWARENESS active_agents", @product_context)

      row =
        Enum.find(result.data, fn r -> r.agent_id == "twin:awareness_product" end)

      assert row != nil
      assert "entity:product:churn_rate" in row.entities_touched
      assert Enum.any?(row.signals, fn s -> s.new_reputation == 0.92 end)
    end
  end

  describe "AWARENESS — scope narrowing" do
    test "WITHIN narrows the scan to the requested subtree" do
      assert {:ok, _} =
               assert_fixture("a03_product",
                 context: %{
                   scope: ["company", "product"],
                   agent_id: "twin:awareness_product_only"
                 }
               )

      assert {:ok, _} =
               assert_fixture("a03_hr",
                 context: %{scope: ["company", "hr"], agent_id: "twin:awareness_hr_only"},
                 derived_from: ["entity:hr:headcount"]
               )

      assert {:ok, %Cqr.Result{} = result} =
               Engine.execute(
                 "AWARENESS active_agents WITHIN scope:company:product",
                 @root_context
               )

      ids = agent_ids(result)
      assert "twin:awareness_product_only" in ids
      refute "twin:awareness_hr_only" in ids
    end

    test "agent cannot escape its own sandbox via WITHIN" do
      assert {:error, %Cqr.Error{code: :scope_access}} =
               Engine.execute(
                 "AWARENESS active_agents WITHIN scope:company:hr",
                 @product_context
               )
    end
  end

  describe "AWARENESS — sibling isolation" do
    test "product agent does not see hr-scope assertions" do
      assert {:ok, _} =
               assert_fixture("a04_hr",
                 context: %{scope: ["company", "hr"], agent_id: "twin:awareness_hr_actor"},
                 derived_from: ["entity:hr:headcount"]
               )

      assert {:ok, %Cqr.Result{} = result} =
               Engine.execute("AWARENESS active_agents", @product_context)

      refute "twin:awareness_hr_actor" in agent_ids(result)
    end
  end

  describe "AWARENESS — ranking and limit" do
    test "results are sorted by activity_count descending" do
      for i <- 1..3 do
        assert {:ok, _} =
                 assert_fixture("a05_busy_#{i}",
                   context: %{
                     scope: ["company", "product"],
                     agent_id: "twin:awareness_busy"
                   }
                 )
      end

      assert {:ok, _} =
               assert_fixture("a05_quiet",
                 context: %{
                   scope: ["company", "product"],
                   agent_id: "twin:awareness_quiet"
                 }
               )

      assert {:ok, %Cqr.Result{} = result} =
               Engine.execute("AWARENESS active_agents", @root_context)

      counts = Enum.map(result.data, & &1.activity_count)
      assert counts == Enum.sort(counts, :desc)

      busy = Enum.find(result.data, fn r -> r.agent_id == "twin:awareness_busy" end)
      quiet = Enum.find(result.data, fn r -> r.agent_id == "twin:awareness_quiet" end)
      assert busy.activity_count >= quiet.activity_count
    end

    test "LIMIT caps the number of agents returned" do
      for i <- 1..3 do
        assert {:ok, _} =
                 assert_fixture("a06_limit_#{i}",
                   context: %{
                     scope: ["company", "product"],
                     agent_id: "twin:awareness_limit_#{i}"
                   }
                 )
      end

      assert {:ok, %Cqr.Result{} = result} =
               Engine.execute("AWARENESS active_agents LIMIT 1", @root_context)

      assert length(result.data) <= 1
    end
  end

  describe "AWARENESS — time window" do
    test "OVER last <duration> filters audit events to the recent window" do
      assert {:ok, _} =
               assert_fixture("a07_recent",
                 context: %{
                   scope: ["company", "product"],
                   agent_id: "twin:awareness_recent"
                 }
               )

      assert {:ok, %Cqr.Result{} = result} =
               Engine.execute(
                 "AWARENESS active_agents OVER last 1h",
                 @root_context
               )

      assert "twin:awareness_recent" in agent_ids(result)
    end
  end

  describe "AWARENESS — quality envelope" do
    test "result carries provenance and freshness" do
      assert {:ok, _} = assert_fixture("a08_quality", context: @product_context)

      assert {:ok, %Cqr.Result{quality: quality, sources: sources}} =
               Engine.execute("AWARENESS active_agents", @product_context)

      assert "grafeo" in sources
      assert quality.provenance =~ "AWARENESS"
      assert %DateTime{} = quality.freshness
    end
  end
end
