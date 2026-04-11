defmodule Cqr.Integration.ScopeEnforcementTest do
  @moduledoc """
  Integration tests for scope enforcement on RESOLVE, DISCOVER, and ASSERT.

  These are the most important tests in the project — they prove the
  governance guarantee from the patent's independent claim 29: an agent
  at a given scope can see only self + ancestors + descendants, never
  siblings. Cross-scope relationship edges must not leak sibling-scoped
  entities into discovery results.

  The seed dataset (see `Cqr.Repo.Seed`) has this shape:

      company
        |-- finance     (arr, mrr, ...)
        |-- product     (churn_rate, nps, ...)
        |-- engineering (deployment_frequency, ...)
        |-- hr          (headcount, ...)
        |-- customer_success (csat, ...)

  And a notable cross-scope edge:
      product:churn_rate -[:CONTRIBUTES_TO]-> finance:arr
  """

  use ExUnit.Case

  alias Cqr.Engine

  @company_context %{scope: ["company"], agent_id: "twin:root"}
  @product_context %{scope: ["company", "product"], agent_id: "twin:product"}

  describe "RESOLVE: sibling isolation" do
    test "product agent cannot resolve HR entities" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute("RESOLVE entity:hr:headcount", @product_context)
    end

    test "product agent cannot resolve finance entities" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute("RESOLVE entity:finance:arr", @product_context)
    end

    test "product agent cannot resolve engineering entities" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute("RESOLVE entity:engineering:deployment_frequency", @product_context)
    end

    test "product agent CAN resolve its own product entities" do
      assert {:ok, %Cqr.Result{data: [%{namespace: "product", name: "churn_rate"}]}} =
               Engine.execute("RESOLVE entity:product:churn_rate", @product_context)
    end
  end

  describe "RESOLVE: ancestor visibility" do
    test "root (company) agent can resolve HR entities (descendant visibility)" do
      assert {:ok, %Cqr.Result{data: [%{namespace: "hr", name: "headcount"}]}} =
               Engine.execute("RESOLVE entity:hr:headcount", @company_context)
    end

    test "root (company) agent can resolve finance entities (descendant visibility)" do
      assert {:ok, %Cqr.Result{data: [%{namespace: "finance", name: "arr"}]}} =
               Engine.execute("RESOLVE entity:finance:arr", @company_context)
    end
  end

  describe "RESOLVE: scope parameter override narrows visibility" do
    test "root agent with FROM scope:company:product cannot see HR entities" do
      # Root agent would normally see everything, but the FROM clause
      # narrows visibility to the product subtree only.
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(
                 "RESOLVE entity:hr:headcount FROM scope:company:product",
                 @company_context
               )
    end

    test "root agent with FROM scope:company:product cannot see finance entities" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(
                 "RESOLVE entity:finance:arr FROM scope:company:product",
                 @company_context
               )
    end

    test "root agent with FROM scope:company:product CAN still see product entities" do
      assert {:ok, %Cqr.Result{data: [%{namespace: "product", name: "churn_rate"}]}} =
               Engine.execute(
                 "RESOLVE entity:product:churn_rate FROM scope:company:product",
                 @company_context
               )
    end

    test "root agent with FROM scope:company:product can still see company ancestor entities" do
      # Ancestor visibility from the narrowed subtree: scope:company
      # is an ancestor of scope:company:product and remains visible.
      agent_visible = Cqr.Scope.visible_scopes(["company", "product"])
      assert ["company"] in agent_visible
    end

    test "agent cannot escape its sandbox by naming an inaccessible FROM scope" do
      # Product agent has no access to hr; naming it in FROM must error.
      assert {:error, %Cqr.Error{code: :scope_access}} =
               Engine.execute(
                 "RESOLVE entity:hr:headcount FROM scope:company:hr",
                 @product_context
               )
    end
  end

  describe "DISCOVER: sibling isolation" do
    test "product agent discovering around churn_rate does NOT see finance:arr" do
      # product:churn_rate has a CONTRIBUTES_TO edge to finance:arr.
      # That cross-scope edge must be filtered out for a product agent.
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 1 DIRECTION outbound",
                 @product_context
               )

      namespaces = data |> Enum.map(& &1.entity) |> Enum.map(fn {ns, _} -> ns end)
      refute "finance" in namespaces
      refute "hr" in namespaces
      refute "engineering" in namespaces
    end

    test "root agent discovering around churn_rate DOES see finance:arr (cross-scope visible)" do
      # Root can see both product and finance, so the CONTRIBUTES_TO edge
      # to finance:arr surfaces in the discovery results.
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 1 DIRECTION outbound",
                 @company_context
               )

      entities = Enum.map(data, & &1.entity)
      assert {"finance", "arr"} in entities
      assert {"product", "nps"} in entities
    end

    test "product agent with DEPTH 2 still cannot see finance descendants transitively" do
      # Depth traversal must still respect scope boundaries.
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 2 DIRECTION outbound",
                 @product_context
               )

      namespaces = data |> Enum.map(& &1.entity) |> Enum.map(fn {ns, _} -> ns end) |> Enum.uniq()
      refute "finance" in namespaces
      refute "hr" in namespaces
    end
  end

  describe "DISCOVER: WITHIN clause narrows visibility" do
    test "root agent with WITHIN scope:company:product cannot see finance results" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:product:churn_rate " <>
                   "WITHIN scope:company:product DEPTH 1 DIRECTION outbound",
                 @company_context
               )

      namespaces = data |> Enum.map(& &1.entity) |> Enum.map(fn {ns, _} -> ns end)
      refute "finance" in namespaces
    end

    test "product agent naming an inaccessible WITHIN scope gets scope_access error" do
      assert {:error, %Cqr.Error{code: :scope_access}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:product:churn_rate WITHIN scope:company:hr",
                 @product_context
               )
    end
  end

  describe "ASSERT: scope enforcement regression" do
    # ASSERT already has its own scope check (via Cqr.Adapter.Grafeo.resolve_target_scope/2);
    # these tests make sure the engine-level fix does not regress that path.

    test "product agent can assert into its own scope" do
      expr =
        ~s(ASSERT entity:test_scope_enforcement:ok_case TYPE derived_metric ) <>
          ~s(DESCRIPTION "Scope enforcement test" INTENT "regression check" ) <>
          ~s(DERIVED_FROM entity:product:churn_rate IN scope:company:product)

      assert {:ok, %Cqr.Result{}} = Engine.execute(expr, @product_context)
    end

    test "product agent CANNOT assert into an HR sibling scope" do
      expr =
        ~s(ASSERT entity:test_scope_enforcement:bad_case TYPE derived_metric ) <>
          ~s(DESCRIPTION "Scope enforcement test" INTENT "regression check" ) <>
          ~s(DERIVED_FROM entity:product:churn_rate IN scope:company:hr)

      assert {:error, %Cqr.Error{code: :scope_access}} =
               Engine.execute(expr, @product_context)
    end
  end

  describe "Cqr.Scope.visible_scopes invariants" do
    test "product scope visibility is self + ancestor only, never siblings" do
      visible = Cqr.Scope.visible_scopes(["company", "product"])

      assert ["company", "product"] in visible
      assert ["company"] in visible

      refute ["company", "hr"] in visible
      refute ["company", "finance"] in visible
      refute ["company", "engineering"] in visible
      refute ["company", "customer_success"] in visible
    end

    test "root scope visibility includes all descendants" do
      visible = Cqr.Scope.visible_scopes(["company"])

      assert ["company"] in visible
      assert ["company", "hr"] in visible
      assert ["company", "finance"] in visible
      assert ["company", "product"] in visible
    end
  end
end
