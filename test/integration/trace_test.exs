defmodule Cqr.Integration.TraceTest do
  @moduledoc """
  Integration tests for the TRACE primitive.

  Covers the full path: parser -> Cqr.Engine -> Cqr.Engine.Trace ->
  Cqr.Adapter.Grafeo -> Grafeo reads -> %Cqr.Result{} with the
  provenance envelope.

  Every test uses a unique entity name in the `test_trace` namespace so
  reruns are deterministic and other suites stay untouched.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine
  alias Cqr.Grafeo.Server, as: GrafeoServer

  @product_context %{scope: ["company", "product"], agent_id: "twin:trace_product"}
  @finance_context %{scope: ["company", "finance"], agent_id: "twin:trace_finance"}
  @hr_context %{scope: ["company", "hr"], agent_id: "twin:trace_hr"}

  setup do
    cleanup()
    on_exit(&cleanup/0)
    :ok
  end

  defp cleanup do
    for ns <- ["test_trace"] do
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'})-[r]-() DELETE r")
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'}) DELETE e")
      GrafeoServer.query("MATCH (r:AssertionRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:CertificationRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:SignalRecord {entity_namespace: '#{ns}'}) DELETE r")
    end

    :ok
  end

  defp assert_fixture(name, opts \\ []) do
    derived = Keyword.get(opts, :derived_from, ["entity:product:churn_rate"])
    context = Keyword.get(opts, :context, @product_context)
    description = Keyword.get(opts, :description, "trace fixture #{name}")

    expr =
      ~s(ASSERT entity:test_trace:#{name} TYPE observation ) <>
        ~s(DESCRIPTION "#{description}" ) <>
        ~s(INTENT "trace test fixture" ) <>
        ~s(DERIVED_FROM #{Enum.join(derived, ", ")})

    Engine.execute(expr, context)
  end

  describe "TRACE on seeded entities (no assertion / cert history)" do
    test "returns current_state with empty assertion and empty certification_history" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("TRACE entity:product:churn_rate", @product_context)

      assert row.entity == "entity:product:churn_rate"
      assert row.assertion == nil
      assert row.certification_history == []
      assert row.signal_history == []
      assert row.current_state.type == "metric"
      assert row.current_state.description =~ "churn"
      assert row.current_state.reputation == 0.87
    end
  end

  describe "TRACE after ASSERT" do
    test "returns assertion record with asserted_by, intent, and derived_from" do
      assert {:ok, _} = assert_fixture("t01_asserted")

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("TRACE entity:test_trace:t01_asserted", @product_context)

      assert %{
               asserted_by: "twin:trace_product",
               intent: "trace test fixture",
               derived_from: ["entity:product:churn_rate"]
             } = row.assertion

      assert is_binary(row.assertion.asserted_at)
    end
  end

  describe "TRACE after CERTIFY lifecycle" do
    test "returns full certification history with 3 transitions" do
      assert {:ok, _} = assert_fixture("t02_certified")

      entity_ref = "entity:test_trace:t02_certified"

      assert {:ok, _} =
               Engine.execute("CERTIFY #{entity_ref} STATUS proposed", @product_context)

      assert {:ok, _} =
               Engine.execute("CERTIFY #{entity_ref} STATUS under_review", @product_context)

      assert {:ok, _} =
               Engine.execute(
                 ~s(CERTIFY #{entity_ref} STATUS certified AUTHORITY "twin:reviewer" EVIDENCE "LGTM"),
                 @product_context
               )

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("TRACE #{entity_ref}", @product_context)

      assert [proposed, under_review, certified] = row.certification_history
      assert proposed.to_status == "proposed"
      assert under_review.from_status == "proposed"
      assert under_review.to_status == "under_review"
      assert certified.from_status == "under_review"
      assert certified.to_status == "certified"
      assert certified.authority == "twin:reviewer"
      assert certified.evidence == "LGTM"
    end
  end

  describe "TRACE with causal depth" do
    test "depth 2 walks A->B->C chain" do
      assert {:ok, _} =
               assert_fixture("t03_b",
                 derived_from: ["entity:product:churn_rate"],
                 description: "intermediate B"
               )

      assert {:ok, _} =
               assert_fixture("t03_a",
                 derived_from: ["entity:test_trace:t03_b"],
                 description: "top A"
               )

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "TRACE entity:test_trace:t03_a DEPTH causal:2",
                 @product_context
               )

      entities = Enum.map(row.derived_from_chain, & &1.entity)
      assert "entity:test_trace:t03_b" in entities
      assert "entity:product:churn_rate" in entities

      depths = Enum.map(row.derived_from_chain, & &1.depth)
      assert 1 in depths
      assert 2 in depths
    end

    test "default depth 1 returns only immediate sources" do
      assert {:ok, _} =
               assert_fixture("t04_b",
                 derived_from: ["entity:product:churn_rate"]
               )

      assert {:ok, _} =
               assert_fixture("t04_a",
                 derived_from: ["entity:test_trace:t04_b"]
               )

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("TRACE entity:test_trace:t04_a", @product_context)

      depths = Enum.map(row.derived_from_chain, & &1.depth)
      assert Enum.all?(depths, &(&1 == 1))

      entities = Enum.map(row.derived_from_chain, & &1.entity)
      assert "entity:test_trace:t04_b" in entities
      refute "entity:product:churn_rate" in entities
    end
  end

  describe "TRACE referenced_by" do
    test "seeded source surfaces the asserted entity that derived from it" do
      assert {:ok, _} =
               assert_fixture("t05_consumer", derived_from: ["entity:product:churn_rate"])

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("TRACE entity:product:churn_rate", @product_context)

      entities = Enum.map(row.referenced_by, & &1.entity)
      assert "entity:test_trace:t05_consumer" in entities
    end
  end

  describe "TRACE error handling" do
    test "nonexistent entity returns entity_not_found" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute("TRACE entity:test_trace:does_not_exist", @product_context)
    end
  end

  describe "scope enforcement" do
    test "product agent cannot TRACE an HR entity" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute("TRACE entity:hr:headcount", @product_context)
    end

    test "hr agent CAN trace hr entity" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("TRACE entity:hr:headcount", @hr_context)

      assert row.entity == "entity:hr:headcount"
    end

    test "finance agent cannot see product fixtures" do
      assert {:ok, _} = assert_fixture("t06_product_only")

      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute("TRACE entity:test_trace:t06_product_only", @finance_context)
    end
  end
end
