defmodule Cqr.Integration.ScopeTest do
  use ExUnit.Case

  alias Cqr.Scope
  alias Cqr.Repo.ScopeTree

  describe "scope tree" do
    test "all scopes loaded from seed data" do
      scopes = Scope.all_scopes()
      assert length(scopes) == 6
      assert ["company"] in scopes
      assert ["company", "finance"] in scopes
      assert ["company", "engineering"] in scopes
      assert ["company", "product"] in scopes
      assert ["company", "hr"] in scopes
      assert ["company", "customer_success"] in scopes
    end

    test "scope exists" do
      assert Scope.exists?(["company"])
      assert Scope.exists?(["company", "finance"])
      refute Scope.exists?(["nonexistent"])
      refute Scope.exists?(["company", "nonexistent"])
    end
  end

  describe "visible_scopes/1" do
    test "root scope sees only itself" do
      visible = Scope.visible_scopes(["company"])
      assert visible == [["company"]]
    end

    test "child scope sees self and parent" do
      visible = Scope.visible_scopes(["company", "finance"])
      assert ["company", "finance"] in visible
      assert ["company"] in visible
      assert length(visible) == 2
    end

    test "nonexistent scope returns empty" do
      assert Scope.visible_scopes(["nonexistent"]) == []
    end
  end

  describe "accessible?/2" do
    test "scope is accessible to itself" do
      assert Scope.accessible?(["company", "finance"], ["company", "finance"])
    end

    test "parent is accessible from child" do
      assert Scope.accessible?(["company", "finance"], ["company"])
    end

    test "sibling scope is NOT accessible" do
      refute Scope.accessible?(["company", "finance"], ["company", "engineering"])
    end

    test "child scope is NOT accessible from parent" do
      refute Scope.accessible?(["company"], ["company", "finance"])
    end
  end

  describe "authoritative_scope/2" do
    test "entity in agent's scope" do
      assert {:ok, ["company", "finance"]} =
               Scope.authoritative_scope({"finance", "arr"}, ["company", "finance"])
    end

    test "entity visible via parent scope" do
      # From company root, finance entities are NOT visible (scope-first: genuine invisibility)
      # The company scope can see itself but finance entities are IN scope:finance
      # Since company is parent of finance, company does NOT see finance's entities
      # unless the query specifically traverses
      result = Scope.authoritative_scope({"finance", "arr"}, ["company"])

      # From root company scope, finance scope is not in visible_scopes (only ["company"])
      # So finance entities are invisible
      assert result == {:error, :not_visible}
    end

    test "entity in sibling scope is not visible" do
      result = Scope.authoritative_scope({"finance", "arr"}, ["company", "engineering"])
      assert result == {:error, :not_visible}
    end
  end

  describe "fallback_chain/2" do
    test "valid chain within visible scopes" do
      assert {:ok, [["company", "finance"]]} =
               Scope.fallback_chain([["company", "finance"]], ["company", "finance"])
    end

    test "invalid chain — inaccessible scope" do
      assert {:error, {:inaccessible_scope, ["company", "engineering"]}} =
               Scope.fallback_chain(
                 [["company", "engineering"]],
                 ["company", "finance"]
               )
    end
  end

  describe "scope tree children" do
    test "company has child scopes" do
      children = ScopeTree.children(["company"])
      assert length(children) == 5
    end

    test "leaf scope has no children" do
      children = ScopeTree.children(["company", "finance"])
      assert children == []
    end
  end

  describe "ETS performance" do
    test "scope lookup is sub-millisecond" do
      {time_us, _result} =
        :timer.tc(fn ->
          for _ <- 1..1000 do
            Scope.visible_scopes(["company", "finance"])
          end
        end)

      avg_us = time_us / 1000
      # Sub-millisecond = < 1000 microseconds per lookup
      assert avg_us < 1000, "Average scope lookup took #{avg_us}μs, expected < 1000μs"
    end
  end
end
