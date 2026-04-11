defmodule Cqr.Integration.AssertTest do
  @moduledoc """
  Integration tests for the ASSERT primitive.

  Covers the full path: parser → Cqr.Engine → Cqr.Engine.Assert →
  Cqr.Adapter.Grafeo → Grafeo writes → round-trip via RESOLVE/DISCOVER.

  Each test uses a unique entity name in the `test_assert` namespace to
  avoid interference, since Grafeo is shared in-process state across the
  test run (ExUnit sync mode).
  """

  use ExUnit.Case

  alias Cqr.Engine
  alias Cqr.Grafeo.Server, as: GrafeoServer
  alias Cqr.Repo.Semantic

  @product_context %{scope: ["company", "product"], agent_id: "twin:test"}
  @finance_context %{scope: ["company", "finance"], agent_id: "twin:finance"}

  # Helper: build a minimal valid ASSERT expression for the given entity name.
  defp minimal_assert(name, opts \\ []) do
    derived =
      Keyword.get(opts, :derived_from, ["entity:product:churn_rate", "entity:product:nps"])
      |> Enum.join(", ")

    base =
      ~s(ASSERT entity:test_assert:#{name} TYPE derived_metric ) <>
        ~s(DESCRIPTION "Test assertion #{name}" ) <>
        ~s(INTENT "Testing ASSERT primitive" ) <>
        ~s(DERIVED_FROM #{derived})

    base =
      case Keyword.get(opts, :scope) do
        nil -> base
        scope -> base <> " IN #{scope}"
      end

    case Keyword.get(opts, :confidence) do
      nil -> base
      conf -> base <> " CONFIDENCE #{conf}"
    end
  end

  describe "successful ASSERT" do
    test "with all required fields" do
      expr = minimal_assert("case1_basic")

      assert {:ok, result} = Engine.execute(expr, @product_context)

      assert %Cqr.Result{
               data: [
                 %{
                   namespace: "test_assert",
                   name: "case1_basic",
                   type: "derived_metric",
                   description: "Test assertion case1_basic",
                   certified: false,
                   confidence: 0.5,
                   reputation: 0.5,
                   asserted_by: "twin:test",
                   owner: "twin:test",
                   intent: "Testing ASSERT primitive",
                   derived_from: ["entity:product:churn_rate", "entity:product:nps"],
                   scopes: [["company", "product"]]
                 }
               ],
               sources: ["grafeo"]
             } = result

      assert result.quality.provenance == "ASSERT operation by twin:test"
      assert result.quality.certified_by == nil
      assert result.quality.owner == "twin:test"
    end

    test "with optional IN scope and CONFIDENCE" do
      expr =
        minimal_assert("case2_with_opts",
          scope: "scope:company:product",
          confidence: "0.85"
        )

      assert {:ok, result} = Engine.execute(expr, @product_context)

      assert [
               %{
                 name: "case2_with_opts",
                 confidence: 0.85,
                 scopes: [["company", "product"]]
               }
             ] = result.data

      assert result.quality.confidence == 0.85
    end

    test "via the cqr_assert MCP tool with relationships" do
      args = %{
        "entity" => "entity:test_assert:case3_with_rels",
        "type" => "derived_metric",
        "description" => "Test with typed relationships",
        "intent" => "Testing RELATES_TO handling",
        "derived_from" => "entity:product:churn_rate",
        "relationships" =>
          "CORRELATES_WITH:entity:product:nps:0.7,DEPENDS_ON:entity:product:feature_adoption:0.5"
      }

      # The MCP tool layer formats the result with string keys (JSON-ready),
      # so match on the string-keyed shape.
      assert {:ok,
              %{
                "data" => [
                  %{
                    "namespace" => "test_assert",
                    "name" => "case3_with_rels",
                    "type" => "derived_metric"
                  }
                ],
                "sources" => ["grafeo"]
              }} = CqrMcp.Tools.call("cqr_assert", args, @product_context)

      # Verify the relationships were actually written to Grafeo as typed edges.
      assert {:ok, rows} =
               GrafeoServer.query(
                 "MATCH (e:Entity {namespace: 'test_assert', name: 'case3_with_rels'})" <>
                   "-[r]->(t:Entity) " <>
                   "WHERE type(r) <> 'DERIVED_FROM' " <>
                   "RETURN type(r) AS rel_type, r.strength, t.name"
               )

      rel_types = rows |> Enum.map(& &1["rel_type"]) |> Enum.sort()
      assert rel_types == ["CORRELATES_WITH", "DEPENDS_ON"]
    end
  end

  describe "ASSERT failure cases" do
    test "entity already exists" do
      first = minimal_assert("case4_dup")
      assert {:ok, _} = Engine.execute(first, @product_context)

      assert {:error, %Cqr.Error{code: :entity_exists} = err} =
               Engine.execute(first, @product_context)

      assert err.message =~ "already exists"
      assert err.message =~ "entity:test_assert:case4_dup"
      assert err.retry_guidance =~ "CERTIFY"
    end

    test "derived_from entity does not exist" do
      expr =
        minimal_assert("case5_bad_derived",
          derived_from: ["entity:product:does_not_exist"]
        )

      assert {:error, %Cqr.Error{code: :entity_not_found} = err} =
               Engine.execute(expr, @product_context)

      assert err.message =~ "derived_from"
      assert err.message =~ "entity:product:does_not_exist"
    end

    test "scope not accessible (sibling scope)" do
      # Agent at company:finance cannot assert into company:engineering
      expr =
        minimal_assert("case6_bad_scope",
          derived_from: ["entity:finance:arr"],
          scope: "scope:company:engineering"
        )

      assert {:error, %Cqr.Error{code: :scope_access} = err} =
               Engine.execute(expr, @finance_context)

      assert err.suggestions |> Enum.any?(&(&1 == "scope:company:finance"))
    end

    test "missing INTENT clause" do
      expr =
        ~s(ASSERT entity:test_assert:case7a_no_intent TYPE metric ) <>
          ~s(DESCRIPTION "no intent" DERIVED_FROM entity:product:churn_rate)

      assert {:error, %Cqr.Error{code: :missing_required_field} = err} =
               Engine.execute(expr, @product_context)

      assert "INTENT" in err.details.missing
    end

    test "missing DERIVED_FROM clause" do
      expr =
        ~s(ASSERT entity:test_assert:case7b_no_derived TYPE metric ) <>
          ~s(DESCRIPTION "no lineage" INTENT "testing")

      assert {:error, %Cqr.Error{code: :missing_required_field} = err} =
               Engine.execute(expr, @product_context)

      assert "DERIVED_FROM" in err.details.missing
    end

    test "missing DESCRIPTION and TYPE" do
      expr =
        ~s(ASSERT entity:test_assert:case7c_sparse INTENT "sparse" ) <>
          ~s(DERIVED_FROM entity:product:churn_rate)

      assert {:error, %Cqr.Error{code: :missing_required_field} = err} =
               Engine.execute(expr, @product_context)

      assert "TYPE" in err.details.missing
      assert "DESCRIPTION" in err.details.missing
    end
  end

  describe "post-ASSERT visibility" do
    test "asserted entity is immediately visible via RESOLVE" do
      expr = minimal_assert("case8_resolve")
      assert {:ok, _} = Engine.execute(expr, @product_context)

      assert {:ok, result} =
               Engine.execute("RESOLVE entity:test_assert:case8_resolve", @product_context)

      assert [
               %{
                 namespace: "test_assert",
                 name: "case8_resolve",
                 type: "derived_metric",
                 certified: false,
                 reputation: 0.5,
                 owner: "twin:test",
                 scopes: [["company", "product"]]
               }
             ] = result.data
    end

    test "asserted entity appears in DISCOVER results as inbound DERIVED_FROM" do
      expr = minimal_assert("case9_discover")
      assert {:ok, _} = Engine.execute(expr, @product_context)

      # Discovering inbound from churn_rate must surface the new entity via
      # its DERIVED_FROM edge (inbound direction since churn_rate is the target).
      assert {:ok, result} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 1 DIRECTION inbound",
                 @product_context
               )

      assert Enum.any?(result.data, fn item ->
               item.entity == {"test_assert", "case9_discover"} and
                 item.relationship == "DERIVED_FROM" and
                 item.direction == "inbound"
             end)
    end
  end

  describe "governance" do
    test "assertion audit record is written with provenance" do
      expr = minimal_assert("case10_audit")
      assert {:ok, _} = Engine.execute(expr, @product_context)

      assert {:ok, [record]} =
               GrafeoServer.query(
                 "MATCH (r:AssertionRecord {entity_namespace: 'test_assert', " <>
                   "entity_name: 'case10_audit'}) " <>
                   "RETURN r.agent_id, r.intent, r.confidence, r.derived_from, r.record_id"
               )

      assert record["r.agent_id"] == "twin:test"
      assert record["r.intent"] == "Testing ASSERT primitive"
      assert record["r.confidence"] == 0.5
      assert record["r.derived_from"] == "entity:product:churn_rate,entity:product:nps"
      assert is_binary(record["r.record_id"])
      # Confirm the UUID shape
      assert String.length(record["r.record_id"]) == 36
    end
  end

  describe "atomicity" do
    test "failed derived_from validation leaves no entity behind" do
      expr =
        minimal_assert("case11_atomicity",
          derived_from: [
            "entity:product:churn_rate",
            "entity:product:does_not_exist_either"
          ]
        )

      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(expr, @product_context)

      # The entity node must not exist in Grafeo after a failed ASSERT.
      refute Semantic.entity_exists?({"test_assert", "case11_atomicity"})

      # And no stray AssertionRecord either.
      assert {:ok, []} =
               GrafeoServer.query(
                 "MATCH (r:AssertionRecord {entity_namespace: 'test_assert', " <>
                   "entity_name: 'case11_atomicity'}) RETURN r.record_id"
               )
    end
  end
end
