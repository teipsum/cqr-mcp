defmodule Cqr.Integration.DiscoverPrefixTest do
  @moduledoc """
  Integration tests for DISCOVER prefix mode.

  When the topic matches `entity:ns:name:*` the engine performs hierarchical
  prefix enumeration: depth-first traversal following CONTAINS edges, with
  branch-level scope pruning. A node outside the agent's visible scopes
  is omitted AND its subtree is not descended, so the agent cannot infer
  the shape of the hidden subtree.

  Normal entity-anchor and free-text DISCOVER continue to work unchanged.
  """

  use ExUnit.Case

  alias Cqr.Engine

  @product_context %{scope: ["company", "product"], agent_id: "twin:product"}
  @finance_context %{scope: ["company", "finance"], agent_id: "twin:finance"}

  defp hierarchical_assert(ns_path, leaf_name) do
    ~s(ASSERT entity:#{ns_path}:#{leaf_name} TYPE derived_metric ) <>
      ~s(DESCRIPTION "Prefix fixture #{ns_path}:#{leaf_name}" ) <>
      ~s(INTENT "Testing DISCOVER prefix mode" ) <>
      ~s(DERIVED_FROM entity:product:churn_rate)
  end

  describe "DISCOVER prefix mode — happy path" do
    test "returns every descendant under the prefix at all depths" do
      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("dpfx_case1:branch_a", "leaf1"),
                 @product_context
               )

      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("dpfx_case1:branch_a", "leaf2"),
                 @product_context
               )

      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("dpfx_case1:branch_a:nested", "deep"),
                 @product_context
               )

      assert {:ok, %Cqr.Result{data: rows}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:dpfx_case1:branch_a:*",
                 @product_context
               )

      names = rows |> Enum.map(& &1.name) |> Enum.sort()
      assert "branch_a" in names
      assert "leaf1" in names
      assert "leaf2" in names
      assert "deep" in names
    end

    test "single-leaf prefix returns only the anchor" do
      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("dpfx_case2:branch_b", "only_leaf"),
                 @product_context
               )

      assert {:ok, %Cqr.Result{data: rows}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:dpfx_case2:branch_b:only_leaf:*",
                 @product_context
               )

      assert [%{name: "only_leaf"}] = rows
    end
  end

  describe "DISCOVER prefix mode — scope pruning" do
    test "branch blocked by scope is pruned (entity and subtree omitted)" do
      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("dpfx_case3:branch_a", "leaf1"),
                 @product_context
               )

      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("dpfx_case3:branch_a:nested", "deep"),
                 @product_context
               )

      # Finance has no access to the product-scoped subtree. Prefix mode
      # returns an empty result — the existence of dpfx_case3:branch_a is
      # not even surfaced.
      assert {:ok, %Cqr.Result{data: []}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:dpfx_case3:branch_a:*",
                 @finance_context
               )
    end

    test "blocked anchor is indistinguishable from nonexistent anchor" do
      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("dpfx_case4:branch_a", "leaf1"),
                 @product_context
               )

      {:ok, %Cqr.Result{data: blocked_rows}} =
        Engine.execute(
          "DISCOVER concepts RELATED TO entity:dpfx_case4:branch_a:*",
          @finance_context
        )

      {:ok, %Cqr.Result{data: missing_rows}} =
        Engine.execute(
          "DISCOVER concepts RELATED TO entity:dpfx_case4_missing:branch:*",
          @finance_context
        )

      assert blocked_rows == []
      assert missing_rows == []
    end
  end

  describe "DISCOVER prefix mode — does not affect other DISCOVER paths" do
    test "regular entity DISCOVER continues to work" do
      assert {:ok, %Cqr.Result{data: rows}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:product:churn_rate",
                 @product_context
               )

      # Returns related entities via existing relationship traversal.
      assert is_list(rows)
      refute Enum.any?(rows, fn r -> Map.get(r, :source) == "prefix" end)
    end

    test "free-text DISCOVER continues to work" do
      assert {:ok, %Cqr.Result{data: rows}} =
               Engine.execute(
                 ~s(DISCOVER concepts RELATED TO "churn"),
                 @product_context
               )

      assert is_list(rows)
      refute Enum.any?(rows, fn r -> Map.get(r, :source) == "prefix" end)
    end
  end
end
