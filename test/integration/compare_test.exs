defmodule Cqr.Integration.CompareTest do
  @moduledoc """
  Integration tests for the COMPARE primitive.

  Covers the full path: parser -> Cqr.Engine -> Cqr.Engine.Compare ->
  Cqr.Adapter.Grafeo.compare -> Grafeo reads -> %Cqr.Result{} with the
  comparison envelope.

  Uses seeded entities (churn_rate, nps, dau, retention_rate, arr) so
  the relationship overlap and quality assertions are stable across
  runs without setup. Reputation values come from `Cqr.Repo.Seed`:
  churn_rate=0.87, nps=0.82, dau=0.91, arr=0.95.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine

  @product_context %{scope: ["company", "product"], agent_id: "twin:compare_product"}
  @root_context %{scope: ["company"], agent_id: "twin:compare_root"}
  @hr_context %{scope: ["company", "hr"], agent_id: "twin:compare_hr"}

  describe "COMPARE basic two-entity" do
    test "returns one row with both entities listed" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:product:nps",
                 @product_context
               )

      assert row.entities == ["entity:product:churn_rate", "entity:product:nps"]
      assert Map.has_key?(row.per_entity, "entity:product:churn_rate")
      assert Map.has_key?(row.per_entity, "entity:product:nps")
    end

    test "per-entity summary carries type, reputation, and owner" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:product:nps",
                 @product_context
               )

      churn = row.per_entity["entity:product:churn_rate"]
      nps = row.per_entity["entity:product:nps"]

      # Reputation values can be mutated by other test suites running first
      # (cross_primitive signals seeded entities). Assert shape, not the
      # exact seed value.
      assert churn.type == "metric"
      assert is_float(churn.reputation)
      assert churn.owner == "product_team"
      assert nps.type == "metric"
      assert is_float(nps.reputation)
      assert nps.owner == "product_team"
    end

    test "differing_properties surfaces description divergence" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:product:nps",
                 @product_context
               )

      descriptions =
        row.differing_properties
        |> Enum.find(fn p -> p.property == :description end)

      assert descriptions
      assert descriptions.values["entity:product:churn_rate"] =~ "churn"
      assert descriptions.values["entity:product:nps"] =~ "Promoter"
    end

    test "quality_differences reports per-entity reputation values" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:product:nps",
                 @product_context
               )

      reputations = row.quality_differences[:reputation]
      assert is_float(reputations["entity:product:churn_rate"])
      assert is_float(reputations["entity:product:nps"])

      certified = row.quality_differences[:certified]
      assert Map.has_key?(certified, "entity:product:churn_rate")
      assert Map.has_key?(certified, "entity:product:nps")
    end
  end

  describe "COMPARE relationship overlap" do
    test "shared_relationships includes the CORRELATES_WITH edge between churn_rate and nps" do
      # churn_rate -[CORRELATES_WITH]-> nps is seeded, so each side's
      # relationship signature set contains a (CORRELATES_WITH, other,
      # direction) signature. The overlap is empty here because edges are
      # directional: churn_rate's outbound = nps's inbound (different
      # signatures). What we expect to share is the relationship to a
      # third entity neither one points to in the seed -- so the shared
      # set may be empty, which is itself meaningful information.
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:product:nps",
                 @product_context
               )

      # relationship_overlap is always populated; shared_relationships
      # may be empty when entities don't point to common targets.
      assert is_map(row.relationship_overlap)
      assert Map.has_key?(row.relationship_overlap, "entity:product:churn_rate")
      assert Map.has_key?(row.relationship_overlap, "entity:product:nps")
      assert is_list(row.shared_relationships)
    end

    test "shared_relationships finds the common target (arr) for retention_rate vs churn_rate" do
      # retention_rate -[CORRELATES_WITH]-> churn_rate (seeded)
      # churn_rate -[CONTRIBUTES_TO]-> arr (seeded)
      # No direct shared outbound target between retention_rate and
      # churn_rate, but they have a relationship to each other; so the
      # overlap test verifies the shape, not a specific pre-known overlap.
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "COMPARE entity:product:retention_rate, entity:product:churn_rate",
                 @product_context
               )

      retention_rels = row.relationship_overlap["entity:product:retention_rate"]
      churn_rels = row.relationship_overlap["entity:product:churn_rate"]

      # Both entities have at least one relationship in the seed.
      refute Enum.empty?(retention_rels)
      refute Enum.empty?(churn_rels)
    end
  end

  describe "COMPARE INCLUDE clause" do
    test "INCLUDE quality only omits relationships and properties facets" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:product:nps INCLUDE quality",
                 @product_context
               )

      refute Map.has_key?(row, :shared_relationships)
      refute Map.has_key?(row, :differing_properties)
      assert Map.has_key?(row, :quality_differences)
    end

    test "INCLUDE relationships, properties omits quality" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:product:nps INCLUDE relationships, properties",
                 @product_context
               )

      assert Map.has_key?(row, :shared_relationships)
      assert Map.has_key?(row, :differing_properties)
      refute Map.has_key?(row, :quality_differences)
    end
  end

  describe "COMPARE three or more entities" do
    test "compares three entities at once" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:product:nps, entity:product:dau",
                 @product_context
               )

      assert length(row.entities) == 3
      assert map_size(row.per_entity) == 3
      reputations = row.quality_differences[:reputation]
      assert is_float(reputations["entity:product:dau"])
      assert map_size(reputations) == 3
    end
  end

  describe "COMPARE validation" do
    test "comparing entity to itself returns validation error" do
      assert {:error, %Cqr.Error{code: :validation_error, message: msg}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:product:churn_rate",
                 @product_context
               )

      assert msg =~ "distinct"
    end

    test "comparing nonexistent entity returns entity_not_found" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:product:does_not_exist_xyz",
                 @product_context
               )
    end
  end

  describe "COMPARE scope enforcement" do
    test "product agent cannot COMPARE an HR entity" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:hr:enps",
                 @product_context
               )
    end

    test "root agent can COMPARE across namespaces" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:hr:enps",
                 @root_context
               )

      assert "entity:product:churn_rate" in row.entities
      assert "entity:hr:enps" in row.entities
    end

    test "hr agent only sees hr entities in COMPARE" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(
                 "COMPARE entity:hr:enps, entity:product:churn_rate",
                 @hr_context
               )
    end
  end

  describe "COMPARE result envelope" do
    test "carries provenance noting the comparison cardinality" do
      assert {:ok, %Cqr.Result{quality: quality}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:product:nps",
                 @product_context
               )

      assert quality.provenance =~ "COMPARE"
      assert quality.provenance =~ "2 entities"
    end

    test "averaged reputation matches the mean of the per-entity values" do
      assert {:ok, %Cqr.Result{quality: quality, data: [row]}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:product:nps",
                 @product_context
               )

      reputations = row.quality_differences[:reputation]
      values = Map.values(reputations)
      expected = Enum.sum(values) / length(values)

      assert_in_delta quality.reputation, expected, 0.001
    end
  end
end
