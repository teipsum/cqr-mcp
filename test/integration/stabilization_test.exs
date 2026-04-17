defmodule Cqr.Integration.StabilizationTest do
  @moduledoc """
  Stabilization regression matrix covering every CQR primitive end-to-end
  plus the three bugs fixed in the April 16-17 sprint:

    * Bug #27 — JSON escape in UPDATE response (bfd3352 + 2707043)
    * Bug #28 — UPDATE on certified entity times out
    * Bug #29 — RESOLVE on missing entity hangs

  Each describe block owns a disjoint namespace under `test_stab` so
  parallel deletion in setup is cheap and no test cross-contaminates
  another. Error-path cases are guarded by a 5-second wall-clock
  ceiling so any future re-introduction of the NIF-hang family of bugs
  surfaces as a plain ExUnit failure rather than as a stuck suite.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine
  alias Cqr.Grafeo.Server, as: GrafeoServer

  @product_context %{scope: ["company", "product"], agent_id: "twin:stab_product"}
  @finance_context %{scope: ["company", "finance"], agent_id: "twin:stab_finance"}

  @root_namespace "test_stab"

  @cleanup_namespaces [
    "test_stab",
    "test_stab:bug27",
    "test_stab:bug28",
    "test_stab:bug29",
    "test_stab:resolve",
    "test_stab:discover",
    "test_stab:discover:branch",
    "test_stab:discover:branch:nested",
    "test_stab:assert",
    "test_stab:assert_batch",
    "test_stab:certify",
    "test_stab:signal",
    "test_stab:update",
    "test_stab:trace",
    "test_stab:awareness",
    "test_stab:refresh",
    "test_stab:hypothesize",
    "test_stab:compare",
    "test_stab:anchor"
  ]

  setup do
    cleanup()
    on_exit(&cleanup/0)
    :ok
  end

  defp cleanup do
    for ns <- @cleanup_namespaces do
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'})-[r]-() DELETE r")
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'}) DELETE e")
      GrafeoServer.query("MATCH (r:AssertionRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:CertificationRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:VersionRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:SignalRecord {entity_namespace: '#{ns}'}) DELETE r")
    end

    :ok
  end

  # Execute `fun` with a wall-clock ceiling so a NIF hang surfaces as a
  # flunk instead of a stuck suite. Same contract as the existing
  # nif_hang_regression helper, duplicated here to keep the suite
  # self-contained.
  defp assert_completes_within(timeout_ms, fun) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> value
      nil -> flunk("operation did not complete within #{timeout_ms}ms — probable NIF hang")
    end
  end

  defp seed(ns, name, opts \\ []) do
    description = Keyword.get(opts, :description, "stab fixture #{ns}:#{name}")
    derived = Keyword.get(opts, :derived_from, "entity:product:churn_rate")

    expr =
      ~s(ASSERT entity:#{ns}:#{name} TYPE derived_metric ) <>
        ~s(DESCRIPTION "#{description}" ) <>
        ~s(INTENT "stabilization fixture" ) <>
        ~s(DERIVED_FROM #{derived})

    assert {:ok, _} = Engine.execute(expr, @product_context)
  end

  defp certify_phase(entity_ref, status, authority) do
    auth_clause =
      if String.contains?(authority, ":"),
        do: ~s(AUTHORITY "#{authority}"),
        else: "AUTHORITY #{authority}"

    assert {:ok, _} =
             Engine.execute(
               "CERTIFY #{entity_ref} STATUS #{status} #{auth_clause}",
               @product_context
             )
  end

  defp walk_to_certified(entity_ref, authority \\ "authority:stab_board") do
    for status <- ["proposed", "under_review", "certified"] do
      certify_phase(entity_ref, status, authority)
    end
  end

  # ═════════════════════════════════════════════════════════════════════
  # Bug #27 — JSON escape in UPDATE response
  # ═════════════════════════════════════════════════════════════════════

  describe "Bug #27 — JSON escape in UPDATE response" do
    @bug27_ns "#{@root_namespace}:bug27"

    test "UPDATE with UTF-8 metacharacters in description wire-encodes as ASCII" do
      name = "utf8_basic"
      entity_ref = "entity:#{@bug27_ns}:#{name}"

      seed(@bug27_ns, name, description: "seed description")

      new_desc =
        "Revised — now uses the 7‑day rolling window. " <>
          "Smart quotes: \u201Ccanonical\u201D and \u2018aside\u2019. " <>
          "Accents: café naïve résumé. Ellipsis: …"

      assert {:ok, result} =
               CqrMcp.Tools.call(
                 "cqr_update",
                 %{
                   "entity" => entity_ref,
                   "change_type" => "correction",
                   "description" => new_desc,
                   "evidence" => "JSON escape regression — é ñ ü"
                 },
                 @product_context
               )

      wire_json = Jason.encode!(result, escape: :unicode_safe)

      assert Regex.match?(~r/^[\x00-\x7F]*$/, wire_json),
             "wire payload must be pure ASCII"

      assert {:ok, decoded} = Jason.decode(wire_json)
      row = decoded["data"] |> hd()
      assert row["new_description"] == new_desc
    end

    test "UPDATE with 5KB mixed-class description round-trips byte-for-byte" do
      name = "utf8_large"
      entity_ref = "entity:#{@bug27_ns}:#{name}"

      big = mixed_class_payload(5_200)
      assert byte_size(big) >= 5_000

      seed(@bug27_ns, name)

      assert {:ok, result} =
               CqrMcp.Tools.call(
                 "cqr_update",
                 %{
                   "entity" => entity_ref,
                   "change_type" => "correction",
                   "description" => big,
                   "evidence" => "Large-payload round-trip"
                 },
                 @product_context
               )

      wire_json = Jason.encode!(result, escape: :unicode_safe)
      assert Regex.match?(~r/^[\x00-\x7F]*$/, wire_json)

      assert {:ok, resolved} = Engine.execute("RESOLVE #{entity_ref}", @product_context)
      assert [%{description: description}] = resolved.data
      assert description == big
      assert byte_size(description) == byte_size(big)
    end

    test "UPDATE response survives the full MCP stdio envelope" do
      name = "envelope"
      entity_ref = "entity:#{@bug27_ns}:#{name}"

      seed(@bug27_ns, name)

      new_desc = "Envelope check — é ñ ü … \u201Cquoted\u201D"

      assert {:ok, result} =
               CqrMcp.Tools.call(
                 "cqr_update",
                 %{
                   "entity" => entity_ref,
                   "change_type" => "correction",
                   "description" => new_desc,
                   "evidence" => "envelope"
                 },
                 @product_context
               )

      inner_text = Jason.encode!(result, pretty: true)

      envelope = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{"content" => [%{"type" => "text", "text" => inner_text}]}
      }

      wire = Jason.encode!(envelope, escape: :unicode_safe)
      assert Regex.match?(~r/^[\x00-\x7F]*$/, wire)

      {:ok, decoded} = Jason.decode(wire)
      text = decoded["result"]["content"] |> hd() |> Map.fetch!("text")
      {:ok, inner} = Jason.decode(text)
      assert inner["data"] |> hd() |> Map.fetch!("new_description") == new_desc
    end
  end

  # ═════════════════════════════════════════════════════════════════════
  # Bug #28 — UPDATE on certified entity times out
  # ═════════════════════════════════════════════════════════════════════

  describe "Bug #28 — UPDATE on certified entity" do
    @bug28_ns "#{@root_namespace}:bug28"

    test "correction on certified entity applies and preserves certification" do
      name = "cert_correction_large"
      entity_ref = "entity:#{@bug28_ns}:#{name}"

      seed(@bug28_ns, name, description: "seed before certification")
      walk_to_certified(entity_ref)

      big = mixed_class_payload(5_200)

      assert_completes_within(30_000, fn ->
        assert {:ok, r} =
                 Engine.execute(
                   ~s(UPDATE #{entity_ref} CHANGE_TYPE correction ) <>
                     ~s(DESCRIPTION "#{big}" ) <>
                     ~s(EVIDENCE "Correction on certified — é ñ ü"),
                   @product_context
                 )

        assert hd(r.data).status == "applied"
      end)

      assert {:ok, resolved} = Engine.execute("RESOLVE #{entity_ref}", @product_context)
      row = hd(resolved.data)
      assert row.description == big
      assert row.certified == true
      assert row.certification_status == "certified"
    end

    test "redefinition on certified entity transitions to contested (pending review)" do
      name = "cert_redef_large"
      entity_ref = "entity:#{@bug28_ns}:#{name}"

      seed(@bug28_ns, name, description: "seed before redefinition")
      walk_to_certified(entity_ref)

      big = mixed_class_payload(5_200)

      assert_completes_within(30_000, fn ->
        assert {:ok, r} =
                 Engine.execute(
                   ~s(UPDATE #{entity_ref} CHANGE_TYPE redefinition ) <>
                     ~s(DESCRIPTION "#{big}" ) <>
                     ~s(EVIDENCE "Redefining — é ñ ü"),
                   @product_context
                 )

        assert hd(r.data).status == "pending_review"
      end)

      assert {:ok, resolved} = Engine.execute("RESOLVE #{entity_ref}", @product_context)
      row = hd(resolved.data)
      assert row.description == "seed before redefinition"
      assert row.certification_status == "contested"

      # Server must still be responsive after the pending-review write —
      # a wedged NIF would queue subsequent RESOLVEs behind the stuck
      # dirty-scheduler thread.
      assert_completes_within(5_000, fn ->
        assert {:ok, _} =
                 Engine.execute(
                   "RESOLVE entity:product:churn_rate",
                   @product_context
                 )
      end)
    end
  end

  # ═════════════════════════════════════════════════════════════════════
  # Bug #29 — RESOLVE on missing entity hangs
  # ═════════════════════════════════════════════════════════════════════

  describe "Bug #29 — RESOLVE on missing entity" do
    @bug29_ns "#{@root_namespace}:bug29"

    test "RESOLVE on entity:nonexistent:test returns entity_not_found within 1 second" do
      assert_completes_within(1_000, fn ->
        assert {:error, err} =
                 Engine.execute(
                   "RESOLVE entity:nonexistent_stab:never_asserted",
                   @product_context
                 )

        assert err.code == :entity_not_found
      end)
    end

    test "RESOLVE on deep hierarchical missing address returns error" do
      # 6-level deep path — every ancestor is also absent, so the walk
      # terminates at the first missing container.
      assert_completes_within(1_000, fn ->
        assert {:error, err} =
                 Engine.execute(
                   "RESOLVE entity:#{@bug29_ns}:a:b:c:d:e:f",
                   @product_context
                 )

        assert err.code == :entity_not_found
      end)
    end

    test "10 sequential RESOLVE calls on missing entities — no NIF hang accumulation" do
      assert_completes_within(5_000, fn ->
        for i <- 1..10 do
          assert {:error, err} =
                   Engine.execute(
                     "RESOLVE entity:#{@bug29_ns}:missing_#{i}",
                     @product_context
                   )

          assert err.code == :entity_not_found
        end
      end)
    end

    test "after missing RESOLVE, a valid RESOLVE still works (server not wedged)" do
      assert {:error, _} =
               Engine.execute(
                 "RESOLVE entity:#{@bug29_ns}:still_missing",
                 @product_context
               )

      assert_completes_within(2_000, fn ->
        assert {:ok, result} =
                 Engine.execute(
                   "RESOLVE entity:product:churn_rate",
                   @product_context
                 )

        assert [%{name: "churn_rate"}] = result.data
      end)
    end
  end

  # ═════════════════════════════════════════════════════════════════════
  # Primitive regression matrix — happy + error paths for every primitive
  # ═════════════════════════════════════════════════════════════════════

  describe "RESOLVE" do
    @resolve_ns "#{@root_namespace}:resolve"

    test "happy: resolve existing entity returns all expected fields" do
      name = "happy"
      seed(@resolve_ns, name, description: "resolve happy path")

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("RESOLVE entity:#{@resolve_ns}:#{name}", @product_context)

      assert row.namespace == @resolve_ns
      assert row.name == name
      assert row.type == "derived_metric"
      assert row.description == "resolve happy path"
      assert row.certified == false
      assert row.owner == "twin:stab_product"
    end

    test "error: resolve missing entity returns entity_not_found within 5s" do
      assert_completes_within(5_000, fn ->
        assert {:error, %Cqr.Error{code: :entity_not_found}} =
                 Engine.execute(
                   "RESOLVE entity:#{@resolve_ns}:absent",
                   @product_context
                 )
      end)
    end
  end

  describe "DISCOVER" do
    @discover_ns "#{@root_namespace}:discover"

    test "happy anchor mode: neighborhood of an existing entity" do
      seed(@discover_ns, "anchor_target")

      assert {:ok, %Cqr.Result{data: rows}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:#{@discover_ns}:anchor_target",
                 @product_context
               )

      assert is_list(rows)
    end

    test "happy prefix mode: descendants surface via CONTAINS" do
      # Hierarchical ASSERT auto-creates the "branch" container.
      assert {:ok, _} =
               Engine.execute(
                 ~s(ASSERT entity:#{@discover_ns}:branch:leaf1 TYPE derived_metric ) <>
                   ~s(DESCRIPTION "prefix leaf 1" ) <>
                   ~s(INTENT "discover prefix fixture" ) <>
                   ~s(DERIVED_FROM entity:product:churn_rate),
                 @product_context
               )

      assert {:ok, _} =
               Engine.execute(
                 ~s(ASSERT entity:#{@discover_ns}:branch:leaf2 TYPE derived_metric ) <>
                   ~s(DESCRIPTION "prefix leaf 2" ) <>
                   ~s(INTENT "discover prefix fixture" ) <>
                   ~s(DERIVED_FROM entity:product:churn_rate),
                 @product_context
               )

      assert {:ok, %Cqr.Result{data: rows}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:#{@discover_ns}:branch:*",
                 @product_context
               )

      names = rows |> Enum.map(& &1.name) |> Enum.sort()
      assert "leaf1" in names
      assert "leaf2" in names
    end

    test "happy free-text mode: discover by unique keyword" do
      unique = "Stabneedlekeyword#{:erlang.unique_integer([:positive])}"

      assert {:ok, _} =
               Engine.execute(
                 ~s(ASSERT entity:#{@discover_ns}:freetext TYPE derived_metric ) <>
                   ~s(DESCRIPTION "#{unique} and surrounding context" ) <>
                   ~s(INTENT "discover free-text fixture" ) <>
                   ~s(DERIVED_FROM entity:product:churn_rate),
                 @product_context
               )

      assert {:ok, %Cqr.Result{data: rows}} =
               Engine.execute(
                 ~s(DISCOVER concepts RELATED TO "#{unique}"),
                 @product_context
               )

      assert Enum.any?(rows, fn row ->
               row[:entity] == {@discover_ns, "freetext"}
             end)
    end

    test "error: discover with empty topic is a parse error" do
      assert_completes_within(5_000, fn ->
        assert {:error, %Cqr.Error{code: :parse_error}} =
                 Engine.execute("DISCOVER concepts RELATED TO ", @product_context)
      end)
    end
  end

  describe "ASSERT" do
    @assert_ns "#{@root_namespace}:assert"

    test "happy: assert new entity with all required fields" do
      name = "happy"

      expr =
        ~s(ASSERT entity:#{@assert_ns}:#{name} TYPE derived_metric ) <>
          ~s(DESCRIPTION "assert happy path" ) <>
          ~s(INTENT "testing ASSERT happy") <>
          ~s( DERIVED_FROM entity:product:churn_rate)

      assert {:ok, %Cqr.Result{data: [row]}} = Engine.execute(expr, @product_context)
      assert row.name == name
      assert row.certified == false
      assert row.reputation == 0.5
    end

    test "error: missing description is a parse error" do
      expr =
        ~s(ASSERT entity:#{@assert_ns}:no_desc TYPE derived_metric ) <>
          ~s(INTENT "no description provided" ) <>
          ~s(DERIVED_FROM entity:product:churn_rate)

      assert_completes_within(5_000, fn ->
        assert {:error, %Cqr.Error{code: code}} = Engine.execute(expr, @product_context)
        assert code in [:parse_error, :missing_required_field]
      end)
    end

    test "error: asserting an existing entity returns entity_exists" do
      name = "dup"
      seed(@assert_ns, name)

      dup_expr =
        ~s(ASSERT entity:#{@assert_ns}:#{name} TYPE derived_metric ) <>
          ~s(DESCRIPTION "stab fixture #{@assert_ns}:#{name}" ) <>
          ~s(INTENT "stabilization fixture" ) <>
          ~s(DERIVED_FROM entity:product:churn_rate)

      assert_completes_within(5_000, fn ->
        assert {:error, %Cqr.Error{code: :entity_exists}} =
                 Engine.execute(dup_expr, @product_context)
      end)
    end

    test "utf8: assert with 5KB description containing em dashes, accents, and CJK" do
      name = "utf8_big"
      big = mixed_class_payload(5_200)
      assert byte_size(big) >= 5_000

      assert {:ok, _} =
               CqrMcp.Tools.call(
                 "cqr_assert",
                 %{
                   "entity" => "entity:#{@assert_ns}:#{name}",
                   "type" => "derived_metric",
                   "description" => big,
                   "intent" => "UTF-8 stress — é ñ 日",
                   "derived_from" => "entity:product:churn_rate"
                 },
                 @product_context
               )

      assert {:ok, resolved} =
               Engine.execute("RESOLVE entity:#{@assert_ns}:#{name}", @product_context)

      assert [%{description: ^big}] = resolved.data
    end
  end

  describe "ASSERT_BATCH" do
    @batch_ns "#{@root_namespace}:assert_batch"

    defp batch_entity(ns, name, overrides \\ %{}) do
      Map.merge(
        %{
          "entity" => "entity:#{ns}:#{name}",
          "type" => "derived_metric",
          "description" => "batch fixture #{ns}:#{name}",
          "intent" => "batch test",
          "derived_from" => "entity:product:churn_rate"
        },
        overrides
      )
    end

    test "happy: batch of 3 entities all succeed" do
      args = %{
        "entities" => [
          batch_entity(@batch_ns, "b_one"),
          batch_entity(@batch_ns, "b_two"),
          batch_entity(@batch_ns, "b_three")
        ]
      }

      assert {:ok,
              %{
                "total" => 3,
                "created" => 3,
                "skipped" => 0,
                "failed" => 0
              }} = CqrMcp.Tools.call("cqr_assert_batch", args, @product_context)
    end

    test "partial: existing entity is skipped, fresh ones succeed" do
      seed(@batch_ns, "existing")

      args = %{
        "entities" => [
          batch_entity(@batch_ns, "existing"),
          batch_entity(@batch_ns, "fresh_one"),
          batch_entity(@batch_ns, "fresh_two")
        ]
      }

      assert {:ok, %{"total" => 3, "created" => 2, "skipped" => 1, "failed" => 0}} =
               CqrMcp.Tools.call("cqr_assert_batch", args, @product_context)
    end

    test "error: batch with invalid entity (missing type) records a failure" do
      args = %{
        "entities" => [
          batch_entity(@batch_ns, "good")
          |> Map.delete("type"),
          batch_entity(@batch_ns, "also_good")
        ]
      }

      assert_completes_within(5_000, fn ->
        assert {:ok, %{"total" => 2, "created" => 1, "failed" => 1, "results" => results}} =
                 CqrMcp.Tools.call("cqr_assert_batch", args, @product_context)

        assert Enum.any?(results, fn r -> r["status"] == "failed" end)
      end)
    end
  end

  describe "CERTIFY" do
    @certify_ns "#{@root_namespace}:certify"

    test "happy: full lifecycle nil -> proposed -> under_review -> certified" do
      name = "full"
      entity_ref = "entity:#{@certify_ns}:#{name}"
      seed(@certify_ns, name)

      for status <- ["proposed", "under_review", "certified"] do
        assert {:ok, _} =
                 Engine.execute(
                   ~s(CERTIFY #{entity_ref} STATUS #{status} AUTHORITY "authority:stab_board"),
                   @product_context
                 )
      end

      assert {:ok, resolved} = Engine.execute("RESOLVE #{entity_ref}", @product_context)
      [row] = resolved.data
      assert row.certified == true
      assert row.certification_status == "certified"
      assert row.certified_by == "authority:stab_board"
    end

    test "error: invalid transition (nil -> certified directly)" do
      name = "skip"
      entity_ref = "entity:#{@certify_ns}:#{name}"
      seed(@certify_ns, name)

      assert_completes_within(5_000, fn ->
        assert {:error, %Cqr.Error{code: :invalid_transition}} =
                 Engine.execute(
                   "CERTIFY #{entity_ref} STATUS certified AUTHORITY stab_lead",
                   @product_context
                 )
      end)
    end

    test "error: certify non-existent entity returns entity_not_found" do
      assert_completes_within(5_000, fn ->
        assert {:error, %Cqr.Error{code: :entity_not_found}} =
                 Engine.execute(
                   "CERTIFY entity:#{@certify_ns}:ghost STATUS proposed AUTHORITY stab_lead",
                   @product_context
                 )
      end)
    end
  end

  describe "SIGNAL" do
    @signal_ns "#{@root_namespace}:signal"

    test "happy: signal existing entity with score 0.9 and reputation is updated" do
      name = "happy"
      entity_ref = "entity:#{@signal_ns}:#{name}"
      seed(@signal_ns, name)

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 ~s(SIGNAL reputation ON #{entity_ref} SCORE 0.9 EVIDENCE "quality bump"),
                 @product_context
               )

      assert row.new_reputation == 0.9

      assert {:ok, %Cqr.Result{data: [entity]}} =
               Engine.execute("RESOLVE #{entity_ref}", @product_context)

      assert entity.reputation == 0.9
    end

    test "error: signal non-existent entity returns entity_not_found" do
      assert_completes_within(5_000, fn ->
        assert {:error, %Cqr.Error{code: :entity_not_found}} =
                 Engine.execute(
                   ~s(SIGNAL reputation ON entity:#{@signal_ns}:ghost SCORE 0.5 ) <>
                     ~s(EVIDENCE "should fail"),
                   @product_context
                 )
      end)
    end
  end

  describe "UPDATE" do
    @update_ns "#{@root_namespace}:update"

    test "happy: update uncertified entity with correction" do
      name = "uncert"
      entity_ref = "entity:#{@update_ns}:#{name}"
      seed(@update_ns, name)

      assert {:ok, r} =
               Engine.execute(
                 ~s(UPDATE #{entity_ref} CHANGE_TYPE correction ) <>
                   ~s(DESCRIPTION "revised uncert" EVIDENCE "typo fix"),
                 @product_context
               )

      assert hd(r.data).status == "applied"

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("RESOLVE #{entity_ref}", @product_context)

      assert row.description == "revised uncert"
    end

    test "happy: update certified entity with correction preserves certification" do
      name = "cert_corr"
      entity_ref = "entity:#{@update_ns}:#{name}"
      seed(@update_ns, name)
      walk_to_certified(entity_ref)

      assert {:ok, r} =
               Engine.execute(
                 ~s(UPDATE #{entity_ref} CHANGE_TYPE correction ) <>
                   ~s(DESCRIPTION "corrected text" EVIDENCE "typo"),
                 @product_context
               )

      assert hd(r.data).status == "applied"

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("RESOLVE #{entity_ref}", @product_context)

      assert row.description == "corrected text"
      assert row.certified == true
      assert row.certification_status == "certified"
    end

    test "governance: redefinition on certified entity transitions to contested" do
      name = "cert_redef"
      entity_ref = "entity:#{@update_ns}:#{name}"
      seed(@update_ns, name, description: "original meaning")
      walk_to_certified(entity_ref)

      assert {:ok, r} =
               Engine.execute(
                 ~s(UPDATE #{entity_ref} CHANGE_TYPE redefinition ) <>
                   ~s(DESCRIPTION "new meaning" EVIDENCE "semantic change"),
                 @product_context
               )

      assert hd(r.data).status == "pending_review"

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("RESOLVE #{entity_ref}", @product_context)

      assert row.description == "original meaning"
      assert row.certification_status == "contested"
    end

    test "error: update non-existent entity returns entity_not_found" do
      assert_completes_within(5_000, fn ->
        assert {:error, %Cqr.Error{code: :entity_not_found}} =
                 Engine.execute(
                   ~s(UPDATE entity:#{@update_ns}:ghost CHANGE_TYPE correction ) <>
                     ~s(DESCRIPTION "will fail"),
                   @product_context
                 )
      end)
    end

    test "error: update contested entity is blocked" do
      name = "blocked"
      entity_ref = "entity:#{@update_ns}:#{name}"
      seed(@update_ns, name)
      walk_to_certified(entity_ref)
      certify_phase(entity_ref, "contested", "challenger")

      assert_completes_within(5_000, fn ->
        assert {:error, %Cqr.Error{code: :invalid_transition} = err} =
                 Engine.execute(
                   ~s(UPDATE #{entity_ref} CHANGE_TYPE correction ) <>
                     ~s(DESCRIPTION "blocked" EVIDENCE "should fail"),
                   @product_context
                 )

        assert err.message =~ "contest"
      end)
    end

    test "utf8: update with large UTF-8 description round-trips intact" do
      name = "utf8_big"
      entity_ref = "entity:#{@update_ns}:#{name}"
      seed(@update_ns, name)

      big = mixed_class_payload(5_200)

      assert {:ok, _} =
               Engine.execute(
                 ~s(UPDATE #{entity_ref} CHANGE_TYPE correction ) <>
                   ~s(DESCRIPTION "#{big}" EVIDENCE "utf8 stress"),
                 @product_context
               )

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("RESOLVE #{entity_ref}", @product_context)

      assert row.description == big
    end
  end

  describe "TRACE" do
    @trace_ns "#{@root_namespace}:trace"

    test "happy: trace entity with assertion + certification history" do
      name = "happy"
      entity_ref = "entity:#{@trace_ns}:#{name}"
      seed(@trace_ns, name)
      walk_to_certified(entity_ref)

      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute("TRACE #{entity_ref}", @product_context)

      assert row.assertion.asserted_by == "twin:stab_product"
      assert length(row.certification_history) == 3

      statuses = Enum.map(row.certification_history, & &1.to_status) |> Enum.sort()
      assert statuses == ["certified", "proposed", "under_review"]
    end

    test "error: trace non-existent entity returns entity_not_found" do
      assert_completes_within(5_000, fn ->
        assert {:error, %Cqr.Error{code: :entity_not_found}} =
                 Engine.execute(
                   "TRACE entity:#{@trace_ns}:ghost",
                   @product_context
                 )
      end)
    end
  end

  describe "AWARENESS" do
    @awareness_ns "#{@root_namespace}:awareness"

    test "happy: awareness with default params returns activity" do
      seed(@awareness_ns, "activity_marker")

      assert {:ok, %Cqr.Result{} = result} =
               Engine.execute("AWARENESS active_agents", @product_context)

      assert is_list(result.data)

      # The asserting agent for this test must show up in the window.
      assert Enum.any?(result.data, fn row ->
               row.agent_id == "twin:stab_product"
             end)
    end

    test "happy: awareness with 24h time_window" do
      seed(@awareness_ns, "recent_marker")

      assert {:ok, %Cqr.Result{} = result} =
               Engine.execute(
                 "AWARENESS active_agents OVER last 24h",
                 @product_context
               )

      assert Enum.any?(result.data, fn row ->
               row.agent_id == "twin:stab_product" and
                 "entity:#{@awareness_ns}:recent_marker" in row.entities_touched
             end)
    end
  end

  describe "REFRESH" do
    test "happy: refresh check returns stale items list" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "REFRESH CHECK active_context WHERE age > 1h RETURN stale_items",
                 @product_context
               )

      assert is_list(data)

      # All returned items must live in a product-visible namespace.
      assert Enum.all?(data, fn row ->
               String.starts_with?(row.entity, "entity:product:") or
                 String.starts_with?(row.entity, "entity:test_stab:")
             end)
    end
  end

  describe "HYPOTHESIZE" do
    test "happy: hypothesize reputation change on existing entity" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "HYPOTHESIZE entity:product:churn_rate CHANGE reputation TO 0.20",
                 @product_context
               )

      assert row.entity == "entity:product:churn_rate"
      assert row.hypothetical_change.field == :reputation
      assert row.hypothetical_change.value == 0.20
    end

    test "error: hypothesize on non-existent entity returns entity_not_found" do
      assert_completes_within(5_000, fn ->
        assert {:error, %Cqr.Error{code: :entity_not_found}} =
                 Engine.execute(
                   "HYPOTHESIZE entity:#{@root_namespace}:hypothesize:ghost " <>
                     "CHANGE reputation TO 0.10",
                   @product_context
                 )
      end)
    end
  end

  describe "COMPARE" do
    test "happy: compare two existing entities" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "COMPARE entity:product:churn_rate, entity:product:nps",
                 @product_context
               )

      assert "entity:product:churn_rate" in row.entities
      assert "entity:product:nps" in row.entities
      assert map_size(row.per_entity) == 2
    end

    test "error: compare with non-existent entity returns entity_not_found" do
      assert_completes_within(5_000, fn ->
        assert {:error, %Cqr.Error{code: :entity_not_found}} =
                 Engine.execute(
                   "COMPARE entity:product:churn_rate, entity:product:ghost_#{@root_namespace}",
                   @product_context
                 )
      end)
    end
  end

  describe "ANCHOR" do
    test "happy: anchor chain of existing entities" do
      assert {:ok, %Cqr.Result{data: [row]}} =
               Engine.execute(
                 "ANCHOR entity:product:churn_rate, entity:product:nps",
                 @product_context
               )

      assert row.chain == ["entity:product:churn_rate", "entity:product:nps"]
      assert row.missing == []
      assert is_float(row.weakest_link_confidence)
    end

    test "error: anchor chain with missing entity flags it as missing" do
      # ANCHOR does not error on missing links — it flags them in the
      # `missing` field so the agent can decide how much trust to place
      # in the chain. Verify that contract remains intact.
      assert_completes_within(5_000, fn ->
        assert {:ok, %Cqr.Result{data: [row]}} =
                 Engine.execute(
                   "ANCHOR entity:product:churn_rate, entity:product:ghost_#{@root_namespace}",
                   @product_context
                 )

        assert "entity:product:ghost_#{@root_namespace}" in row.missing
        assert row.weakest_link_confidence == 0.0
      end)
    end

    test "error: anchor against an out-of-scope entity surfaces it as missing" do
      # A finance agent asking about a product entity gets the entity
      # reported as missing (containment-aware visibility). Proves
      # scope-access collapses to missing rather than surfacing a raw
      # scope_access error in the ANCHOR path.
      assert_completes_within(5_000, fn ->
        assert {:ok, %Cqr.Result{data: [row]}} =
                 Engine.execute(
                   "ANCHOR entity:product:churn_rate",
                   @finance_context
                 )

        assert "entity:product:churn_rate" in row.missing
      end)
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Fixtures
  # ─────────────────────────────────────────────────────────────────────

  # Build a payload of at least `target_bytes` bytes covering every
  # character class the CQR write path must survive end-to-end:
  # ASCII metacharacters, Latin-1, CJK, emoji, math symbols. The CQR
  # parser uses `"` as the string delimiter so we deliberately avoid
  # embedded double quotes here — the bug classes this file guards
  # against live downstream of the parser. The trailing non-whitespace
  # marker keeps `CqrMcp.Tools.sanitize_quoted/1` (which calls
  # `String.trim/1`) from silently shrinking the stored value.
  defp mixed_class_payload(target_bytes) do
    chunk =
      "ASCII meta: $~()/+:*#@%|[]{}<>;!?&=^ — " <>
        "Latin-1: café naïve résumé — " <>
        "CJK: 日本語 中文 한국어 — " <>
        "emoji: 🚀💥✨🎯 — " <>
        "math: ∑∫∂∆ ≠ ≤ ≥ ∞ π — " <>
        "path: C:\\Users\\alice\\notes.txt, it's 'quoted'\n\ttab and CRLF\r\n"

    body =
      [chunk]
      |> Stream.cycle()
      |> Enum.reduce_while("", fn part, acc ->
        next = acc <> part
        if byte_size(next) >= target_bytes, do: {:halt, next}, else: {:cont, next}
      end)

    String.trim_trailing(body) <> "|END"
  end
end
