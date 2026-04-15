defmodule Cqr.Parser.AssertTest do
  use ExUnit.Case, async: true

  alias Cqr.Parser

  @base ~s(ASSERT entity:insights:churn_arr_impact TYPE observation ) <>
          ~s(DESCRIPTION "churn impacts ARR" INTENT "testing" ) <>
          ~s(DERIVED_FROM entity:product:churn_rate,entity:finance:arr)

  describe "ASSERT without RELATIONSHIPS" do
    test "still parses when the clause is absent" do
      assert {:ok, %Cqr.Assert{} = ast} = Parser.parse(@base)
      assert ast.entity == {"insights", "churn_arr_impact"}
      assert ast.type == "observation"
      assert ast.derived_from == [{"product", "churn_rate"}, {"finance", "arr"}]
      assert ast.relationships == nil
    end

    test "parses DERIVED_FROM with hierarchical entity addresses" do
      expr =
        ~s(ASSERT entity:insights:x TYPE observation DESCRIPTION "x" INTENT "y" ) <>
          ~s(DERIVED_FROM entity:agent:default:orientation,) <>
          ~s(entity:governance:relationship_guide)

      assert {:ok, %Cqr.Assert{derived_from: sources}} = Parser.parse(expr)

      assert sources == [
               {"agent:default", "orientation"},
               {"governance", "relationship_guide"}
             ]
    end
  end

  describe "ASSERT with RELATIONSHIPS" do
    test "parses a single relationship" do
      expr = @base <> " RELATIONSHIPS CONTRIBUTES_TO:entity:finance:arr:0.75"

      assert {:ok,
              %Cqr.Assert{
                relationships: [
                  %{type: "CONTRIBUTES_TO", target: {"finance", "arr"}, strength: 0.75}
                ]
              }} = Parser.parse(expr)
    end

    test "parses multiple comma-separated relationships" do
      expr =
        @base <>
          " RELATIONSHIPS CONTRIBUTES_TO:entity:finance:arr:0.75," <>
          "CORRELATES_WITH:entity:product:churn_rate:0.9"

      assert {:ok, %Cqr.Assert{relationships: rels}} = Parser.parse(expr)

      assert [
               %{type: "CONTRIBUTES_TO", target: {"finance", "arr"}, strength: 0.75},
               %{type: "CORRELATES_WITH", target: {"product", "churn_rate"}, strength: 0.9}
             ] = rels
    end

    test "tolerates whitespace around the comma separator" do
      expr =
        @base <>
          " RELATIONSHIPS CONTRIBUTES_TO:entity:finance:arr:0.75 , " <>
          "DEPENDS_ON:entity:product:churn_rate:0.5"

      assert {:ok, %Cqr.Assert{relationships: [_, _]}} = Parser.parse(expr)
    end

    test "accepts all five valid relationship types" do
      for type <- ~w(CORRELATES_WITH CONTRIBUTES_TO DEPENDS_ON CAUSES PART_OF) do
        expr = @base <> " RELATIONSHIPS #{type}:entity:finance:arr:0.5"

        assert {:ok, %Cqr.Assert{relationships: [%{type: ^type}]}} = Parser.parse(expr)
      end
    end

    test "rejects unknown relationship types" do
      expr = @base <> " RELATIONSHIPS INFLUENCES:entity:finance:arr:0.5"

      assert {:error, %Cqr.Error{code: :parse_error}} = Parser.parse(expr)
    end

    test "parses strength as a float" do
      expr = @base <> " RELATIONSHIPS CAUSES:entity:finance:arr:0.33"

      assert {:ok, %Cqr.Assert{relationships: [%{strength: strength}]}} = Parser.parse(expr)
      assert is_float(strength)
      assert strength == 0.33
    end

    test "parses a hierarchical entity address in a relationship target" do
      expr = @base <> " RELATIONSHIPS DEPENDS_ON:entity:agent:default:orientation:0.9"

      assert {:ok, %Cqr.Assert{relationships: [rel]}} = Parser.parse(expr)
      assert rel.type == "DEPENDS_ON"
      assert rel.target == {"agent:default", "orientation"}
      assert rel.strength == 0.9
    end

    test "parses multiple hierarchical relationship targets" do
      expr =
        @base <>
          " RELATIONSHIPS CONTRIBUTES_TO:entity:agent:patent_agent:legal:0.7," <>
          "DEPENDS_ON:entity:governance:relationship_guide:0.5"

      assert {:ok, %Cqr.Assert{relationships: rels}} = Parser.parse(expr)

      assert [
               %{
                 type: "CONTRIBUTES_TO",
                 target: {"agent:patent_agent", "legal"},
                 strength: 0.7
               },
               %{
                 type: "DEPENDS_ON",
                 target: {"governance", "relationship_guide"},
                 strength: 0.5
               }
             ] = rels
    end

    test "RELATIONSHIPS can coexist with IN and CONFIDENCE in any order" do
      expr =
        ~s(ASSERT entity:insights:churn_arr_impact TYPE observation ) <>
          ~s(RELATIONSHIPS CAUSES:entity:finance:arr:0.8 ) <>
          ~s(DESCRIPTION "x" INTENT "y" ) <>
          ~s(DERIVED_FROM entity:product:churn_rate ) <>
          ~s(IN scope:company:product CONFIDENCE 0.7)

      assert {:ok, %Cqr.Assert{} = ast} = Parser.parse(expr)
      assert ast.confidence == 0.7
      assert ast.scope == ["company", "product"]
      assert [%{type: "CAUSES", strength: 0.8}] = ast.relationships
    end
  end
end
