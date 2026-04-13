defmodule Cqr.Parser.AwarenessTest do
  use ExUnit.Case, async: true

  alias Cqr.Parser

  describe "AWARENESS — minimal" do
    test "active_agents alone parses with defaults" do
      assert {:ok, %Cqr.Awareness{} = result} =
               Parser.parse("AWARENESS active_agents")

      assert result.mode == :active_agents
      assert result.within == nil
      assert result.time_window == nil
      assert result.limit == 20
    end
  end

  describe "AWARENESS — WITHIN clause" do
    test "narrows to a single scope" do
      assert {:ok, result} =
               Parser.parse("AWARENESS active_agents WITHIN scope:company:product")

      assert result.within == ["company", "product"]
    end

    test "accepts a deep scope path" do
      assert {:ok, result} =
               Parser.parse("AWARENESS active_agents WITHIN scope:company:product:churn")

      assert result.within == ["company", "product", "churn"]
    end
  end

  describe "AWARENESS — OVER last clause" do
    test "hours window" do
      assert {:ok, result} =
               Parser.parse("AWARENESS active_agents OVER last 24h")

      assert result.time_window == {24, :h}
    end

    test "minutes window" do
      assert {:ok, result} =
               Parser.parse("AWARENESS active_agents OVER last 30m")

      assert result.time_window == {30, :m}
    end

    test "days window" do
      assert {:ok, result} =
               Parser.parse("AWARENESS active_agents OVER last 7d")

      assert result.time_window == {7, :d}
    end
  end

  describe "AWARENESS — LIMIT clause" do
    test "overrides default limit" do
      assert {:ok, result} =
               Parser.parse("AWARENESS active_agents LIMIT 5")

      assert result.limit == 5
    end
  end

  describe "AWARENESS — combined clauses" do
    test "WITHIN + OVER + LIMIT" do
      assert {:ok, result} =
               Parser.parse(
                 "AWARENESS active_agents WITHIN scope:company:product OVER last 24h LIMIT 10"
               )

      assert result.within == ["company", "product"]
      assert result.time_window == {24, :h}
      assert result.limit == 10
    end

    test "clauses in any order" do
      assert {:ok, result} =
               Parser.parse("AWARENESS active_agents LIMIT 3 OVER last 7d WITHIN scope:company")

      assert result.within == ["company"]
      assert result.time_window == {7, :d}
      assert result.limit == 3
    end
  end

  describe "AWARENESS — error cases" do
    test "missing active_agents keyword" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("AWARENESS")
    end

    test "unknown mode keyword" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Parser.parse("AWARENESS sleeping_agents")
    end

    test "AWARENESS suggestion in retry guidance" do
      assert {:error, %Cqr.Error{retry_guidance: guidance}} =
               Parser.parse("AWARENES active_agents")

      assert guidance =~ "AWARENESS"
    end
  end
end
