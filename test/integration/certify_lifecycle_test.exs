defmodule Cqr.Integration.CertifyLifecycleTest do
  @moduledoc """
  Integration tests for the CERTIFY primitive's governance lifecycle.

  Covers the full path: parser → `Cqr.Engine` → `Cqr.Engine.Certify` →
  Grafeo writes → round-trip via RESOLVE and direct audit-trail queries.

  Each test uses a fresh entity name in the `test_certify` namespace to
  avoid interference, since Grafeo is shared in-process state across the
  test run. The entities are created via ASSERT at the start of each test
  that needs one, which also exercises the ASSERT → CERTIFY pipeline.
  """

  use ExUnit.Case

  alias Cqr.Engine
  alias Cqr.Grafeo.Server, as: GrafeoServer

  @product_context %{scope: ["company", "product"], agent_id: "twin:product"}
  @finance_context %{scope: ["company", "finance"], agent_id: "twin:finance"}

  # Helper: ASSERT a fresh test_certify entity in the product scope and
  # return its {ns, name} tuple.
  defp assert_test_entity(name, context \\ @product_context) do
    expr =
      ~s(ASSERT entity:test_certify:#{name} TYPE derived_metric ) <>
        ~s(DESCRIPTION "Lifecycle test entity #{name}" ) <>
        ~s(INTENT "Exercise CERTIFY lifecycle" ) <>
        ~s(DERIVED_FROM entity:product:churn_rate)

    assert {:ok, _} = Engine.execute(expr, context)
    {"test_certify", name}
  end

  defp certify(entity_ref, status, opts, context) do
    authority = Keyword.get(opts, :authority)
    evidence = Keyword.get(opts, :evidence)

    parts = ["CERTIFY #{entity_ref} STATUS #{status}"]
    # AUTHORITY accepts either a bare identifier or a quoted string. Authorities
    # containing colons (e.g. "authority:data_governance_board") must be quoted
    # because the identifier grammar is [a-z_][a-z0-9_]*.
    parts =
      cond do
        is_nil(authority) -> parts
        String.contains?(authority, ":") -> parts ++ [~s(AUTHORITY "#{authority}")]
        true -> parts ++ ["AUTHORITY #{authority}"]
      end

    parts = if evidence, do: parts ++ [~s(EVIDENCE "#{evidence}")], else: parts

    Engine.execute(Enum.join(parts, " "), context)
  end

  defp certify(entity_ref, status, opts),
    do: certify(entity_ref, status, opts, @product_context)

  describe "full lifecycle: proposed → under_review → certified" do
    test "writes a CertificationRecord per phase and updates the entity" do
      assert_test_entity("case1_full_lifecycle")

      # Phase 1: proposed
      assert {:ok, r1} =
               certify("entity:test_certify:case1_full_lifecycle", "proposed",
                 authority: "product_lead",
                 evidence: "Initial proposal"
               )

      assert hd(r1.data).new_status == :proposed
      assert hd(r1.data).previous_status == nil

      # Phase 2: under_review
      assert {:ok, r2} =
               certify("entity:test_certify:case1_full_lifecycle", "under_review",
                 authority: "review_board",
                 evidence: "Under review by board"
               )

      assert hd(r2.data).new_status == :under_review
      assert hd(r2.data).previous_status == :proposed

      # Phase 3: certified
      assert {:ok, r3} =
               certify("entity:test_certify:case1_full_lifecycle", "certified",
                 authority: "authority:data_governance_board",
                 evidence: "Formally certified"
               )

      assert hd(r3.data).new_status == :certified
      assert hd(r3.data).previous_status == :under_review
      assert r3.quality.certified_by == "authority:data_governance_board"
      assert %DateTime{} = r3.quality.certified_at
      assert r3.quality.reputation >= 0.9

      # Round-trip via RESOLVE — the quality envelope should reflect the
      # certification state rather than falling back to the original owner.
      assert {:ok, resolved} =
               Engine.execute(
                 "RESOLVE entity:test_certify:case1_full_lifecycle",
                 @product_context
               )

      [entity] = resolved.data
      assert entity.certified == true
      assert entity.certified_by == "authority:data_governance_board"
      assert is_binary(entity.certified_at)
      assert entity.reputation >= 0.9

      assert resolved.quality.certified_by == "authority:data_governance_board"
      assert %DateTime{} = resolved.quality.certified_at
      assert resolved.quality.reputation >= 0.9
    end
  end

  describe "state transition enforcement" do
    test "proposed → certified (skipping under_review) fails" do
      assert_test_entity("case2_skip_review")

      assert {:ok, _} =
               certify("entity:test_certify:case2_skip_review", "proposed",
                 authority: "product_lead"
               )

      assert {:error, err} =
               certify("entity:test_certify:case2_skip_review", "certified",
                 authority: "product_lead"
               )

      assert err.code == :invalid_transition
      assert err.retry_guidance =~ "Valid next states"
      assert err.retry_guidance =~ "under_review"
    end

    test "certified → proposed fails" do
      assert_test_entity("case2_cert_to_proposed")

      for status <- ["proposed", "under_review", "certified"] do
        assert {:ok, _} =
                 certify("entity:test_certify:case2_cert_to_proposed", status,
                   authority: "product_lead"
                 )
      end

      assert {:error, err} =
               certify("entity:test_certify:case2_cert_to_proposed", "proposed",
                 authority: "product_lead"
               )

      assert err.code == :invalid_transition
      assert err.retry_guidance =~ "Valid next states"
    end

    test "under_review → proposed is allowed (returning to draft)" do
      # The state machine intentionally permits under_review → proposed so a
      # reviewer can bounce a proposal back. This test locks in that shape.
      assert_test_entity("case2_review_to_proposed")

      assert {:ok, _} =
               certify("entity:test_certify:case2_review_to_proposed", "proposed",
                 authority: "product_lead"
               )

      assert {:ok, _} =
               certify("entity:test_certify:case2_review_to_proposed", "under_review",
                 authority: "product_lead"
               )

      assert {:ok, _} =
               certify("entity:test_certify:case2_review_to_proposed", "proposed",
                 authority: "product_lead"
               )
    end
  end

  describe "superseded lifecycle" do
    test "certified → superseded drops reputation and clears certified flag" do
      assert_test_entity("case3_supersedes")

      for status <- ["proposed", "under_review", "certified"] do
        assert {:ok, _} =
                 certify("entity:test_certify:case3_supersedes", status,
                   authority: "product_lead"
                 )
      end

      assert {:ok, resolved_certified} =
               Engine.execute(
                 "RESOLVE entity:test_certify:case3_supersedes",
                 @product_context
               )

      assert hd(resolved_certified.data).reputation >= 0.9

      assert {:ok, _} =
               certify("entity:test_certify:case3_supersedes", "superseded",
                 authority: "product_lead",
                 evidence: "Replaced by newer metric"
               )

      assert {:ok, resolved_after} =
               Engine.execute(
                 "RESOLVE entity:test_certify:case3_supersedes",
                 @product_context
               )

      [entity] = resolved_after.data
      assert entity.certified == false
      assert entity.reputation <= 0.3
    end
  end

  describe "contested lifecycle" do
    test "certified -> contested -> under_review is allowed" do
      assert_test_entity("case_contested_path")

      for status <- ["proposed", "under_review", "certified"] do
        assert {:ok, _} =
                 certify("entity:test_certify:case_contested_path", status,
                   authority: "product_lead"
                 )
      end

      assert {:ok, r_contested} =
               certify("entity:test_certify:case_contested_path", "contested",
                 authority: "challenger",
                 evidence: "Definition challenged by review"
               )

      assert hd(r_contested.data).new_status == :contested
      assert hd(r_contested.data).previous_status == :certified

      assert {:ok, r_review} =
               certify("entity:test_certify:case_contested_path", "under_review",
                 authority: "review_board"
               )

      assert hd(r_review.data).new_status == :under_review
      assert hd(r_review.data).previous_status == :contested
    end

    test "contested -> certified directly is blocked" do
      assert_test_entity("case_contested_skip")

      for status <- ["proposed", "under_review", "certified", "contested"] do
        assert {:ok, _} =
                 certify("entity:test_certify:case_contested_skip", status,
                   authority: "product_lead"
                 )
      end

      assert {:error, err} =
               certify("entity:test_certify:case_contested_skip", "certified",
                 authority: "product_lead"
               )

      assert err.code == :invalid_transition
      assert err.retry_guidance =~ "under_review"
    end

    test "contested entity preserves the certified reputation value" do
      assert_test_entity("case_contested_reputation")

      for status <- ["proposed", "under_review", "certified"] do
        assert {:ok, _} =
                 certify("entity:test_certify:case_contested_reputation", status,
                   authority: "product_lead"
                 )
      end

      assert {:ok, before} =
               Engine.execute(
                 "RESOLVE entity:test_certify:case_contested_reputation",
                 @product_context
               )

      certified_reputation = hd(before.data).reputation
      assert certified_reputation >= 0.9

      assert {:ok, _} =
               certify("entity:test_certify:case_contested_reputation", "contested",
                 authority: "challenger",
                 evidence: "Contesting current definition"
               )

      assert {:ok, after_contest} =
               Engine.execute(
                 "RESOLVE entity:test_certify:case_contested_reputation",
                 @product_context
               )

      assert hd(after_contest.data).reputation == certified_reputation
    end
  end

  describe "superseded revival" do
    test "superseded -> proposed re-enters the lifecycle" do
      assert_test_entity("case_revive")

      for status <- ["proposed", "under_review", "certified", "superseded"] do
        assert {:ok, _} =
                 certify("entity:test_certify:case_revive", status, authority: "product_lead")
      end

      assert {:ok, r_revived} =
               certify("entity:test_certify:case_revive", "proposed",
                 authority: "product_lead",
                 evidence: "Revived after new evidence"
               )

      assert hd(r_revived.data).new_status == :proposed
      assert hd(r_revived.data).previous_status == :superseded
    end

    test "superseded -> certified directly is blocked" do
      assert_test_entity("case_revive_skip")

      for status <- ["proposed", "under_review", "certified", "superseded"] do
        assert {:ok, _} =
                 certify("entity:test_certify:case_revive_skip", status,
                   authority: "product_lead"
                 )
      end

      assert {:error, err} =
               certify("entity:test_certify:case_revive_skip", "certified",
                 authority: "product_lead"
               )

      assert err.code == :invalid_transition
      assert err.retry_guidance =~ "proposed"
    end
  end

  describe "audit trail query" do
    test "three CertificationRecord nodes exist after full lifecycle, each with a unique UUID" do
      assert_test_entity("case4_audit_trail")

      for status <- ["proposed", "under_review", "certified"] do
        assert {:ok, _} =
                 certify("entity:test_certify:case4_audit_trail", status,
                   authority: "product_lead",
                   evidence: "Evidence for #{status}"
                 )
      end

      # Query CertificationRecord nodes directly via the CERTIFICATION_EVENT edge.
      assert {:ok, rows} =
               GrafeoServer.query(
                 "MATCH (e:Entity {namespace: 'test_certify', name: 'case4_audit_trail'})" <>
                   "-[:CERTIFICATION_EVENT]->(r:CertificationRecord) " <>
                   "RETURN r.record_id, r.new_status, r.previous_status, " <>
                   "r.timestamp, r.evidence, r.authority"
               )

      assert length(rows) == 3

      statuses = rows |> Enum.map(& &1["r.new_status"]) |> Enum.sort()
      assert statuses == ["certified", "proposed", "under_review"]

      # Every record has a UUIDv4 identifier.
      ids = Enum.map(rows, & &1["r.record_id"])
      assert Enum.all?(ids, fn id -> is_binary(id) and String.length(id) == 36 end)
      assert length(Enum.uniq(ids)) == 3

      # Timestamps parse as ISO8601 and are in chronological order when sorted
      # by new_status following the lifecycle sequence. Since records are
      # append-only, sorting by timestamp should also yield the phase order.
      sorted =
        rows
        |> Enum.sort_by(fn row ->
          {:ok, dt, _} = DateTime.from_iso8601(row["r.timestamp"])
          dt
        end)
        |> Enum.map(& &1["r.new_status"])

      assert sorted == ["proposed", "under_review", "certified"]

      # previous_status on each record reflects the phase before it.
      by_status = Map.new(rows, &{&1["r.new_status"], &1})
      assert by_status["proposed"]["r.previous_status"] == ""
      assert by_status["under_review"]["r.previous_status"] == "proposed"
      assert by_status["certified"]["r.previous_status"] == "under_review"
    end
  end

  describe "ASSERT → CERTIFY integration" do
    test "an asserted entity moves from uncertified to certified through the full pipeline" do
      assert_test_entity("case5_assert_to_cert")

      # Freshly asserted: uncertified, baseline reputation, no certified_by.
      assert {:ok, pre} =
               Engine.execute(
                 "RESOLVE entity:test_certify:case5_assert_to_cert",
                 @product_context
               )

      assert hd(pre.data).certified == false
      assert hd(pre.data).reputation == 0.5
      assert pre.quality.certified_by == nil

      for status <- ["proposed", "under_review", "certified"] do
        assert {:ok, _} =
                 certify("entity:test_certify:case5_assert_to_cert", status,
                   authority: "authority:data_governance_board",
                   evidence: "Phase #{status}"
                 )
      end

      assert {:ok, post} =
               Engine.execute(
                 "RESOLVE entity:test_certify:case5_assert_to_cert",
                 @product_context
               )

      [entity] = post.data
      assert entity.certified == true
      assert entity.certified_by == "authority:data_governance_board"
      assert is_binary(entity.certified_at)
      assert entity.reputation >= 0.9

      assert post.quality.certified_by == "authority:data_governance_board"
      assert %DateTime{} = post.quality.certified_at
    end
  end

  describe "scope enforcement on CERTIFY" do
    test "agent in product scope can certify product entities" do
      assert_test_entity("case6_scope_ok")

      assert {:ok, _} =
               certify("entity:test_certify:case6_scope_ok", "proposed",
                 authority: "product_lead"
               )
    end

    test "agent in finance scope cannot certify a product-scoped entity" do
      # Create the entity in the product scope via the product agent so it's
      # only visible to product.
      assert_test_entity("case6_scope_denied", @product_context)

      assert {:error, err} =
               certify(
                 "entity:test_certify:case6_scope_denied",
                 "proposed",
                 [authority: "finance_lead"],
                 @finance_context
               )

      assert err.code in [:scope_access, :entity_not_found]
      # When scope_access, the error should suggest visible scopes.
      if err.code == :scope_access do
        assert is_list(err.suggestions)
        assert Enum.any?(err.suggestions, &(&1 =~ "finance"))
      end
    end
  end

  describe "evidence preservation" do
    test "evidence is stored on each CertificationRecord" do
      assert_test_entity("case7_evidence")

      # Ordered list — phase transitions must advance in sequence, so we
      # cannot iterate a map here (map iteration order is undefined).
      phases = [
        {"proposed", "Drafted from baseline data"},
        {"under_review", "Review board convened 2026-04-01"},
        {"certified", "Signed off by governance board"}
      ]

      for {status, evidence} <- phases do
        assert {:ok, _} =
                 certify("entity:test_certify:case7_evidence", status,
                   authority: "product_lead",
                   evidence: evidence
                 )
      end

      evidence_by_phase = Map.new(phases)

      assert {:ok, rows} =
               GrafeoServer.query(
                 "MATCH (e:Entity {namespace: 'test_certify', name: 'case7_evidence'})" <>
                   "-[:CERTIFICATION_EVENT]->(r:CertificationRecord) " <>
                   "RETURN r.new_status, r.evidence"
               )

      assert length(rows) == 3

      for row <- rows do
        expected = evidence_by_phase[row["r.new_status"]]
        assert row["r.evidence"] == expected
      end
    end
  end
end
