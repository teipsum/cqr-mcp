defmodule Cqr.Parser.ResolveTest do
  use ExUnit.Case, async: true

  alias Cqr.Parser

  describe "RESOLVE — minimal" do
    test "entity only" do
      assert {:ok, %Cqr.Resolve{entity: {"finance", "arr"}}} =
               Parser.parse("RESOLVE entity:finance:arr")
    end

    test "entity with underscores" do
      assert {:ok, %Cqr.Resolve{entity: {"my_ns", "my_metric"}}} =
               Parser.parse("RESOLVE entity:my_ns:my_metric")
    end

    test "entity with numbers" do
      assert {:ok, %Cqr.Resolve{entity: {"finance", "q4_2025_arr"}}} =
               Parser.parse("RESOLVE entity:finance:q4_2025_arr")
    end
  end

  describe "RESOLVE — FROM clause" do
    test "single-segment scope" do
      {:ok, result} = Parser.parse("RESOLVE entity:finance:arr FROM scope:finance")
      assert result.entity == {"finance", "arr"}
      assert result.scope == ["finance"]
    end

    test "multi-segment scope" do
      {:ok, result} = Parser.parse("RESOLVE entity:finance:arr FROM scope:company:finance")
      assert result.scope == ["company", "finance"]
    end

    test "deep scope" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr FROM scope:company:finance:latam")

      assert result.scope == ["company", "finance", "latam"]
    end
  end

  describe "RESOLVE — WITH freshness" do
    test "hours" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr WITH freshness < 24h")

      assert result.freshness == {24, :h}
    end

    test "minutes" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr WITH freshness < 30m")

      assert result.freshness == {30, :m}
    end

    test "days" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr WITH freshness < 7d")

      assert result.freshness == {7, :d}
    end

    test "weeks" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr WITH freshness < 2w")

      assert result.freshness == {2, :w}
    end

    test "without space after <" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr WITH freshness <24h")

      assert result.freshness == {24, :h}
    end
  end

  describe "RESOLVE — WITH reputation" do
    test "basic score" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr WITH reputation > 0.7")

      assert result.reputation == 0.7
    end

    test "high precision score" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr WITH reputation > 0.85")

      assert result.reputation == 0.85
    end

    test "zero score" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr WITH reputation > 0.0")

      assert result.reputation == 0.0
    end

    test "without space after >" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr WITH reputation >0.7")

      assert result.reputation == 0.7
    end
  end

  describe "RESOLVE — INCLUDE clause" do
    test "single annotation" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr INCLUDE lineage")

      assert result.include == [:lineage]
    end

    test "multiple annotations" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr INCLUDE lineage, confidence, owner")

      assert result.include == [:lineage, :confidence, :owner]
    end

    test "all annotations" do
      {:ok, result} =
        Parser.parse(
          "RESOLVE entity:finance:arr INCLUDE freshness, confidence, reputation, owner, lineage"
        )

      assert result.include == [:freshness, :confidence, :reputation, :owner, :lineage]
    end
  end

  describe "RESOLVE — FALLBACK clause" do
    test "single fallback" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr FALLBACK scope:global")

      assert result.fallback == [["global"]]
    end

    test "fallback chain with ASCII arrow" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr FALLBACK scope:product -> scope:global")

      assert result.fallback == [["product"], ["global"]]
    end

    test "fallback chain with Unicode arrow" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr FALLBACK scope:product → scope:global")

      assert result.fallback == [["product"], ["global"]]
    end

    test "three-level fallback chain" do
      {:ok, result} =
        Parser.parse(
          "RESOLVE entity:finance:arr FALLBACK scope:finance -> scope:product -> scope:global"
        )

      assert result.fallback == [["finance"], ["product"], ["global"]]
    end

    test "fallback with multi-segment scopes" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr FALLBACK scope:company:product -> scope:company")

      assert result.fallback == [["company", "product"], ["company"]]
    end
  end

  describe "RESOLVE — full expressions" do
    test "all clauses in canonical order" do
      {:ok, result} =
        Parser.parse("""
        RESOLVE entity:finance:arr FROM scope:company:finance WITH freshness < 24h WITH reputation > 0.7 INCLUDE lineage, confidence, owner FALLBACK scope:product -> scope:global
        """)

      assert result.entity == {"finance", "arr"}
      assert result.scope == ["company", "finance"]
      assert result.freshness == {24, :h}
      assert result.reputation == 0.7
      assert result.include == [:lineage, :confidence, :owner]
      assert result.fallback == [["product"], ["global"]]
    end

    test "both WITH clauses" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr WITH freshness < 24h WITH reputation > 0.7")

      assert result.freshness == {24, :h}
      assert result.reputation == 0.7
    end
  end

  describe "RESOLVE — order-insensitive clauses" do
    test "INCLUDE before FROM" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr INCLUDE lineage FROM scope:finance")

      assert result.entity == {"finance", "arr"}
      assert result.include == [:lineage]
      assert result.scope == ["finance"]
    end

    test "FALLBACK before WITH" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr FALLBACK scope:global WITH freshness < 24h")

      assert result.fallback == [["global"]]
      assert result.freshness == {24, :h}
    end

    test "WITH reputation before WITH freshness" do
      {:ok, result} =
        Parser.parse("RESOLVE entity:finance:arr WITH reputation > 0.7 WITH freshness < 24h")

      assert result.reputation == 0.7
      assert result.freshness == {24, :h}
    end

    test "all clauses in reverse order" do
      {:ok, result} =
        Parser.parse(
          "RESOLVE entity:finance:arr FALLBACK scope:global INCLUDE lineage WITH reputation > 0.8 WITH freshness < 12h FROM scope:company"
        )

      assert result.entity == {"finance", "arr"}
      assert result.fallback == [["global"]]
      assert result.include == [:lineage]
      assert result.reputation == 0.8
      assert result.freshness == {12, :h}
      assert result.scope == ["company"]
    end
  end

  describe "RESOLVE — nil defaults" do
    test "optional fields are nil when absent" do
      {:ok, result} = Parser.parse("RESOLVE entity:finance:arr")
      assert result.scope == nil
      assert result.freshness == nil
      assert result.reputation == nil
      assert result.include == nil
      assert result.fallback == nil
    end
  end
end
