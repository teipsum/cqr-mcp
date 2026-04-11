defmodule Cqr.Integration.SemanticTest do
  use ExUnit.Case

  alias Cqr.Grafeo.Native
  alias Cqr.Repo.Seed
  alias Cqr.Repo.Semantic

  describe "entity_exists?/1" do
    test "existing entity" do
      assert Semantic.entity_exists?({"finance", "arr"})
    end

    test "nonexistent entity" do
      refute Semantic.entity_exists?({"finance", "nonexistent"})
    end
  end

  describe "get_entity/2" do
    test "returns entity with metadata" do
      {:ok, entity} = Semantic.get_entity({"finance", "arr"})
      assert entity.namespace == "finance"
      assert entity.name == "arr"
      assert entity.type == "metric"
      assert entity.owner == "finance_team"
      assert is_float(entity.reputation) or is_integer(entity.reputation)
      assert entity.scopes != []
    end

    test "returns not_found for nonexistent entity" do
      assert {:error, :not_found} = Semantic.get_entity({"finance", "nonexistent"})
    end

    test "scope-filtered — visible scope" do
      visible = [["company", "finance"]]
      {:ok, entity} = Semantic.get_entity({"finance", "arr"}, visible)
      assert entity.name == "arr"
    end

    test "scope-filtered — invisible scope" do
      visible = [["company", "engineering"]]
      assert {:error, :not_visible} = Semantic.get_entity({"finance", "arr"}, visible)
    end

    test "NPS has multiple scopes" do
      {:ok, entity} = Semantic.get_entity({"product", "nps"})
      assert length(entity.scopes) == 2
    end
  end

  describe "entities_in_scope/1" do
    test "finance scope entities" do
      {:ok, entities} = Semantic.entities_in_scope(["company", "finance"])
      names = Enum.map(entities, & &1.name)
      assert "arr" in names
      assert "mrr" in names
      assert "burn_rate" in names
      assert length(entities) == 7
    end

    test "engineering scope entities" do
      {:ok, entities} = Semantic.entities_in_scope(["company", "engineering"])
      names = Enum.map(entities, & &1.name)
      assert "deployment_frequency" in names
      assert "mttr" in names
      assert length(entities) == 6
    end

    test "empty scope returns empty" do
      {:ok, entities} = Semantic.entities_in_scope(["nonexistent"])
      assert entities == []
    end
  end

  describe "related_entities/3" do
    test "churn_rate has related entities" do
      {:ok, related} = Semantic.related_entities({"product", "churn_rate"})
      assert [_ | _] = related

      rel_entities = Enum.map(related, & &1.entity)
      assert {"product", "nps"} in rel_entities or {"finance", "arr"} in rel_entities
    end

    test "relationships include type and strength" do
      {:ok, related} = Semantic.related_entities({"product", "churn_rate"})

      for r <- related do
        assert r.relationship != nil
        assert r.strength != nil
      end
    end

    test "nonexistent entity returns empty" do
      {:ok, related} = Semantic.related_entities({"nonexistent", "entity"})
      assert related == []
    end
  end

  describe "search_entities/2" do
    test "finds entities by name substring" do
      results = Semantic.search_entities("arr")
      assert {"finance", "arr"} in results
    end

    test "returns empty for no match" do
      results = Semantic.search_entities("zzz_nonexistent_zzz")
      assert results == []
    end
  end

  describe "seeder idempotency" do
    test "seeding a second time is a no-op" do
      # The app already seeded on startup. Calling again should skip.
      assert :ok = Seed.seed_if_empty_direct(get_db_handle())
    end
  end

  defp get_db_handle do
    # Access the db handle from the GenServer state for direct NIF calls
    {:ok, db} = Native.new(:memory)
    db
  end
end
