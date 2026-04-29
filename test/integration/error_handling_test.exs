defmodule Cqr.Integration.ErrorHandlingTest do
  @moduledoc """
  Comprehensive error-handling coverage for every CQR primitive.

  The triggering bug was `cqr_update` on a non-existent entity hanging
  instead of returning a structured error. That report turned out to be
  a symptom of the earlier DirtyIo NIF wedge (centralised in
  `Cqr.Grafeo.Gql.escape/1` and bounded by `Cqr.Grafeo.Server.run_with_timeout/2`),
  but it also surfaced the need to pin error-path behaviour across the
  entire primitive surface so a future regression surfaces as a test
  failure, not a silent production hang.

  For every primitive this module verifies:

    * entity-not-found and scope-denied cases return
      `{:error, %Cqr.Error{code: :entity_not_found}}` (both collapse to
      the same code — a blocked entity is indistinguishable from a
      missing one by design, see `Cqr.Repo.Semantic.get_entity/2`),
    * invalid input returns a structured `%Cqr.Error{}` with the
      relevant code and the offending field in the message,
    * the error surfaces within a tight wall-clock budget (well inside
      the 30 s NIF timeout ceiling) so a future regression re-introduces
      as a plain test failure instead of a 30 s flake.

  A few primitives (ANCHOR, DISCOVER) intentionally absorb missing
  entities into an OK result — ANCHOR flags them in the data row,
  DISCOVER on a nonexistent anchor returns an empty neighborhood.
  Those design choices are pinned below too, so a future "helpful"
  rewrite that starts erroring on those cases trips immediately.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine
  alias Cqr.Grafeo.Server, as: GrafeoServer

  @product_context %{scope: ["company", "product"], agent_id: "twin:error_handling"}
  @namespace "test_error_handling"
  @budget_ms 1_000

  setup do
    cleanup()
    on_exit(&cleanup/0)
    :ok
  end

  defp cleanup do
    for ns <- [@namespace, "#{@namespace}:child"] do
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'})-[r]-() DELETE r")
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'}) DELETE e")
      GrafeoServer.query("MATCH (r:AssertionRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:CertificationRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:SignalRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:VersionRecord {entity_namespace: '#{ns}'}) DELETE r")
    end

    :ok
  end

  # --- RESOLVE ---------------------------------------------------------------

  describe "RESOLVE error handling" do
    test "missing entity returns entity_not_found under the budget" do
      assert %Cqr.Error{code: :entity_not_found} =
               err =
               run_error("RESOLVE entity:#{@namespace}:missing_resolve")

      assert err.message =~ "entity:#{@namespace}:missing_resolve"
      assert err.retry_guidance =~ "scope" or err.retry_guidance =~ "namespace"
    end

    test "entity outside the agent's visible scope returns entity_not_found" do
      # An entity that exists in a sibling subtree is indistinguishable from
      # missing: the error collapses to :entity_not_found so scope membership
      # does not leak across the visibility boundary.
      hr_context = %{scope: ["company", "hr"], agent_id: "twin:error_hr"}

      assert %Cqr.Error{code: :entity_not_found} =
               run_error("RESOLVE entity:product:churn_rate", hr_context)
    end

    test "scope the agent cannot see returns scope_access, not entity_not_found" do
      # An explicit FROM clause naming a scope outside the agent's sandbox
      # is a different class of error from a missing entity — the engine
      # rejects the request before any entity lookup.
      assert %Cqr.Error{code: :scope_access} =
               run_error("RESOLVE entity:product:churn_rate FROM scope:company:hr")
    end
  end

  # --- DISCOVER --------------------------------------------------------------

  describe "DISCOVER error handling" do
    test "nonexistent anchor entity returns an empty neighborhood, not an error" do
      # DISCOVER tolerates missing anchors by design — an agent uses this to
      # confirm a hypothesis has no reachable neighbors. Pinned here so a
      # future refactor that starts erroring breaks visibly.
      assert_completes_within(@budget_ms, fn ->
        assert {:ok, %Cqr.Result{data: []}} =
                 Engine.execute(
                   "DISCOVER concepts RELATED TO entity:#{@namespace}:missing_discover",
                   @product_context
                 )
      end)
    end

    test "prefix traversal from a missing anchor returns empty" do
      assert_completes_within(@budget_ms, fn ->
        assert {:ok, %Cqr.Result{data: []}} =
                 Engine.execute(
                   "DISCOVER concepts RELATED TO entity:#{@namespace}:missing:*",
                   @product_context
                 )
      end)
    end

    test "free-text search with no text matches returns a well-formed envelope" do
      # bge-small produces non-zero cosine similarity for any input, so a
      # nonsense token may still surface weak vector hits. The contract
      # tested here is that the engine returns a well-formed result envelope
      # (a Cqr.Result with a list of data) rather than crashing or hanging
      # on an unmatchable query — not that the result list is empty.
      assert_completes_within(@budget_ms, fn ->
        assert {:ok, %Cqr.Result{data: data}} =
                 Engine.execute(
                   ~s(DISCOVER concepts RELATED TO "xyzznonexistenttoken123"),
                   @product_context
                 )

        assert is_list(data)

        Enum.each(data, fn r ->
          combined = String.downcase("#{r.name} #{r.description || ""}")
          refute String.contains?(combined, "xyzznonexistenttoken123")
        end)
      end)
    end
  end

  # --- ASSERT ----------------------------------------------------------------

  describe "ASSERT error handling" do
    test "asserting a duplicate entity returns entity_exists" do
      # First ASSERT seeds the entity.
      seed =
        ~s(ASSERT entity:#{@namespace}:dup TYPE derived_metric ) <>
          ~s(DESCRIPTION "Seed" INTENT "Seed" ) <>
          ~s(DERIVED_FROM entity:product:churn_rate)

      assert {:ok, _} = Engine.execute(seed, @product_context)

      # Second ASSERT on the same entity must fail with :entity_exists.
      assert %Cqr.Error{code: :entity_exists} = err = run_error(seed)
      assert err.message =~ "entity:#{@namespace}:dup"
    end

    test "missing DERIVED_FROM returns missing_required_field" do
      expr =
        ~s(ASSERT entity:#{@namespace}:no_derived TYPE derived_metric ) <>
          ~s(DESCRIPTION "No lineage" INTENT "Regression")

      assert %Cqr.Error{code: :missing_required_field} = err = run_error(expr)
      assert err.message =~ "DERIVED_FROM"
    end

    test "dangling DERIVED_FROM reference returns entity_not_found" do
      expr =
        ~s(ASSERT entity:#{@namespace}:dangling TYPE derived_metric ) <>
          ~s(DESCRIPTION "Dangling source" INTENT "Regression" ) <>
          ~s(DERIVED_FROM entity:#{@namespace}:does_not_exist)

      assert %Cqr.Error{code: :entity_not_found} = err = run_error(expr)
      assert err.message =~ "does_not_exist"
    end

    test "CONFIDENCE out of range returns validation_error" do
      expr =
        ~s(ASSERT entity:#{@namespace}:bad_conf TYPE derived_metric ) <>
          ~s(DESCRIPTION "Bad confidence" INTENT "Regression" ) <>
          ~s(DERIVED_FROM entity:product:churn_rate CONFIDENCE 1.5)

      assert %Cqr.Error{code: :validation_error} = err = run_error(expr)
      assert err.message =~ "CONFIDENCE"
    end
  end

  # --- UPDATE (triggering bug) ----------------------------------------------

  describe "UPDATE error handling — triggering bug" do
    test "UPDATE on a missing entity returns entity_not_found within 1 s" do
      # This is the case the user reported as "hangs indefinitely". With the
      # centralised Gql.escape and the NIF timeout wrapper landed in
      # feature/fix-nif-hang-v2, the read path short-circuits before any
      # write query is constructed; the error surfaces in milliseconds.
      expr =
        ~s(UPDATE entity:#{@namespace}:missing_update CHANGE_TYPE correction ) <>
          ~s(DESCRIPTION "Would overwrite" EVIDENCE "Regression")

      assert %Cqr.Error{code: :entity_not_found} = err = run_error(expr)
      assert err.message =~ "missing_update"
    end

    test "UPDATE on a hierarchical missing entity returns entity_not_found" do
      # Hierarchical addresses walk the containment path; a missing ancestor
      # must also collapse to :entity_not_found rather than leaking the
      # shape of the missing container chain.
      expr =
        ~s(UPDATE entity:#{@namespace}:child:missing CHANGE_TYPE correction ) <>
          ~s(DESCRIPTION "Would overwrite" EVIDENCE "Regression")

      assert %Cqr.Error{code: :entity_not_found} = run_error(expr)
    end

    test "UPDATE with missing CHANGE_TYPE returns missing_required_field" do
      seed_entity("needs_ct")

      expr =
        ~s(UPDATE entity:#{@namespace}:needs_ct ) <>
          ~s(DESCRIPTION "No change type" EVIDENCE "Regression")

      assert %Cqr.Error{code: :missing_required_field} = err = run_error(expr)
      assert err.message =~ "CHANGE_TYPE"
    end

    test "UPDATE with CONFIDENCE out of range returns validation_error" do
      seed_entity("bad_conf")

      expr =
        ~s(UPDATE entity:#{@namespace}:bad_conf CHANGE_TYPE correction ) <>
          ~s(DESCRIPTION "Bad confidence" EVIDENCE "Regression" CONFIDENCE 2.0)

      assert %Cqr.Error{code: :validation_error} = err = run_error(expr)
      assert err.message =~ "CONFIDENCE"
    end

    test "UPDATE on a contested entity is blocked with invalid_transition" do
      # Reproduces the governance matrix's "contest in flight" branch so
      # a refactor that collapses the matrix back to a single "permit
      # everything" path trips immediately.
      seed_entity("contest_me")

      assert {:ok, _} =
               Engine.execute(
                 "CERTIFY entity:#{@namespace}:contest_me STATUS proposed",
                 @product_context
               )

      assert {:ok, _} =
               Engine.execute(
                 "CERTIFY entity:#{@namespace}:contest_me STATUS under_review",
                 @product_context
               )

      assert {:ok, _} =
               Engine.execute(
                 "CERTIFY entity:#{@namespace}:contest_me STATUS certified AUTHORITY board",
                 @product_context
               )

      # :standard policy + :redefinition on a certified entity routes into
      # the pending-review path, leaving the entity in :contested.
      assert {:ok, _} =
               Engine.execute(
                 ~s(UPDATE entity:#{@namespace}:contest_me CHANGE_TYPE redefinition ) <>
                   ~s(DESCRIPTION "Rewrite" EVIDENCE "Contest"),
                 @product_context
               )

      # Second UPDATE on the now-contested entity must be blocked.
      assert %Cqr.Error{code: :invalid_transition} =
               err =
               run_error(
                 ~s(UPDATE entity:#{@namespace}:contest_me CHANGE_TYPE correction ) <>
                   ~s(DESCRIPTION "Again" EVIDENCE "Should be blocked")
               )

      assert err.message =~ "contest" or err.retry_guidance =~ "contest"
    end
  end

  # --- CERTIFY ---------------------------------------------------------------

  describe "CERTIFY error handling" do
    test "CERTIFY on a missing entity returns entity_not_found" do
      expr = "CERTIFY entity:#{@namespace}:missing_certify STATUS proposed"

      assert %Cqr.Error{code: :entity_not_found} = err = run_error(expr)
      assert err.message =~ "missing_certify"
    end

    test "invalid status transition returns invalid_transition" do
      # Fresh entities start at status=nil; the only legal first transition
      # is to :proposed. Jumping straight to :certified must be rejected.
      seed_entity("bad_transition")

      expr = "CERTIFY entity:#{@namespace}:bad_transition STATUS certified AUTHORITY board"

      assert %Cqr.Error{code: :invalid_transition} = err = run_error(expr)
      # The matrix currently stores the status atom in inspect form, so the
      # message reads "Cannot transition from nil to :certified".
      assert err.message =~ "transition"
    end
  end

  # --- TRACE -----------------------------------------------------------------

  describe "TRACE error handling" do
    test "TRACE on a missing entity returns entity_not_found" do
      assert %Cqr.Error{code: :entity_not_found} =
               err =
               run_error("TRACE entity:#{@namespace}:missing_trace")

      assert err.message =~ "missing_trace"
    end
  end

  # --- SIGNAL ----------------------------------------------------------------

  describe "SIGNAL error handling" do
    test "SIGNAL on a missing entity returns entity_not_found" do
      expr =
        ~s(SIGNAL reputation ON entity:#{@namespace}:missing_signal ) <>
          ~s(SCORE 0.8 EVIDENCE "Regression")

      assert %Cqr.Error{code: :entity_not_found} = err = run_error(expr)
      assert err.message =~ "missing_signal"
    end

    test "SCORE out of range returns validation_error" do
      seed_entity("bad_score")

      expr =
        ~s(SIGNAL reputation ON entity:#{@namespace}:bad_score ) <>
          ~s(SCORE 1.5 EVIDENCE "Out of range")

      assert %Cqr.Error{code: :validation_error} = err = run_error(expr)
      assert err.message =~ "SCORE"
    end

    test "missing EVIDENCE returns missing_required_field" do
      seed_entity("no_evidence")

      expr = ~s(SIGNAL reputation ON entity:#{@namespace}:no_evidence SCORE 0.7)

      assert %Cqr.Error{code: :missing_required_field} = err = run_error(expr)
      assert err.message =~ "EVIDENCE"
    end
  end

  # --- REFRESH ---------------------------------------------------------------

  describe "REFRESH error handling" do
    test "REFRESH completes within the budget and returns a structured result" do
      # Absence of stale work is a valid outcome, not a failure — REFRESH
      # returns {:ok, [...]} with zero or more rows depending on what the
      # surrounding suite has seeded. Pin the wall-clock and shape only
      # so the hang regression surfaces, not test-order noise.
      assert_completes_within(@budget_ms, fn ->
        assert {:ok, %Cqr.Result{data: data}} =
                 Engine.execute(
                   "REFRESH CHECK active_context WHERE age > 7d",
                   @product_context
                 )

        assert is_list(data)
      end)
    end

    test "REFRESH with an out-of-sandbox WITHIN returns scope_access" do
      # A WITHIN scope the agent has no visibility into must be rejected
      # up-front — scope narrowing runs before any adapter is consulted.
      hr_context = %{scope: ["company", "hr"], agent_id: "twin:refresh_hr"}

      assert %Cqr.Error{code: :scope_access} =
               run_error(
                 "REFRESH CHECK active_context WITHIN scope:company:product WHERE age > 24h",
                 hr_context
               )
    end
  end

  # --- AWARENESS -------------------------------------------------------------

  describe "AWARENESS error handling" do
    test "AWARENESS completes within the budget and returns a structured result" do
      # AWARENESS against a lightly-populated sandbox must not hang. The
      # outer suite leaves audit rows from other tests behind, so this
      # test pins the wall-clock guarantee rather than a specific row
      # count — the hang regression is what we're guarding against.
      assert_completes_within(@budget_ms, fn ->
        assert {:ok, %Cqr.Result{data: data}} =
                 Engine.execute("AWARENESS active_agents", @product_context)

        assert is_list(data)
      end)
    end

    test "AWARENESS with an out-of-sandbox WITHIN returns scope_access" do
      hr_context = %{scope: ["company", "hr"], agent_id: "twin:awareness_hr"}

      assert %Cqr.Error{code: :scope_access} =
               run_error("AWARENESS active_agents WITHIN scope:company:product", hr_context)
    end
  end

  # --- HYPOTHESIZE -----------------------------------------------------------

  describe "HYPOTHESIZE error handling" do
    test "HYPOTHESIZE on a missing entity returns entity_not_found" do
      expr =
        ~s(HYPOTHESIZE entity:#{@namespace}:missing_hypo ) <>
          ~s(CHANGE reputation TO 0.2)

      assert %Cqr.Error{code: :entity_not_found} = err = run_error(expr)
      assert err.message =~ "missing_hypo"
    end

    test "HYPOTHESIZE reputation target out of range returns invalid_input" do
      seed_entity("bad_hypo")

      expr =
        ~s(HYPOTHESIZE entity:#{@namespace}:bad_hypo ) <>
          ~s(CHANGE reputation TO 1.5)

      assert %Cqr.Error{code: :invalid_input} = err = run_error(expr)
      assert err.message =~ "reputation" or err.message =~ "CHANGE"
    end
  end

  # --- COMPARE ---------------------------------------------------------------

  describe "COMPARE error handling" do
    test "COMPARE with one missing entity returns entity_not_found" do
      # Seed one entity so only the second is missing — the engine's
      # ensure_all_visible halts on the first missing reference.
      seed_entity("cmp_exists")

      expr =
        "COMPARE entity:#{@namespace}:cmp_exists, " <>
          "entity:#{@namespace}:cmp_missing"

      assert %Cqr.Error{code: :entity_not_found} = err = run_error(expr)
      assert err.message =~ "cmp_missing"
    end

    test "COMPARE of an entity with itself returns validation_error" do
      seed_entity("cmp_self")

      expr =
        "COMPARE entity:#{@namespace}:cmp_self, " <>
          "entity:#{@namespace}:cmp_self"

      assert %Cqr.Error{code: :validation_error} = err = run_error(expr)
      assert err.message =~ "distinct" or err.message =~ "duplicate"
    end
  end

  # --- ANCHOR ----------------------------------------------------------------

  describe "ANCHOR error handling" do
    test "ANCHOR with a missing entity in the chain flags it as missing in data" do
      # ANCHOR's design is to return a structured assessment even when
      # links are missing — the data row lists them, and chain_confidence
      # gets a ×0.5 penalty per missing link. The caller then acts on the
      # recommendations rather than on a top-level error.
      assert_completes_within(@budget_ms, fn ->
        assert {:ok, %Cqr.Result{data: [row]}} =
                 Engine.execute(
                   "ANCHOR entity:product:churn_rate, " <>
                     "entity:#{@namespace}:anchor_missing",
                   @product_context
                 )

        assert row.missing != []
        assert Enum.any?(row.missing, &String.contains?(&1, "anchor_missing"))
      end)
    end

    test "ANCHOR with an entity outside the agent's scope collapses to missing" do
      # Scope denial is indistinguishable from non-existence — ANCHOR
      # buckets both into the same `missing` list so scope membership
      # does not leak via the chain assessment.
      hr_context = %{scope: ["company", "hr"], agent_id: "twin:anchor_hr"}

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "ANCHOR entity:hr:headcount, entity:product:churn_rate",
                 hr_context
               )

      assert Enum.any?(row.missing, &String.contains?(&1, "product:churn_rate"))
    end
  end

  # --- Helpers ---------------------------------------------------------------

  # Execute `expr` and assert it returns `{:error, %Cqr.Error{}}` within the
  # budget. Returns the error struct for further assertions. A timeout
  # reproduces a regression (hang), and is flagged as such so the failure
  # message points at the NIF-hang class rather than generic timeout.
  defp run_error(expr, context \\ @product_context) do
    result =
      assert_completes_within(@budget_ms, fn ->
        Engine.execute(expr, context)
      end)

    assert {:error, %Cqr.Error{} = err} = result
    err
  end

  defp seed_entity(name) do
    expr =
      ~s(ASSERT entity:#{@namespace}:#{name} TYPE derived_metric ) <>
        ~s(DESCRIPTION "Seed for error handling" ) <>
        ~s(INTENT "Error-handling fixture" ) <>
        ~s(DERIVED_FROM entity:product:churn_rate)

    assert {:ok, _} = Engine.execute(expr, @product_context)
    {@namespace, name}
  end

  # Run `fun` inside a Task with a hard wall-clock budget. A hung NIF would
  # otherwise stall the test for the full 30 s GenServer ceiling; surfacing
  # the hang as a plain ExUnit failure keeps the regression fingerprint
  # clear.
  defp assert_completes_within(timeout_ms, fun) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} ->
        value

      nil ->
        flunk(
          "operation did not complete within #{timeout_ms}ms — probable NIF hang " <>
            "or regression in an error path"
        )
    end
  end
end
