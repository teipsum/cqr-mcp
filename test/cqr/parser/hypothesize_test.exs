defmodule Cqr.Parser.HypothesizeTest do
  use ExUnit.Case, async: true

  alias Cqr.Parser

  describe "HYPOTHESIZE basic" do
    test "parses entity + single CHANGE clause" do
      assert {:ok,
              %Cqr.Hypothesize{
                entity: {"product", "churn_rate"},
                changes: [%{field: :reputation, value: 0.2}]
              }} =
               Parser.parse("HYPOTHESIZE entity:product:churn_rate CHANGE reputation TO 0.20")
    end

    test "applies default depth 2 and decay 0.7 when omitted" do
      assert {:ok, %Cqr.Hypothesize{depth: 2, decay: 0.7}} =
               Parser.parse("HYPOTHESIZE entity:product:churn_rate CHANGE reputation TO 0.20")
    end
  end

  describe "HYPOTHESIZE optional clauses" do
    test "parses DEPTH and DECAY" do
      assert {:ok, %Cqr.Hypothesize{depth: 4, decay: 0.5}} =
               Parser.parse(
                 "HYPOTHESIZE entity:product:churn_rate " <>
                   "CHANGE reputation TO 0.10 DEPTH 4 DECAY 0.50"
               )
    end

    test "tolerates clause reordering" do
      assert {:ok, %Cqr.Hypothesize{depth: 3, decay: 0.9, changes: [%{value: 0.4}]}} =
               Parser.parse(
                 "HYPOTHESIZE entity:product:churn_rate " <>
                   "DEPTH 3 DECAY 0.90 CHANGE reputation TO 0.40"
               )
    end
  end

  describe "HYPOTHESIZE error handling" do
    test "missing CHANGE field rejects" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("HYPOTHESIZE entity:product:churn_rate CHANGE foo TO 0.10")
    end

    test "missing TO keyword rejects" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("HYPOTHESIZE entity:product:churn_rate CHANGE reputation 0.10")
    end

    test "typo in keyword surfaces guidance" do
      assert {:error, %Cqr.Error{retry_guidance: guidance}} =
               Parser.parse("HYPOTHESIS entity:product:churn_rate CHANGE reputation TO 0.10")

      assert guidance =~ "HYPOTHESIZE"
    end
  end
end
