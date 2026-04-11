defmodule Cqr.Integration.CrossPrimitiveTest do
  @moduledoc """
  Cross-primitive integration tests.

  Verifies that TRACE, SIGNAL, and REFRESH interoperate correctly with
  each other and with the existing RESOLVE / DISCOVER / ASSERT / CERTIFY
  primitives. These tests exercise realistic multi-step workflows an
  agent would run in production.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine
  alias Cqr.Grafeo.Server, as: GrafeoServer

  @product_context %{scope: ["company", "product"], agent_id: "twin:xp_product"}
  @root_context %{scope: ["company"], agent_id: "twin:xp_root"}

  setup do
    cleanup()
    on_exit(&cleanup/0)
    :ok
  end

  defp cleanup do
    for ns <- ["test_xp"] do
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'})-[r]-() DELETE r")
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'}) DELETE e")
      GrafeoServer.query("MATCH (r:AssertionRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:CertificationRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:SignalRecord {entity_namespace: '#{ns}'}) DELETE r")
    end

    :ok
  end

  defp assert_fixture(name, opts \\ []) do
    derived = Keyword.get(opts, :derived_from, ["entity:product:churn_rate"])

    expr =
      ~s(ASSERT entity:test_xp:#{name} TYPE observation ) <>
        ~s(DESCRIPTION "cross-primitive fixture #{name}" ) <>
        ~s(INTENT "cross-primitive test" ) <>
        ~s(DERIVED_FROM #{Enum.join(derived, ", ")})

    Engine.execute(expr, @product_context)
  end

  describe "ASSERT + SIGNAL + TRACE" do
    test "TRACE shows both AssertionRecord and SignalRecord" do
      assert {:ok, _} = assert_fixture("x01")

      signal_expr =
        ~s(SIGNAL reputation ON entity:test_xp:x01 SCORE 0.7 ) <>
          ~s(EVIDENCE "quality check after assertion")

      assert {:ok, _} = Engine.execute(signal_expr, @product_context)

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("TRACE entity:test_xp:x01", @product_context)

      assert row.assertion != nil
      assert row.assertion.asserted_by == "twin:xp_product"

      assert [signal] = row.signal_history
      assert signal.new_reputation == 0.7
      assert signal.evidence == "quality check after assertion"
    end
  end

  describe "ASSERT + CERTIFY + SIGNAL + TRACE" do
    test "full provenance chain in one trace row" do
      assert {:ok, _} = assert_fixture("x02")

      entity_ref = "entity:test_xp:x02"

      assert {:ok, _} = Engine.execute("CERTIFY #{entity_ref} STATUS proposed", @product_context)

      assert {:ok, _} =
               Engine.execute("CERTIFY #{entity_ref} STATUS under_review", @product_context)

      assert {:ok, _} =
               Engine.execute(
                 ~s(CERTIFY #{entity_ref} STATUS certified AUTHORITY "twin:reviewer" EVIDENCE "reviewed"),
                 @product_context
               )

      signal_expr =
        ~s(SIGNAL reputation ON #{entity_ref} SCORE 0.55 ) <>
          ~s(EVIDENCE "reputation reassessment")

      assert {:ok, _} = Engine.execute(signal_expr, @product_context)

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("TRACE #{entity_ref}", @product_context)

      assert row.assertion != nil
      assert length(row.certification_history) == 3
      assert [%{new_reputation: 0.55}] = row.signal_history

      assert row.current_state.certified_by == "twin:reviewer"
    end
  end

  describe "REFRESH + SIGNAL + RESOLVE" do
    test "degrade a stale source, observe in RESOLVE" do
      # churn_rate is seeded at 12h freshness with reputation 0.87.
      # Simulate: the analyst finds the source is stale and downgrades it.
      signal_expr =
        ~s(SIGNAL reputation ON entity:product:churn_rate SCORE 0.4 ) <>
          ~s(EVIDENCE "source pipeline is behind")

      assert {:ok, _} = Engine.execute(signal_expr, @product_context)

      assert {:ok, %Cqr.Result{data: [entity]}} =
               Engine.execute("RESOLVE entity:product:churn_rate", @product_context)

      assert entity.reputation == 0.4

      # Restore seeded reputation to not bleed into other tests.
      GrafeoServer.query(
        "MATCH (e:Entity {namespace: 'product', name: 'churn_rate'}) SET e.reputation = 0.87"
      )

      GrafeoServer.query(
        "MATCH (sr:SignalRecord {entity_namespace: 'product', entity_name: 'churn_rate'})" <>
          " WHERE sr.agent_id = 'twin:xp_product'" <>
          " DELETE sr"
      )

      GrafeoServer.query(
        "MATCH (e:Entity {namespace: 'product', name: 'churn_rate'})-[r:SIGNAL_EVENT]->()" <>
          " DELETE r"
      )
    end
  end

  describe "full workflow: REFRESH -> SIGNAL -> DISCOVER -> ASSERT -> CERTIFY -> TRACE" do
    test "end-to-end agent loop exercises every primitive" do
      # Step 1: REFRESH - scan for stale items. Non-empty at threshold 1h.
      assert {:ok, refresh_result} =
               Engine.execute(
                 "REFRESH CHECK active_context WITHIN scope:company:product WHERE age > 24h RETURN stale_items",
                 @root_context
               )

      refute Enum.empty?(refresh_result.data)

      # Step 2: SIGNAL - pick a stale item and downgrade it.
      stale_entity_ref = List.first(refresh_result.data).entity

      signal_expr =
        ~s(SIGNAL reputation ON #{stale_entity_ref} SCORE 0.35 ) <>
          ~s(EVIDENCE "identified via refresh scan")

      assert {:ok, _} = Engine.execute(signal_expr, @product_context)

      # Step 3: DISCOVER - what's related to the stale entity.
      discover_expr = "DISCOVER concepts RELATED TO #{stale_entity_ref} DEPTH 2"
      assert {:ok, %Cqr.Result{}} = Engine.execute(discover_expr, @product_context)

      # Step 4: ASSERT a recommendation derived from the stale source.
      assert_expr =
        ~s(ASSERT entity:test_xp:x03_reco TYPE recommendation ) <>
          ~s(DESCRIPTION "refresh pipeline for stale source" ) <>
          ~s(INTENT "remediate stale context identified in refresh loop" ) <>
          ~s(DERIVED_FROM #{stale_entity_ref})

      assert {:ok, _} = Engine.execute(assert_expr, @product_context)

      # Step 5: CERTIFY the recommendation through the lifecycle.
      reco_ref = "entity:test_xp:x03_reco"

      assert {:ok, _} = Engine.execute("CERTIFY #{reco_ref} STATUS proposed", @product_context)

      assert {:ok, _} =
               Engine.execute("CERTIFY #{reco_ref} STATUS under_review", @product_context)

      assert {:ok, _} =
               Engine.execute(
                 ~s(CERTIFY #{reco_ref} STATUS certified AUTHORITY "twin:xp_reviewer" EVIDENCE "approved remediation"),
                 @product_context
               )

      # Step 6: TRACE - the recommendation should have its assertion,
      # the certification lifecycle, and the stale source in its chain.
      assert {:ok, %Cqr.Result{data: [trace_row]}} =
               Engine.execute("TRACE #{reco_ref}", @product_context)

      assert trace_row.assertion != nil
      assert length(trace_row.certification_history) == 3
      chain_entities = Enum.map(trace_row.derived_from_chain, & &1.entity)
      assert stale_entity_ref in chain_entities

      # Cleanup: restore seeded reputation and drop signal we wrote.
      {ns, name} =
        stale_entity_ref
        |> String.replace_prefix("entity:", "")
        |> String.split(":")
        |> then(fn [a, b] -> {a, b} end)

      GrafeoServer.query(
        "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'})-[r:SIGNAL_EVENT]->() DELETE r"
      )

      GrafeoServer.query(
        "MATCH (sr:SignalRecord {entity_namespace: '#{ns}', entity_name: '#{name}'})" <>
          " WHERE sr.agent_id = 'twin:xp_product' DELETE sr"
      )
    end
  end
end
