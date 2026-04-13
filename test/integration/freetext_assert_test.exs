defmodule Cqr.Integration.FreetextAssertTest do
  @moduledoc """
  Regression tests for the bug where entities created via ASSERT were
  accessible via RESOLVE and graph DISCOVER but invisible to free-text
  DISCOVER. Root cause: the ASSERT write path skipped the `embedding`
  property, so the BM25+vector candidate query's vector side produced
  no similarity score and the entity was often missed entirely.

  These tests pin the invariant: every asserted entity must appear in
  free-text DISCOVER under its scope, and scope isolation must still
  hold.
  """

  use ExUnit.Case

  alias Cqr.Engine

  @company_context %{scope: ["company"], agent_id: "twin:ft_c"}
  @product_context %{scope: ["company", "product"], agent_id: "twin:ft_p"}
  @finance_context %{scope: ["company", "finance"], agent_id: "twin:ft_f"}

  defp assert_expr(name, desc, opts \\ []) do
    scope_clause =
      case Keyword.get(opts, :scope) do
        nil -> ""
        s -> " IN #{s}"
      end

    ~s(ASSERT entity:freetext_test:#{name} TYPE policy ) <>
      ~s(DESCRIPTION "#{desc}" ) <>
      ~s(INTENT "regression test" ) <>
      ~s(DERIVED_FROM entity:product:churn_rate) <> scope_clause
  end

  test "free-text DISCOVER finds asserted entity by unique word in description" do
    {:ok, _} =
      Engine.execute(
        assert_expr("unique_desc", "A marker phrase containing zyxwvu_marker for testing"),
        @company_context
      )

    assert {:ok, result} =
             Engine.execute(~s(DISCOVER concepts RELATED TO "zyxwvu_marker"), @company_context)

    assert Enum.any?(result.data, &(&1.name == "unique_desc"))
  end

  test "free-text DISCOVER finds asserted entity by its name" do
    {:ok, _} =
      Engine.execute(
        assert_expr("zebrafish_policy", "Some policy description here"),
        @company_context
      )

    assert {:ok, result} =
             Engine.execute(~s(DISCOVER concepts RELATED TO "zebrafish_policy"), @company_context)

    assert Enum.any?(result.data, &(&1.name == "zebrafish_policy"))
  end

  test "root-scoped asserted entity is visible to the root agent via free-text" do
    {:ok, _} =
      Engine.execute(
        assert_expr("rootscope_item", "Entity asserted at company root with plutoniumword"),
        @company_context
      )

    assert {:ok, result} =
             Engine.execute(~s(DISCOVER concepts RELATED TO "plutoniumword"), @company_context)

    assert Enum.any?(result.data, &(&1.name == "rootscope_item"))
  end

  test "product-scoped asserted entity is visible to product agent via free-text" do
    {:ok, _} =
      Engine.execute(
        assert_expr("productscope_item", "Product policy mentioning quetzalbird",
          scope: "scope:company:product"
        ),
        @product_context
      )

    assert {:ok, result} =
             Engine.execute(~s(DISCOVER concepts RELATED TO "quetzalbird"), @product_context)

    assert Enum.any?(result.data, &(&1.name == "productscope_item"))
  end

  test "product-scoped asserted entity is NOT visible to sibling finance agent" do
    {:ok, _} =
      Engine.execute(
        assert_expr("sibling_isolated", "Product-only entity with narwhalword term",
          scope: "scope:company:product"
        ),
        @product_context
      )

    assert {:ok, result} =
             Engine.execute(~s(DISCOVER concepts RELATED TO "narwhalword"), @finance_context)

    refute Enum.any?(result.data, &(&1.name == "sibling_isolated"))
  end
end
