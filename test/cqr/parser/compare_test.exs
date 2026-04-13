defmodule Cqr.Parser.CompareTest do
  use ExUnit.Case, async: true

  alias Cqr.Parser

  describe "COMPARE — minimal" do
    test "two entities" do
      assert {:ok, %Cqr.Compare{} = result} =
               Parser.parse("COMPARE entity:product:churn_rate, entity:product:nps")

      assert result.entities == [{"product", "churn_rate"}, {"product", "nps"}]
    end

    test "three entities" do
      assert {:ok, %Cqr.Compare{entities: entities}} =
               Parser.parse(
                 "COMPARE entity:product:churn_rate, entity:product:nps, entity:finance:arr"
               )

      assert entities == [
               {"product", "churn_rate"},
               {"product", "nps"},
               {"finance", "arr"}
             ]
    end

    test "no whitespace after commas" do
      assert {:ok, %Cqr.Compare{entities: entities}} =
               Parser.parse("COMPARE entity:product:churn_rate,entity:product:nps")

      assert entities == [{"product", "churn_rate"}, {"product", "nps"}]
    end

    test "extra whitespace around commas" do
      assert {:ok, %Cqr.Compare{entities: entities}} =
               Parser.parse("COMPARE entity:product:churn_rate ,  entity:product:nps")

      assert entities == [{"product", "churn_rate"}, {"product", "nps"}]
    end

    test "default include is all three facets" do
      assert {:ok, %Cqr.Compare{include: include}} =
               Parser.parse("COMPARE entity:product:churn_rate, entity:product:nps")

      assert include == [:relationships, :properties, :quality]
    end
  end

  describe "COMPARE — INCLUDE clause" do
    test "single facet" do
      assert {:ok, %Cqr.Compare{include: [:relationships]}} =
               Parser.parse(
                 "COMPARE entity:product:churn_rate, entity:product:nps INCLUDE relationships"
               )
    end

    test "two facets" do
      assert {:ok, %Cqr.Compare{include: [:relationships, :quality]}} =
               Parser.parse(
                 "COMPARE entity:product:churn_rate, entity:product:nps INCLUDE relationships, quality"
               )
    end

    test "all three facets" do
      assert {:ok, %Cqr.Compare{include: [:properties, :relationships, :quality]}} =
               Parser.parse(
                 "COMPARE entity:product:churn_rate, entity:product:nps INCLUDE properties, relationships, quality"
               )
    end
  end

  describe "COMPARE — error cases" do
    test "single entity rejected" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("COMPARE entity:product:churn_rate")
    end

    test "no entities rejected" do
      assert {:error, %Cqr.Error{code: :parse_error}} = Parser.parse("COMPARE")
    end

    test "invalid entity format rejected" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("COMPARE product:churn_rate, product:nps")
    end

    test "invalid INCLUDE facet rejected" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("COMPARE entity:product:churn_rate, entity:product:nps INCLUDE bogus")
    end

    test "trailing garbage rejected" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("COMPARE entity:product:churn_rate, entity:product:nps EXTRA")
    end

    test "did-you-mean suggestion fires for COMPAR typo" do
      assert {:error, %Cqr.Error{retry_guidance: guidance}} = Parser.parse("COMPAR foo")
      assert guidance =~ "COMPARE"
    end
  end
end
