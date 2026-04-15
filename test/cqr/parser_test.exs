defmodule Cqr.ParserTest do
  use ExUnit.Case, async: true

  alias Cqr.Parser

  describe "parse/1 — error cases" do
    test "empty string returns error" do
      assert {:error, %Cqr.Error{code: :parse_error}} = Parser.parse("")
    end

    test "non-string input returns error" do
      assert {:error, %Cqr.Error{code: :parse_error}} = Parser.parse(123)
    end

    test "nil input returns error" do
      assert {:error, %Cqr.Error{code: :parse_error}} = Parser.parse(nil)
    end

    test "unknown primitive returns error" do
      assert {:error, %Cqr.Error{code: :parse_error}} = Parser.parse("SELECT * FROM users")
    end

    test "partial RESOLVE with no entity" do
      assert {:error, %Cqr.Error{code: :parse_error}} = Parser.parse("RESOLVE")
    end

    test "RESOLVE with invalid entity format" do
      assert {:error, %Cqr.Error{code: :parse_error}} = Parser.parse("RESOLVE finance:arr")
    end

    test "RESOLVE with uppercase entity" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("RESOLVE entity:Finance:ARR")
    end

    test "DISCOVER without concepts keyword" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("DISCOVER RELATED TO entity:product:churn_rate")
    end

    test "DISCOVER without RELATED TO" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("DISCOVER concepts entity:product:churn_rate")
    end

    test "CERTIFY with invalid status" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("CERTIFY entity:finance:arr STATUS invalid")
    end

    test "trailing garbage after valid expression" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("RESOLVE entity:finance:arr EXTRA_STUFF")
    end

    test "error includes position information" do
      {:error, error} = Parser.parse("RESOLVE badentity")
      assert error.details[:position] != nil
    end

    test "error includes retry guidance" do
      {:error, error} = Parser.parse("INVALID expression")
      assert error.retry_guidance != nil
    end
  end

  describe "parse/1 — whitespace handling" do
    test "leading whitespace is trimmed" do
      {:ok, result} = Parser.parse("  RESOLVE entity:finance:arr")
      assert result.entity == {"finance", "arr"}
    end

    test "trailing whitespace is trimmed" do
      {:ok, result} = Parser.parse("RESOLVE entity:finance:arr  ")
      assert result.entity == {"finance", "arr"}
    end

    test "tab-separated clauses" do
      {:ok, result} = Parser.parse("RESOLVE\tentity:finance:arr\tFROM\tscope:finance")
      assert result.entity == {"finance", "arr"}
      assert result.scope == ["finance"]
    end

    test "multiple spaces between clauses" do
      {:ok, result} = Parser.parse("RESOLVE  entity:finance:arr  FROM  scope:finance")
      assert result.entity == {"finance", "arr"}
      assert result.scope == ["finance"]
    end
  end

  describe "parse/1 — primitive dispatch" do
    test "returns Resolve struct for RESOLVE" do
      {:ok, result} = Parser.parse("RESOLVE entity:finance:arr")
      assert %Cqr.Resolve{} = result
    end

    test "returns Discover struct for DISCOVER" do
      {:ok, result} =
        Parser.parse("DISCOVER concepts RELATED TO entity:product:churn_rate")

      assert %Cqr.Discover{} = result
    end

    test "returns Certify struct for CERTIFY" do
      {:ok, result} = Parser.parse("CERTIFY entity:finance:arr STATUS proposed")
      assert %Cqr.Certify{} = result
    end
  end

  describe "parse/1 — edge cases from POC" do
    test "entity with single-char segments" do
      {:ok, result} = Parser.parse("RESOLVE entity:a:b")
      assert result.entity == {"a", "b"}
    end

    test "entity starting with underscore" do
      {:ok, result} = Parser.parse("RESOLVE entity:_internal:_metric")
      assert result.entity == {"_internal", "_metric"}
    end

    test "scope with many segments" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr FROM scope:company:division:team:sub")

      assert result.scope == ["company", "division", "team", "sub"]
    end

    test "annotation list with no spaces after commas" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr INCLUDE freshness,confidence,owner")

      assert result.include == [:freshness, :confidence, :owner]
    end

    test "DISCOVER with search string containing special chars" do
      {:ok, result} =
        Parser.parse(~s(DISCOVER concepts RELATED TO "Q4 2025 performance & growth"))

      assert result.related_to == {:search, "Q4 2025 performance & growth"}
    end
  end

  describe "parse/1 — hierarchical entity addresses" do
    test "parses 3-segment entity address" do
      {:ok, result} = Parser.parse("RESOLVE entity:agent:default:orientation")
      assert result.entity == {"agent:default", "orientation"}
    end

    test "parses 4-segment entity address" do
      {:ok, result} = Parser.parse("RESOLVE entity:agent:patent_agent:group:a")
      assert result.entity == {"agent:patent_agent:group", "a"}
    end

    test "parses 5-segment entity address" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:twin:michael:health:cardiology:heart_rate")

      assert result.entity == {"twin:michael:health:cardiology", "heart_rate"}
    end

    test "hierarchical entity works in RESOLVE" do
      {:ok, %Cqr.Resolve{} = result} =
        Parser.parse("RESOLVE entity:agent:default:orientation")

      assert result.entity == {"agent:default", "orientation"}
    end

    test "hierarchical entity works in ASSERT" do
      {:ok, %Cqr.Assert{} = result} =
        Parser.parse(
          ~s(ASSERT entity:product:uqr:cognitive:preamble TYPE definition DESCRIPTION "test")
        )

      assert result.entity == {"product:uqr:cognitive", "preamble"}
    end

    test "trailing colon is malformed" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("RESOLVE entity:agent:default:")
    end

    test "empty segment (double colon) is malformed" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("RESOLVE entity:agent::name")
    end

    test "two-segment entity still yields scalar namespace" do
      {:ok, result} = Parser.parse("RESOLVE entity:finance:arr")
      assert result.entity == {"finance", "arr"}
    end
  end
end
