defmodule Cqr.TypesTest do
  use ExUnit.Case, async: true

  alias Cqr.Types

  describe "valid_entity?/1" do
    test "valid entity" do
      assert Types.valid_entity?({"finance", "arr"})
    end

    test "entity with underscores and numbers" do
      assert Types.valid_entity?({"my_ns", "metric_2025"})
    end

    test "invalid — uppercase" do
      refute Types.valid_entity?({"Finance", "arr"})
    end

    test "invalid — empty string" do
      refute Types.valid_entity?({"", "arr"})
    end

    test "invalid — not a tuple" do
      refute Types.valid_entity?("finance:arr")
    end

    test "invalid — starts with number" do
      refute Types.valid_entity?({"2ns", "arr"})
    end
  end

  describe "format_entity/1" do
    test "formats correctly" do
      assert Types.format_entity({"finance", "arr"}) == "entity:finance:arr"
    end
  end

  describe "valid_scope?/1" do
    test "single segment" do
      assert Types.valid_scope?(["company"])
    end

    test "multi-segment" do
      assert Types.valid_scope?(["company", "finance", "latam"])
    end

    test "invalid — empty list" do
      refute Types.valid_scope?([])
    end

    test "invalid — non-list" do
      refute Types.valid_scope?("company")
    end
  end

  describe "parent/1" do
    test "returns parent of multi-segment scope" do
      assert Types.parent(["company", "finance"]) == ["company"]
    end

    test "returns nil for single-segment scope" do
      assert Types.parent(["company"]) == nil
    end

    test "deep scope" do
      assert Types.parent(["company", "finance", "latam"]) == ["company", "finance"]
    end
  end

  describe "ancestors/1" do
    test "returns ancestors from parent to root" do
      assert Types.ancestors(["company", "finance", "latam"]) == [
               ["company", "finance"],
               ["company"]
             ]
    end

    test "single-segment scope has no ancestors" do
      assert Types.ancestors(["company"]) == []
    end
  end

  describe "child?/2" do
    test "child scope" do
      assert Types.child?(["company", "finance"], ["company"])
    end

    test "deep child" do
      assert Types.child?(["company", "finance", "latam"], ["company"])
    end

    test "not a child — same scope" do
      refute Types.child?(["company"], ["company"])
    end

    test "not a child — sibling" do
      refute Types.child?(["company", "finance"], ["company", "engineering"])
    end

    test "not a child — parent" do
      refute Types.child?(["company"], ["company", "finance"])
    end
  end

  describe "format_scope/1" do
    test "formats correctly" do
      assert Types.format_scope(["company", "finance"]) == "scope:company:finance"
    end
  end

  describe "valid_duration?/1" do
    test "valid minutes" do
      assert Types.valid_duration?({30, :m})
    end

    test "valid hours" do
      assert Types.valid_duration?({24, :h})
    end

    test "valid days" do
      assert Types.valid_duration?({7, :d})
    end

    test "valid weeks" do
      assert Types.valid_duration?({2, :w})
    end

    test "invalid — zero" do
      refute Types.valid_duration?({0, :h})
    end

    test "invalid — negative" do
      refute Types.valid_duration?({-1, :h})
    end

    test "invalid — bad unit" do
      refute Types.valid_duration?({1, :x})
    end
  end

  describe "to_minutes/1" do
    test "minutes pass through" do
      assert Types.to_minutes({30, :m}) == 30
    end

    test "hours to minutes" do
      assert Types.to_minutes({2, :h}) == 120
    end

    test "days to minutes" do
      assert Types.to_minutes({1, :d}) == 1440
    end

    test "weeks to minutes" do
      assert Types.to_minutes({1, :w}) == 10_080
    end
  end

  describe "valid_score?/1" do
    test "valid scores" do
      assert Types.valid_score?(0.0)
      assert Types.valid_score?(0.5)
      assert Types.valid_score?(1.0)
    end

    test "invalid — above 1.0" do
      refute Types.valid_score?(1.1)
    end

    test "invalid — negative" do
      refute Types.valid_score?(-0.1)
    end

    test "invalid — not a float" do
      refute Types.valid_score?(1)
    end
  end

  describe "valid_identifier?/1" do
    test "lowercase letters" do
      assert Types.valid_identifier?("abc")
    end

    test "with underscores" do
      assert Types.valid_identifier?("my_metric")
    end

    test "starts with underscore" do
      assert Types.valid_identifier?("_private")
    end

    test "with numbers" do
      assert Types.valid_identifier?("metric_2025")
    end

    test "invalid — starts with number" do
      refute Types.valid_identifier?("2metric")
    end

    test "invalid — uppercase" do
      refute Types.valid_identifier?("Metric")
    end

    test "invalid — empty" do
      refute Types.valid_identifier?("")
    end

    test "invalid — spaces" do
      refute Types.valid_identifier?("my metric")
    end
  end
end
