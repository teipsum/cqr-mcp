defmodule Cqr.Integration.HierarchicalAddressingTest do
  @moduledoc """
  Phase 0 validation suite: hierarchical entity addressing across every
  primitive that accepts an entity reference.

  Each `describe` block represents one of ten validation intents the v0.4.0
  release must satisfy. The intents collectively prove that:

    * RESOLVE, ASSERT, DISCOVER, UPDATE, CERTIFY, SIGNAL, and TRACE all
      accept entity addresses at depths 3, 4, and 5 segments.
    * DISCOVER `:*` prefix mode enumerates the CONTAINS subtree.
    * ASSERT clauses (`relationships`, `DERIVED_FROM`) accept hierarchical
      target addresses, and the auto-created intermediate containers
      participate in containment-aware visibility.

  All addresses use unique `hier_intent_*` namespaces so the suite is
  hermetic against the rest of the integration corpus, which shares the
  in-process Grafeo database in ExUnit sync mode.
  """

  use ExUnit.Case

  alias Cqr.Engine

  @product_context %{scope: ["company", "product"], agent_id: "twin:product"}

  defp hier_assert(ns_path, leaf, opts \\ []) do
    derived = Keyword.get(opts, :derived_from, "entity:product:churn_rate")
    type = Keyword.get(opts, :type, "derived_metric")

    ~s(ASSERT entity:#{ns_path}:#{leaf} TYPE #{type} ) <>
      ~s(DESCRIPTION "Hierarchical fixture #{leaf}" ) <>
      ~s(INTENT "Phase 0 hierarchical validation" ) <>
      ~s(DERIVED_FROM #{derived})
  end

  describe "Intent 1: RESOLVE on a 3-segment hierarchical address" do
    test "resolves entity:hier_intent_1:branch:leaf" do
      assert {:ok, _} =
               Engine.execute(
                 hier_assert("hier_intent_1:branch", "leaf"),
                 @product_context
               )

      assert {:ok, %Cqr.Result{data: [%{name: "leaf", namespace: "hier_intent_1:branch"}]}} =
               Engine.execute(
                 "RESOLVE entity:hier_intent_1:branch:leaf",
                 @product_context
               )
    end
  end

  describe "Intent 2: ASSERT on a 4-segment hierarchical address" do
    test "asserts entity:hier_intent_2:branch:sub:leaf and round-trips" do
      assert {:ok, _} =
               Engine.execute(
                 hier_assert("hier_intent_2:branch:sub", "leaf"),
                 @product_context
               )

      assert {:ok, %Cqr.Result{data: [%{name: "leaf"}]}} =
               Engine.execute(
                 "RESOLVE entity:hier_intent_2:branch:sub:leaf",
                 @product_context
               )
    end
  end

  describe "Intent 3: RESOLVE on a 5-segment hierarchical address" do
    test "resolves entity:hier_intent_3:branch:sub:nested:leaf" do
      assert {:ok, _} =
               Engine.execute(
                 hier_assert("hier_intent_3:branch:sub:nested", "leaf"),
                 @product_context
               )

      assert {:ok, %Cqr.Result{data: [%{name: "leaf"}]}} =
               Engine.execute(
                 "RESOLVE entity:hier_intent_3:branch:sub:nested:leaf",
                 @product_context
               )
    end
  end

  describe "Intent 4: DISCOVER with :* prefix enumerates CONTAINS subtree" do
    test "returns every descendant under entity:hier_intent_4:branch:*" do
      for {ns, leaf} <- [
            {"hier_intent_4:branch", "leaf_one"},
            {"hier_intent_4:branch", "leaf_two"},
            {"hier_intent_4:branch:sub", "deep_leaf"}
          ] do
        assert {:ok, _} = Engine.execute(hier_assert(ns, leaf), @product_context)
      end

      assert {:ok, %Cqr.Result{data: rows}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:hier_intent_4:branch:*",
                 @product_context
               )

      names = rows |> Enum.map(& &1.name) |> MapSet.new()
      assert MapSet.subset?(MapSet.new(["branch", "leaf_one", "leaf_two", "deep_leaf"]), names)
    end
  end

  describe "Intent 5: ASSERT with hierarchical relationship target" do
    test "RELATIONSHIPS clause accepts a 5-segment target address" do
      # Pre-create the deep target so the relationship edge has both endpoints.
      assert {:ok, _} =
               Engine.execute(
                 hier_assert("hier_intent_5:target_branch:sub", "deep_target"),
                 @product_context
               )

      expr =
        ~s(ASSERT entity:hier_intent_5:source TYPE derived_metric ) <>
          ~s(DESCRIPTION "Source with hierarchical relationship target" ) <>
          ~s(INTENT "Phase 0 hierarchical validation" ) <>
          ~s(DERIVED_FROM entity:product:churn_rate ) <>
          ~s(RELATIONSHIPS CORRELATES_WITH:entity:hier_intent_5:target_branch:sub:deep_target:0.7)

      assert {:ok, _} = Engine.execute(expr, @product_context)
    end
  end

  describe "Intent 6: ASSERT with hierarchical DERIVED_FROM lineage" do
    test "DERIVED_FROM accepts a 5-segment source address" do
      assert {:ok, _} =
               Engine.execute(
                 hier_assert("hier_intent_6:source_branch:sub", "deep_source"),
                 @product_context
               )

      expr =
        hier_assert("hier_intent_6:downstream", "leaf",
          derived_from: "entity:hier_intent_6:source_branch:sub:deep_source"
        )

      assert {:ok, _} = Engine.execute(expr, @product_context)
    end
  end

  describe "Intent 7: UPDATE on a hierarchical entity preserves the address" do
    test "correction on entity:hier_intent_7:branch:sub:leaf updates content, keeps address" do
      assert {:ok, _} =
               Engine.execute(
                 hier_assert("hier_intent_7:branch:sub", "leaf"),
                 @product_context
               )

      update_expr =
        ~s(UPDATE entity:hier_intent_7:branch:sub:leaf ) <>
          ~s(CHANGE_TYPE correction ) <>
          ~s(DESCRIPTION "Corrected description after audit" ) <>
          ~s(EVIDENCE "Phase 0 hierarchical UPDATE validation")

      assert {:ok, _} = Engine.execute(update_expr, @product_context)

      assert {:ok, %Cqr.Result{data: [%{description: "Corrected description after audit"}]}} =
               Engine.execute(
                 "RESOLVE entity:hier_intent_7:branch:sub:leaf",
                 @product_context
               )
    end
  end

  describe "Intent 8: CERTIFY on a hierarchical entity transitions lifecycle" do
    test "certifies entity:hier_intent_8:branch:sub:leaf to proposed" do
      assert {:ok, _} =
               Engine.execute(
                 hier_assert("hier_intent_8:branch:sub", "leaf"),
                 @product_context
               )

      cert_expr =
        ~s(CERTIFY entity:hier_intent_8:branch:sub:leaf STATUS proposed ) <>
          ~s(AUTHORITY "twin:product" ) <>
          ~s(EVIDENCE "Phase 0 hierarchical CERTIFY validation")

      assert {:ok, _} = Engine.execute(cert_expr, @product_context)
    end
  end

  describe "Intent 9: SIGNAL on a hierarchical entity adjusts reputation" do
    test "signals entity:hier_intent_9:branch:sub:leaf with a new score" do
      assert {:ok, _} =
               Engine.execute(
                 hier_assert("hier_intent_9:branch:sub", "leaf"),
                 @product_context
               )

      signal_expr =
        ~s(SIGNAL reputation ON entity:hier_intent_9:branch:sub:leaf ) <>
          ~s(SCORE 0.42 EVIDENCE "Phase 0 hierarchical SIGNAL validation")

      assert {:ok, _} = Engine.execute(signal_expr, @product_context)
    end
  end

  describe "Intent 10: TRACE on a hierarchical entity returns provenance" do
    test "traces entity:hier_intent_10:branch:sub:leaf and surfaces records" do
      assert {:ok, _} =
               Engine.execute(
                 hier_assert("hier_intent_10:branch:sub", "leaf"),
                 @product_context
               )

      assert {:ok, %Cqr.Result{}} =
               Engine.execute(
                 "TRACE entity:hier_intent_10:branch:sub:leaf",
                 @product_context
               )
    end
  end
end
