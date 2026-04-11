defmodule Cqr.Integration.SignalTest do
  @moduledoc """
  Integration tests for the SIGNAL primitive.

  Covers the full path: parser -> Cqr.Engine -> Cqr.Engine.Signal ->
  Cqr.Adapter.Grafeo -> Grafeo writes (SignalRecord + reputation update)
  -> round-trip via RESOLVE and TRACE.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine
  alias Cqr.Grafeo.Server, as: GrafeoServer

  @product_context %{scope: ["company", "product"], agent_id: "twin:signal_product"}
  @finance_context %{scope: ["company", "finance"], agent_id: "twin:signal_finance"}
  @hr_context %{scope: ["company", "hr"], agent_id: "twin:signal_hr"}

  setup do
    cleanup()
    on_exit(&cleanup/0)
    :ok
  end

  defp cleanup do
    for ns <- ["test_signal"] do
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'})-[r]-() DELETE r")
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'}) DELETE e")
      GrafeoServer.query("MATCH (r:AssertionRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:CertificationRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:SignalRecord {entity_namespace: '#{ns}'}) DELETE r")
    end

    # SignalRecords and reputation updates on the seeded entities also need to
    # be rolled back so tests don't bleed into each other.
    reset_seeded_reputation("product", "churn_rate", 0.87)
    reset_seeded_reputation("finance", "burn_rate", 0.88)
    reset_seeded_reputation("hr", "headcount", 0.97)

    GrafeoServer.query(
      "MATCH (e:Entity {namespace: 'product', name: 'churn_rate'})-[r:SIGNAL_EVENT]->(sr:SignalRecord) DELETE r"
    )

    GrafeoServer.query("MATCH (sr:SignalRecord) WHERE sr.agent_id CONTAINS 'signal' DELETE sr")

    :ok
  end

  defp reset_seeded_reputation(ns, name, score) do
    GrafeoServer.query(
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}) SET e.reputation = #{score}"
    )
  end

  defp assert_fixture(name, opts \\ []) do
    derived = Keyword.get(opts, :derived_from, ["entity:product:churn_rate"])
    context = Keyword.get(opts, :context, @product_context)

    expr =
      ~s(ASSERT entity:test_signal:#{name} TYPE observation ) <>
        ~s(DESCRIPTION "signal fixture #{name}" ) <>
        ~s(INTENT "signal test fixture" ) <>
        ~s(DERIVED_FROM #{Enum.join(derived, ", ")})

    Engine.execute(expr, context)
  end

  describe "successful SIGNAL" do
    test "updates reputation to 0.6 and RESOLVE reflects it" do
      assert {:ok, _} = assert_fixture("s01_basic")

      expr =
        ~s(SIGNAL reputation ON entity:test_signal:s01_basic SCORE 0.6 ) <>
          ~s(EVIDENCE "quality check")

      assert {:ok, %Cqr.Result{data: [row]}} = Engine.execute(expr, @product_context)

      assert row.new_reputation == 0.6
      assert row.evidence == "quality check"
      assert row.signaled_by == "twin:signal_product"

      assert {:ok, %Cqr.Result{data: [entity]}} =
               Engine.execute("RESOLVE entity:test_signal:s01_basic", @product_context)

      assert entity.reputation == 0.6
    end

    test "SIGNAL score 0.0 works (floor)" do
      assert {:ok, _} = assert_fixture("s02_floor")

      expr =
        ~s(SIGNAL reputation ON entity:test_signal:s02_floor SCORE 0.0 ) <>
          ~s(EVIDENCE "completely unreliable")

      assert {:ok, %Cqr.Result{data: [%{new_reputation: +0.0}]}} =
               Engine.execute(expr, @product_context)
    end

    test "SIGNAL score 1.0 works (ceiling)" do
      assert {:ok, _} = assert_fixture("s03_ceiling")

      expr =
        ~s(SIGNAL reputation ON entity:test_signal:s03_ceiling SCORE 1.0 ) <>
          ~s(EVIDENCE "fully trustworthy")

      assert {:ok, %Cqr.Result{data: [%{new_reputation: 1.0}]}} =
               Engine.execute(expr, @product_context)
    end
  end

  describe "validation errors" do
    test "SIGNAL score 1.5 returns out-of-range error" do
      assert {:ok, _} = assert_fixture("s04_over")

      expr =
        ~s(SIGNAL reputation ON entity:test_signal:s04_over SCORE 1.5 ) <>
          ~s(EVIDENCE "bad score")

      # 1.5 is parsed as 1.5; score validator catches it.
      assert {:error, %Cqr.Error{code: code}} = Engine.execute(expr, @product_context)
      assert code in [:validation_error, :parse_error]
    end

    test "nonexistent entity returns entity_not_found" do
      expr =
        ~s(SIGNAL reputation ON entity:test_signal:does_not_exist SCORE 0.5 ) <>
          ~s(EVIDENCE "nope")

      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(expr, @product_context)
    end
  end

  describe "sequential signals" do
    test "second SIGNAL overwrites reputation and both SignalRecords are visible" do
      assert {:ok, _} = assert_fixture("s05_seq")

      expr1 =
        ~s(SIGNAL reputation ON entity:test_signal:s05_seq SCORE 0.7 ) <>
          ~s(EVIDENCE "first signal")

      expr2 =
        ~s(SIGNAL reputation ON entity:test_signal:s05_seq SCORE 0.4 ) <>
          ~s(EVIDENCE "second signal")

      assert {:ok, _} = Engine.execute(expr1, @product_context)
      assert {:ok, _} = Engine.execute(expr2, @product_context)

      assert {:ok, %Cqr.Result{data: [entity]}} =
               Engine.execute("RESOLVE entity:test_signal:s05_seq", @product_context)

      assert entity.reputation == 0.4

      assert {:ok, %Cqr.Result{data: [trace_row]}} =
               Engine.execute("TRACE entity:test_signal:s05_seq", @product_context)

      assert length(trace_row.signal_history) == 2
      evidences = Enum.map(trace_row.signal_history, & &1.evidence)
      assert "first signal" in evidences
      assert "second signal" in evidences
    end
  end

  describe "SIGNAL preserves certification status" do
    test "signaling reputation on a certified entity leaves certified_by intact" do
      assert {:ok, _} = assert_fixture("s06_cert_preserved")

      entity_ref = "entity:test_signal:s06_cert_preserved"

      assert {:ok, _} = Engine.execute("CERTIFY #{entity_ref} STATUS proposed", @product_context)

      assert {:ok, _} =
               Engine.execute("CERTIFY #{entity_ref} STATUS under_review", @product_context)

      assert {:ok, _} =
               Engine.execute(
                 ~s(CERTIFY #{entity_ref} STATUS certified AUTHORITY "twin:reviewer"),
                 @product_context
               )

      signal_expr =
        ~s(SIGNAL reputation ON #{entity_ref} SCORE 0.5 ) <>
          ~s(EVIDENCE "reputation reassessment")

      assert {:ok, _} = Engine.execute(signal_expr, @product_context)

      assert {:ok, %Cqr.Result{data: [entity]}} =
               Engine.execute("RESOLVE #{entity_ref}", @product_context)

      assert entity.certified_by == "twin:reviewer"
      assert entity.certified == true
      assert entity.reputation == 0.5
    end
  end

  describe "scope enforcement" do
    test "product agent cannot SIGNAL an HR entity" do
      expr =
        ~s(SIGNAL reputation ON entity:hr:headcount SCORE 0.3 ) <>
          ~s(EVIDENCE "out of scope")

      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(expr, @product_context)
    end

    test "hr agent can SIGNAL hr entity" do
      expr =
        ~s(SIGNAL reputation ON entity:hr:headcount SCORE 0.9 ) <>
          ~s(EVIDENCE "quarterly audit passed")

      assert {:ok, _} = Engine.execute(expr, @hr_context)
    end

    test "finance agent cannot SIGNAL a product fixture" do
      assert {:ok, _} = assert_fixture("s07_product_only")

      expr =
        ~s(SIGNAL reputation ON entity:test_signal:s07_product_only SCORE 0.3 ) <>
          ~s(EVIDENCE "wrong scope")

      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(expr, @finance_context)
    end
  end

  describe "TRACE picks up SignalRecord" do
    test "after SIGNAL, TRACE shows the signal in signal_history" do
      assert {:ok, _} = assert_fixture("s08_trace_signal")

      signal_expr =
        ~s(SIGNAL reputation ON entity:test_signal:s08_trace_signal SCORE 0.65 ) <>
          ~s(EVIDENCE "verified by manual review")

      assert {:ok, _} = Engine.execute(signal_expr, @product_context)

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("TRACE entity:test_signal:s08_trace_signal", @product_context)

      assert [sig] = row.signal_history
      assert sig.new_reputation == 0.65
      assert sig.evidence == "verified by manual review"
      assert sig.agent == "twin:signal_product"
    end
  end
end
