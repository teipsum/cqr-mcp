defmodule Cqr.Integration.AnchorTest do
  @moduledoc """
  Integration tests for the ANCHOR primitive.

  Covers the full path: parser -> Cqr.Engine -> Cqr.Engine.Anchor ->
  Cqr.Adapter.Grafeo -> Grafeo reads -> %Cqr.Result{} with the
  composite chain assessment.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine

  @company_context %{scope: ["company"], agent_id: "twin:anchor_root"}
  @product_context %{scope: ["company", "product"], agent_id: "twin:anchor_product"}
  @finance_context %{scope: ["company", "finance"], agent_id: "twin:anchor_finance"}

  describe "ANCHOR on seeded chain" do
    test "resolves every link and computes weakest-link + average" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "ANCHOR entity:finance:arr, entity:product:churn_rate",
                 @company_context
               )

      assert row.chain == ["entity:finance:arr", "entity:product:churn_rate"]
      assert row.missing == []
      assert row.weakest_link_confidence == 0.87
      assert_in_delta row.average_reputation, 0.91, 0.001
    end

    test "all seeded entities are uncertified and surface in recommendations" do
      {:ok, %Cqr.Result{data: [row]}} =
        Engine.execute(
          "ANCHOR entity:finance:arr, entity:product:churn_rate",
          @company_context
        )

      assert "entity:finance:arr" in row.uncertified
      assert "entity:product:churn_rate" in row.uncertified

      assert Enum.any?(row.recommendations, fn r ->
               r =~ "Certify" and r =~ "entity:finance:arr"
             end)
    end

    test "chain_confidence is reduced by uncertified penalty" do
      {:ok, %Cqr.Result{data: [row]}} =
        Engine.execute(
          "ANCHOR entity:finance:arr, entity:product:churn_rate",
          @company_context
        )

      assert row.chain_confidence < row.weakest_link_confidence
    end
  end

  describe "ANCHOR with freshness threshold" do
    test "flags entities older than the window as stale" do
      {:ok, %Cqr.Result{data: [row]}} =
        Engine.execute(
          "ANCHOR entity:finance:arr, entity:product:churn_rate WITH freshness < 6h",
          @company_context
        )

      stale_entities = Enum.map(row.stale, & &1.entity)
      assert "entity:product:churn_rate" in stale_entities
      refute "entity:finance:arr" in stale_entities

      assert Enum.any?(row.recommendations, fn r -> r =~ "Refresh" end)
    end

    test "no stale flags when window is generous" do
      {:ok, %Cqr.Result{data: [row]}} =
        Engine.execute(
          "ANCHOR entity:finance:arr, entity:product:churn_rate WITH freshness < 7d",
          @company_context
        )

      assert row.stale == []
    end
  end

  describe "ANCHOR with reputation threshold" do
    test "flags entities below the minimum as below_reputation" do
      {:ok, %Cqr.Result{data: [row]}} =
        Engine.execute(
          "ANCHOR entity:finance:arr, entity:product:churn_rate WITH reputation > 0.9",
          @company_context
        )

      low = Enum.map(row.below_reputation, & &1.entity)
      assert "entity:product:churn_rate" in low
      refute "entity:finance:arr" in low

      assert Enum.any?(row.recommendations, fn r -> r =~ "reputation" end)
    end
  end

  describe "ANCHOR — rationale" do
    test "FOR rationale is surfaced on the assessment and in provenance" do
      {:ok, %Cqr.Result{data: [row], quality: q}} =
        Engine.execute(
          ~s(ANCHOR entity:finance:arr FOR "Q4 board review"),
          @finance_context
        )

      assert row.rationale == "Q4 board review"
      assert q.provenance =~ "Q4 board review"
    end
  end

  describe "ANCHOR — missing entities" do
    test "nonexistent entity is flagged in missing, not in resolved" do
      {:ok, %Cqr.Result{data: [row]}} =
        Engine.execute(
          "ANCHOR entity:finance:arr, entity:finance:does_not_exist",
          @company_context
        )

      assert "entity:finance:does_not_exist" in row.missing
      assert row.weakest_link_confidence == 0.0

      assert Enum.any?(row.recommendations, fn r ->
               r =~ "missing" and r =~ "entity:finance:does_not_exist"
             end)
    end

    test "entity outside the agent scope is treated as missing" do
      # product agent cannot see finance entities
      {:ok, %Cqr.Result{data: [row]}} =
        Engine.execute("ANCHOR entity:finance:arr", @product_context)

      assert "entity:finance:arr" in row.missing
    end
  end

  describe "ANCHOR — quality envelope" do
    test "quality.reputation mirrors weakest_link_confidence" do
      {:ok, %Cqr.Result{data: [row], quality: q}} =
        Engine.execute(
          "ANCHOR entity:finance:arr, entity:product:churn_rate",
          @company_context
        )

      assert q.reputation == row.weakest_link_confidence
      assert q.confidence == row.chain_confidence
      assert q.provenance =~ "ANCHOR"
    end
  end

  describe "ANCHOR — single entity" do
    test "produces a degenerate chain with floor equal to that entity's reputation" do
      {:ok, %Cqr.Result{data: [row]}} =
        Engine.execute("ANCHOR entity:finance:arr", @finance_context)

      assert row.chain == ["entity:finance:arr"]
      assert row.weakest_link_confidence == 0.95
      assert row.average_reputation == 0.95
    end
  end
end
