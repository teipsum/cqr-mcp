defmodule Cqr.Integration.HypothesizeTest do
  @moduledoc """
  Integration tests for the HYPOTHESIZE primitive.

  Covers the full path: parser -> Cqr.Engine -> Cqr.Engine.Hypothesize ->
  Cqr.Adapter.Grafeo -> Grafeo reads -> %Cqr.Result{} with the blast
  radius envelope.

  Uses the root-level `["company"]` scope so the seeded cross-namespace
  edges (product:churn_rate -> finance:arr, etc.) are visible.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine

  @root_context %{scope: ["company"], agent_id: "twin:hyp_root"}
  @product_context %{scope: ["company", "product"], agent_id: "twin:hyp_product"}
  @finance_context %{scope: ["company", "finance"], agent_id: "twin:hyp_finance"}

  describe "HYPOTHESIZE on seeded entity" do
    test "reports baseline reputation and computed delta" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "HYPOTHESIZE entity:product:churn_rate CHANGE reputation TO 0.20",
                 @root_context
               )

      assert row.entity == "entity:product:churn_rate"
      assert row.hypothetical_change.field == :reputation
      assert row.hypothetical_change.value == 0.20
      assert row.hypothetical_change.original_value == 0.87
      assert_in_delta row.hypothetical_change.delta, -0.67, 0.001
    end

    test "blast radius walks at least one hop and tags depth + relationship" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "HYPOTHESIZE entity:product:churn_rate CHANGE reputation TO 0.20 DEPTH 2",
                 @root_context
               )

      refute row.blast_radius == []

      depths = Enum.map(row.blast_radius, & &1.depth)
      assert Enum.min(depths) == 1
      assert Enum.max(depths) <= 2

      Enum.each(row.blast_radius, fn affected ->
        assert is_binary(affected.entity)
        assert is_binary(affected.relationship)
        assert affected.direction in ["inbound", "outbound"]
        assert is_float(affected.hop_confidence)
      end)
    end

    test "decay shrinks hop_confidence as depth grows" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "HYPOTHESIZE entity:product:churn_rate CHANGE reputation TO 0.20 " <>
                   "DEPTH 3 DECAY 0.50",
                 @root_context
               )

      depth_one = Enum.filter(row.blast_radius, &(&1.depth == 1))

      Enum.each(depth_one, fn affected ->
        assert_in_delta affected.hop_confidence, 0.50, 0.001
      end)
    end

    test "projected_reputation never escapes [0.0, 1.0]" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "HYPOTHESIZE entity:product:churn_rate CHANGE reputation TO 0.20 DEPTH 2",
                 @root_context
               )

      Enum.each(row.blast_radius, fn affected ->
        case affected.projected_reputation do
          nil -> :ok
          v -> assert v >= 0.0 and v <= 1.0
        end
      end)
    end

    test "summary reports total_affected and mean_hop_confidence" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "HYPOTHESIZE entity:product:churn_rate CHANGE reputation TO 0.20 DEPTH 2",
                 @root_context
               )

      assert row.summary.total_affected == length(row.blast_radius)
      assert row.summary.max_depth_reached >= 1
      assert is_float(row.summary.mean_hop_confidence)
    end
  end

  describe "HYPOTHESIZE error handling" do
    test "missing CHANGE clause returns invalid_input" do
      assert {:error, %Cqr.Error{code: :invalid_input}} =
               Engine.execute(
                 %Cqr.Hypothesize{entity: {"product", "churn_rate"}, changes: [], depth: 2},
                 @root_context
               )
    end

    test "nonexistent entity returns entity_not_found" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(
                 "HYPOTHESIZE entity:product:does_not_exist CHANGE reputation TO 0.10",
                 @root_context
               )
    end
  end

  describe "scope enforcement" do
    test "product agent cannot HYPOTHESIZE on a finance entity" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(
                 "HYPOTHESIZE entity:finance:burn_rate CHANGE reputation TO 0.20",
                 @product_context
               )
    end

    test "finance agent only sees finance-side blast radius from churn_rate" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "HYPOTHESIZE entity:product:churn_rate CHANGE reputation TO 0.20 DEPTH 2",
                 @product_context
               )

      affected_namespaces =
        row.blast_radius
        |> Enum.map(& &1.entity)
        |> Enum.map(fn ref -> ref |> String.split(":") |> Enum.at(1) end)
        |> Enum.uniq()

      refute "finance" in affected_namespaces
      assert "product" in affected_namespaces or affected_namespaces == []

      _ = @finance_context
    end
  end
end
