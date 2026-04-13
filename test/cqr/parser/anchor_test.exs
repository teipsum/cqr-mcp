defmodule Cqr.Parser.AnchorTest do
  use ExUnit.Case, async: true

  alias Cqr.Parser

  describe "ANCHOR — minimal" do
    test "single entity" do
      assert {:ok, %Cqr.Anchor{entities: [{"finance", "arr"}]}} =
               Parser.parse("ANCHOR entity:finance:arr")
    end

    test "two entities" do
      assert {:ok, %Cqr.Anchor{entities: entities}} =
               Parser.parse("ANCHOR entity:finance:arr, entity:product:churn_rate")

      assert entities == [{"finance", "arr"}, {"product", "churn_rate"}]
    end

    test "three entities" do
      assert {:ok, %Cqr.Anchor{entities: entities}} =
               Parser.parse(
                 "ANCHOR entity:finance:arr, entity:product:churn_rate, entity:company:health_score"
               )

      assert entities == [
               {"finance", "arr"},
               {"product", "churn_rate"},
               {"company", "health_score"}
             ]
    end

    test "entities without spaces after commas" do
      assert {:ok, %Cqr.Anchor{entities: entities}} =
               Parser.parse("ANCHOR entity:finance:arr,entity:product:churn")

      assert entities == [{"finance", "arr"}, {"product", "churn"}]
    end
  end

  describe "ANCHOR — FOR clause" do
    test "rationale" do
      {:ok, result} =
        Parser.parse(~s(ANCHOR entity:finance:arr FOR "Q4 health assessment"))

      assert result.rationale == "Q4 health assessment"
    end
  end

  describe "ANCHOR — WITH clauses" do
    test "freshness threshold" do
      {:ok, result} =
        Parser.parse("ANCHOR entity:finance:arr WITH freshness < 24h")

      assert result.freshness == {24, :h}
    end

    test "reputation threshold" do
      {:ok, result} =
        Parser.parse("ANCHOR entity:finance:arr WITH reputation > 0.7")

      assert result.reputation == 0.7
    end

    test "both WITH clauses" do
      {:ok, result} =
        Parser.parse("ANCHOR entity:finance:arr WITH freshness < 12h WITH reputation > 0.8")

      assert result.freshness == {12, :h}
      assert result.reputation == 0.8
    end
  end

  describe "ANCHOR — full expressions" do
    test "all clauses" do
      {:ok, result} =
        Parser.parse(
          ~s(ANCHOR entity:finance:arr, entity:product:churn FOR "board review" WITH freshness < 24h WITH reputation > 0.7)
        )

      assert result.entities == [{"finance", "arr"}, {"product", "churn"}]
      assert result.rationale == "board review"
      assert result.freshness == {24, :h}
      assert result.reputation == 0.7
    end

    test "order-insensitive" do
      {:ok, result} =
        Parser.parse(
          ~s(ANCHOR entity:finance:arr WITH reputation > 0.5 FOR "note" WITH freshness < 7d)
        )

      assert result.rationale == "note"
      assert result.reputation == 0.5
      assert result.freshness == {7, :d}
    end
  end

  describe "ANCHOR — nil defaults" do
    test "optional fields are nil when absent" do
      {:ok, result} = Parser.parse("ANCHOR entity:finance:arr")
      assert result.rationale == nil
      assert result.freshness == nil
      assert result.reputation == nil
    end
  end
end
