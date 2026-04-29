defmodule Cqr.Parser.DiscoverTest do
  use ExUnit.Case, async: true

  alias Cqr.Parser

  describe "DISCOVER — minimal" do
    test "entity reference" do
      {:ok, result} =
        Parser.parse("DISCOVER concepts RELATED TO entity:product:churn_rate")

      assert result.related_to == {:entity, {"product", "churn_rate"}}
    end

    test "search string" do
      {:ok, result} =
        Parser.parse(~s(DISCOVER concepts RELATED TO "customer churn"))

      assert result.related_to == {:search, "customer churn"}
    end

    test "empty search string" do
      {:ok, result} =
        Parser.parse(~s(DISCOVER concepts RELATED TO ""))

      assert result.related_to == {:search, ""}
    end

    test "entity prefix (hierarchical enumeration sentinel)" do
      {:ok, result} =
        Parser.parse("DISCOVER concepts RELATED TO entity:agent:patent_agent:*")

      assert result.related_to == {:prefix, ["agent", "patent_agent"]}
    end

    test "deep entity prefix" do
      {:ok, result} =
        Parser.parse("DISCOVER concepts RELATED TO entity:agent:patent_agent:group:sub:*")

      assert result.related_to == {:prefix, ["agent", "patent_agent", "group", "sub"]}
    end

    test "global entity prefix (entity:*)" do
      {:ok, result} = Parser.parse("DISCOVER concepts RELATED TO entity:*")
      assert result.related_to == {:prefix, []}
    end

    test "global entity prefix with LIMIT" do
      {:ok, result} = Parser.parse("DISCOVER concepts RELATED TO entity:* LIMIT 10")
      assert result.related_to == {:prefix, []}
      assert result.limit == 10
    end

    test "single-segment entity prefix (entity:NS:*)" do
      {:ok, result} = Parser.parse("DISCOVER concepts RELATED TO entity:engineering:*")
      assert result.related_to == {:prefix, ["engineering"]}
    end

    test "two-segment entity prefix (regression)" do
      {:ok, result} = Parser.parse("DISCOVER concepts RELATED TO entity:engineering:state:*")
      assert result.related_to == {:prefix, ["engineering", "state"]}
    end

    test "four-segment entity prefix (regression)" do
      {:ok, result} =
        Parser.parse(
          "DISCOVER concepts RELATED TO entity:engineering:proposals:grafeo_capability_extensions:*"
        )

      assert result.related_to ==
               {:prefix, ["engineering", "proposals", "grafeo_capability_extensions"]}
    end

    test "entity reference without trailing :* is NOT treated as a prefix" do
      {:ok, result} =
        Parser.parse("DISCOVER concepts RELATED TO entity:agent:patent_agent")

      assert result.related_to == {:entity, {"agent", "patent_agent"}}
    end
  end

  describe "DISCOVER — WITHIN clause" do
    test "single scope" do
      {:ok, result} =
        Parser.parse(
          "DISCOVER concepts RELATED TO entity:product:churn_rate WITHIN scope:product"
        )

      assert result.within == [["product"]]
    end

    test "multiple scopes" do
      {:ok, result} =
        Parser.parse(
          "DISCOVER concepts RELATED TO entity:product:churn_rate WITHIN scope:product, scope:customer_success"
        )

      assert result.within == [["product"], ["customer_success"]]
    end

    test "multi-segment scopes" do
      {:ok, result} =
        Parser.parse(
          "DISCOVER concepts RELATED TO entity:product:churn_rate WITHIN scope:company:product, scope:company:customer_success"
        )

      assert result.within == [["company", "product"], ["company", "customer_success"]]
    end
  end

  describe "DISCOVER — DEPTH clause" do
    test "depth 1" do
      {:ok, result} =
        Parser.parse("DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 1")

      assert result.depth == 1
    end

    test "depth 3" do
      {:ok, result} =
        Parser.parse("DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 3")

      assert result.depth == 3
    end

    test "depth 10" do
      {:ok, result} =
        Parser.parse("DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 10")

      assert result.depth == 10
    end
  end

  describe "DISCOVER — ANNOTATE clause" do
    test "single annotation" do
      {:ok, result} =
        Parser.parse("DISCOVER concepts RELATED TO entity:product:churn_rate ANNOTATE freshness")

      assert result.annotate == [:freshness]
    end

    test "multiple annotations" do
      {:ok, result} =
        Parser.parse(
          "DISCOVER concepts RELATED TO entity:product:churn_rate ANNOTATE freshness, reputation, owner"
        )

      assert result.annotate == [:freshness, :reputation, :owner]
    end
  end

  describe "DISCOVER — LIMIT clause" do
    test "limit 5" do
      {:ok, result} =
        Parser.parse("DISCOVER concepts RELATED TO entity:product:churn_rate LIMIT 5")

      assert result.limit == 5
    end

    test "limit 100" do
      {:ok, result} =
        Parser.parse("DISCOVER concepts RELATED TO entity:product:churn_rate LIMIT 100")

      assert result.limit == 100
    end
  end

  describe "DISCOVER — full expressions" do
    test "all clauses in canonical order" do
      {:ok, result} =
        Parser.parse(
          "DISCOVER concepts RELATED TO entity:product:churn_rate WITHIN scope:product, scope:customer_success DEPTH 3 ANNOTATE freshness, reputation, owner LIMIT 10"
        )

      assert result.related_to == {:entity, {"product", "churn_rate"}}
      assert result.within == [["product"], ["customer_success"]]
      assert result.depth == 3
      assert result.annotate == [:freshness, :reputation, :owner]
      assert result.limit == 10
    end

    test "search string with all clauses" do
      {:ok, result} =
        Parser.parse(
          ~s(DISCOVER concepts RELATED TO "employee satisfaction" WITHIN scope:hr DEPTH 2 ANNOTATE freshness LIMIT 5)
        )

      assert result.related_to == {:search, "employee satisfaction"}
      assert result.within == [["hr"]]
      assert result.depth == 2
      assert result.annotate == [:freshness]
      assert result.limit == 5
    end
  end

  describe "DISCOVER — order-insensitive clauses" do
    test "DEPTH before WITHIN" do
      {:ok, result} =
        Parser.parse(
          "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 3 WITHIN scope:product"
        )

      assert result.depth == 3
      assert result.within == [["product"]]
    end

    test "LIMIT before DEPTH" do
      {:ok, result} =
        Parser.parse("DISCOVER concepts RELATED TO entity:product:churn_rate LIMIT 10 DEPTH 2")

      assert result.limit == 10
      assert result.depth == 2
    end

    test "ANNOTATE before WITHIN" do
      {:ok, result} =
        Parser.parse(
          "DISCOVER concepts RELATED TO entity:product:churn_rate ANNOTATE owner WITHIN scope:product"
        )

      assert result.annotate == [:owner]
      assert result.within == [["product"]]
    end

    test "all clauses in reverse order" do
      {:ok, result} =
        Parser.parse(
          "DISCOVER concepts RELATED TO entity:product:churn_rate LIMIT 5 ANNOTATE owner DEPTH 2 WITHIN scope:hr"
        )

      assert result.limit == 5
      assert result.annotate == [:owner]
      assert result.depth == 2
      assert result.within == [["hr"]]
    end
  end

  describe "DISCOVER — nil defaults" do
    test "optional fields are nil when absent" do
      {:ok, result} =
        Parser.parse("DISCOVER concepts RELATED TO entity:product:churn_rate")

      assert result.within == nil
      assert result.depth == nil
      assert result.annotate == nil
      assert result.limit == nil
      assert result.near == nil
    end
  end

  describe "DISCOVER — NEAR clause" do
    test "free-text search with NEAR anchor" do
      {:ok, result} =
        Parser.parse(
          ~s(DISCOVER concepts RELATED TO "patent strategy" NEAR entity:engineering:proposals:resolve_batch)
        )

      assert result.related_to == {:search, "patent strategy"}
      assert result.near == {"engineering:proposals", "resolve_batch"}
    end

    test "NEAR with two-segment anchor" do
      {:ok, result} =
        Parser.parse(
          "DISCOVER concepts RELATED TO entity:product:churn_rate NEAR entity:product:retention_rate"
        )

      assert result.near == {"product", "retention_rate"}
    end

    test "NEAR composes with other clauses in any order" do
      {:ok, result} =
        Parser.parse(
          ~s(DISCOVER concepts RELATED TO "rate" NEAR entity:product:churn_rate WITHIN scope:product LIMIT 5)
        )

      assert result.related_to == {:search, "rate"}
      assert result.near == {"product", "churn_rate"}
      assert result.within == [["product"]]
      assert result.limit == 5
    end
  end
end
