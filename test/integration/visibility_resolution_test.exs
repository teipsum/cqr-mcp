defmodule Cqr.Integration.VisibilityResolutionTest do
  @moduledoc """
  Integration tests for containment-aware visibility resolution.

  When an agent RESOLVEs (or SIGNALs, CERTIFIEs, TRACEs, etc.) a
  hierarchical entity, the engine walks the containment path from root
  to target and checks scope authorization at every level. Denial at
  any level returns the same `entity_not_found` response as a truly
  nonexistent entity — an agent must not be able to infer the existence
  or shape of entities in scopes they cannot see.
  """

  use ExUnit.Case

  alias Cqr.Engine

  @product_context %{scope: ["company", "product"], agent_id: "twin:product"}
  @finance_context %{scope: ["company", "finance"], agent_id: "twin:finance"}
  @company_context %{scope: ["company"], agent_id: "twin:root"}

  defp hierarchical_assert(ns_path, leaf_name) do
    ~s(ASSERT entity:#{ns_path}:#{leaf_name} TYPE derived_metric ) <>
      ~s(DESCRIPTION "Visibility fixture #{leaf_name}" ) <>
      ~s(INTENT "Testing containment-aware visibility" ) <>
      ~s(DERIVED_FROM entity:product:churn_rate)
  end

  describe "RESOLVE containment walk" do
    test "product agent resolves its own depth-3 entity" do
      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("vis_case1_root:mid", "leaf"),
                 @product_context
               )

      assert {:ok, %Cqr.Result{data: [%{name: "leaf"}]}} =
               Engine.execute(
                 "RESOLVE entity:vis_case1_root:mid:leaf",
                 @product_context
               )
    end

    test "finance agent cannot resolve depth-3 entity blocked at ancestor" do
      # Product agent asserts. The auto-created ancestor inherits product scope,
      # so finance sees neither the leaf nor the ancestor container.
      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("vis_case2_root:mid", "leaf"),
                 @product_context
               )

      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(
                 "RESOLVE entity:vis_case2_root:mid:leaf",
                 @finance_context
               )
    end

    test "finance agent cannot resolve depth-4 entity blocked at depth-2 ancestor" do
      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("vis_case3_root:mid:sub", "leaf"),
                 @product_context
               )

      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(
                 "RESOLVE entity:vis_case3_root:mid:sub:leaf",
                 @finance_context
               )
    end

    test "finance agent cannot distinguish blocked entity from nonexistent" do
      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("vis_case4_root:mid", "leaf"),
                 @product_context
               )

      {:error, blocked_err} =
        Engine.execute(
          "RESOLVE entity:vis_case4_root:mid:leaf",
          @finance_context
        )

      {:error, missing_err} =
        Engine.execute(
          "RESOLVE entity:vis_case4_nonexistent:mid:leaf",
          @finance_context
        )

      # Both come back with the same error code; no hint that one exists.
      assert blocked_err.code == :entity_not_found
      assert missing_err.code == :entity_not_found
    end

    test "company-root agent sees through descendants (depth-3 resolves)" do
      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("vis_case5_root:mid", "leaf"),
                 @product_context
               )

      assert {:ok, %Cqr.Result{data: [%{name: "leaf"}]}} =
               Engine.execute(
                 "RESOLVE entity:vis_case5_root:mid:leaf",
                 @company_context
               )
    end
  end

  describe "CERTIFY / SIGNAL / TRACE containment walk" do
    test "SIGNAL on depth-3 entity blocked at ancestor returns entity_not_found" do
      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("vis_case6_root:mid", "leaf"),
                 @product_context
               )

      signal_expr =
        ~s(SIGNAL reputation ON entity:vis_case6_root:mid:leaf SCORE 0.75 ) <>
          ~s(EVIDENCE "cross-scope probe")

      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(signal_expr, @finance_context)
    end

    test "TRACE on blocked depth-3 entity returns entity_not_found" do
      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("vis_case7_root:mid", "leaf"),
                 @product_context
               )

      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(
                 "TRACE entity:vis_case7_root:mid:leaf",
                 @finance_context
               )
    end

    test "CERTIFY on blocked depth-3 entity returns entity_not_found (not scope_access)" do
      assert {:ok, _} =
               Engine.execute(
                 hierarchical_assert("vis_case8_root:mid", "leaf"),
                 @product_context
               )

      cert_expr =
        ~s(CERTIFY entity:vis_case8_root:mid:leaf STATUS proposed ) <>
          ~s(AUTHORITY "test_authority" EVIDENCE "none")

      assert {:error, %Cqr.Error{code: code}} =
               Engine.execute(cert_expr, @finance_context)

      # Must not be :scope_access — that would leak existence.
      assert code == :entity_not_found
    end
  end
end
