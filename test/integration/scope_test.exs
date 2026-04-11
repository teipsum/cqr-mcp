defmodule Cqr.Integration.ScopeTest do
  use ExUnit.Case

  alias Cqr.Repo.ScopeTree
  alias Cqr.Scope

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
    test "root scope sees itself and all descendants" do
      visible = Scope.visible_scopes(["company"])
      assert ["company"] in visible
      assert ["company", "finance"] in visible
      assert ["company", "product"] in visible
      assert ["company", "engineering"] in visible
      assert ["company", "hr"] in visible
      assert ["company", "customer_success"] in visible
      assert length(visible) == 6
    end

    test "child scope sees self and parent" do
      visible = Scope.visible_scopes(["company", "finance"])
      assert ["company", "finance"] in visible
      assert ["company"] in visible
      # Leaf scope: no descendants, so just self + parent
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

    test "child scope IS accessible from parent" do
      # Parents own their descendants — bidirectional visibility along the
      # hierarchy. Siblings remain isolated.
      assert Scope.accessible?(["company"], ["company", "finance"])
    end
  end

  describe "authoritative_scope/2" do
    test "entity in agent's scope" do
      assert {:ok, ["company", "finance"]} =
               Scope.authoritative_scope({"finance", "arr"}, ["company", "finance"])
    end

    test "entity visible to parent scope" do
      # The root company agent owns all sub-scopes, so finance entities are
      # visible. authoritative_scope returns the entity's actual scope.
      assert {:ok, ["company", "finance"]} =
               Scope.authoritative_scope({"finance", "arr"}, ["company"])
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
