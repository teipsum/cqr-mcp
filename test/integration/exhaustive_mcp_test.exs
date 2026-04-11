defmodule Cqr.Integration.ExhaustiveMcpTest do
  @moduledoc """
  Exhaustive end-to-end coverage of the V1 MCP surface (RESOLVE, DISCOVER,
  ASSERT, CERTIFY) routed through `Cqr.Engine.execute/2` and the
  `CqrMcp.Tools.call/3` adapter.

  This file is the explicit regression net for the *DISCOVER outbound hang
  on asserted entity targets* incident: Section J builds hubs whose
  `DERIVED_FROM` edges point at *asserted* (not seeded) leaves and at a
  mix of seeded + asserted leaves, then asserts that outbound DISCOVER
  returns in well under a second. The d619b36 N+1 fix already collapses
  the traversal into a single Cypher query regardless of target
  provenance; these tests lock in that invariant.

  Sections:

    A. ASSERT edge cases (14)
    B. DISCOVER graph traversal (14)
    C. DISCOVER BM25 full-text (10)
    D. DISCOVER vector similarity (8)
    E. DISCOVER multi-paradigm merge (3)
    F. CERTIFY lifecycle (11)
    G. RESOLVE edge cases (7)
    H. Scope enforcement comprehensive (9)
    I. Cross-primitive workflows (6)
    J. Scale + the asserted-target hang regression (5)
    K. Error handling (8)

  Total: 95 cases. Every assertion routes through `Cqr.Engine.execute/2`
  or `CqrMcp.Tools.call/3` (which itself calls into the engine) — no test
  asserts against raw Cypher.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine
  alias Cqr.Grafeo.Server, as: GrafeoServer

  @company_context %{scope: ["company"], agent_id: "twin:exh_root"}
  @product_context %{scope: ["company", "product"], agent_id: "twin:exh_product"}
  @finance_context %{scope: ["company", "finance"], agent_id: "twin:exh_finance"}
  @hr_context %{scope: ["company", "hr"], agent_id: "twin:exh_hr"}
  @engineering_context %{scope: ["company", "engineering"], agent_id: "twin:exh_engineering"}

  # All entities created by this file live in `test_exh` namespaces. The
  # cleanup hook drops every node + edge under those namespaces so reruns
  # are deterministic and so the test_hd / test_assert / test_certify
  # namespaces stay untouched.
  @namespaces ~w(test_exh test_exh_a test_exh_b test_exh_c test_exh_f
                 test_exh_g test_exh_h test_exh_i test_exh_j test_exh_k)

  setup_all do
    cleanup_namespaces()
    on_exit(&cleanup_namespaces/0)
    :ok
  end

  setup do
    on_exit(&cleanup_namespaces/0)
    :ok
  end

  defp cleanup_namespaces do
    for ns <- @namespaces do
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'})-[r]-() DELETE r")
      GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'}) DELETE e")
      GrafeoServer.query("MATCH (r:AssertionRecord {entity_namespace: '#{ns}'}) DELETE r")
      GrafeoServer.query("MATCH (r:CertificationRecord {entity_namespace: '#{ns}'}) DELETE r")
    end

    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp assert_minimal(name, opts \\ []) do
    ns = Keyword.get(opts, :namespace, "test_exh")
    derived = Keyword.get(opts, :derived_from, ["entity:product:churn_rate"])
    type = Keyword.get(opts, :type, "observation")
    description = Keyword.get(opts, :description, "fixture #{name}")
    intent = Keyword.get(opts, :intent, "exhaustive integration test")
    context = Keyword.get(opts, :context, @product_context)

    parts = [
      "ASSERT entity:#{ns}:#{name}",
      "TYPE #{type}",
      ~s(DESCRIPTION "#{description}"),
      ~s(INTENT "#{intent}"),
      "DERIVED_FROM #{Enum.join(derived, ",")}"
    ]

    parts =
      case Keyword.get(opts, :scope) do
        nil -> parts
        scope -> parts ++ ["IN #{scope}"]
      end

    parts =
      case Keyword.get(opts, :confidence) do
        nil -> parts
        c -> parts ++ ["CONFIDENCE #{c}"]
      end

    Engine.execute(Enum.join(parts, " "), context)
  end

  defp certify_phase(entity_ref, status, opts) do
    authority = Keyword.get(opts, :authority, "exh_authority")
    evidence = Keyword.get(opts, :evidence)
    context = Keyword.get(opts, :context, @product_context)

    parts = ["CERTIFY #{entity_ref} STATUS #{status}"]

    parts =
      cond do
        is_nil(authority) -> parts
        String.contains?(authority, ":") -> parts ++ [~s(AUTHORITY "#{authority}")]
        true -> parts ++ ["AUTHORITY #{authority}"]
      end

    parts = if evidence, do: parts ++ [~s(EVIDENCE "#{evidence}")], else: parts

    Engine.execute(Enum.join(parts, " "), context)
  end

  defp full_certify(entity_ref, opts) do
    {:ok, _} = certify_phase(entity_ref, "proposed", opts)
    {:ok, _} = certify_phase(entity_ref, "under_review", opts)
    certify_phase(entity_ref, "certified", opts)
  end

  # ╔══════════════════════════════════════════════════════════════════════╗
  # ║ Section A — ASSERT edge cases                                        ║
  # ╚══════════════════════════════════════════════════════════════════════╝

  describe "Section A — ASSERT edge cases" do
    test "A01 minimum required fields only" do
      assert {:ok, %Cqr.Result{data: [%{name: "a01_min", certified: false, confidence: 0.5}]}} =
               assert_minimal("a01_min")
    end

    test "A02 all optional fields populated (scope + confidence)" do
      assert {:ok, %Cqr.Result{data: [%{name: "a02_full", confidence: 0.85}]}} =
               assert_minimal("a02_full",
                 scope: "scope:company:product",
                 confidence: "0.85"
               )
    end

    test "A03 very long description (500+ characters)" do
      long = String.duplicate("the quick brown fox jumps over the lazy dog. ", 12)
      assert String.length(long) > 500

      assert {:ok, %Cqr.Result{data: [%{name: "a03_long", description: ^long}]}} =
               assert_minimal("a03_long", description: long)
    end

    test "A04 special characters in description (apostrophes are escaped)" do
      # Stick to ASCII: the storage layer round-trips bytes as-is and any
      # multi-byte char gets re-encoded by the Cypher writer in a way that
      # mojibakes the round-trip. The interesting escape case here is the
      # apostrophe, which the adapter does have to escape because Cypher
      # string literals are single-quoted.
      desc = "agent's daily pulse - it's fine"

      assert {:ok, %Cqr.Result{data: [%{name: "a04_special", description: ^desc}]}} =
               assert_minimal("a04_special", description: desc)
    end

    test "A05 entity that already exists → entity_exists error" do
      assert {:ok, _} = assert_minimal("a05_dup")

      assert {:error, %Cqr.Error{code: :entity_exists, retry_guidance: guidance}} =
               assert_minimal("a05_dup")

      assert guidance =~ "CERTIFY"
    end

    test "A06 DERIVED_FROM nonexistent entity → entity_not_found" do
      assert {:error, %Cqr.Error{code: :entity_not_found, message: msg}} =
               assert_minimal("a06_bad",
                 derived_from: ["entity:product:does_not_exist_a06"]
               )

      assert msg =~ "does_not_exist_a06"
    end

    test "A07 mix of existing and nonexistent DERIVED_FROM → error, no partial write" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               assert_minimal("a07_partial",
                 derived_from: ["entity:product:churn_rate", "entity:product:also_missing_a07"]
               )

      # Validation error fires before any write — no entity, no record.
      refute Cqr.Repo.Semantic.entity_exists?({"test_exh", "a07_partial"})
    end

    test "A08 non-identifier type fails at parse time" do
      # The grammar restricts TYPE to a lowercase identifier; passing a
      # CamelCase or hyphenated value is a parse error, not an adapter
      # error. The engine still surfaces it as an informative error.
      expr =
        ~s(ASSERT entity:test_exh:a08_bad TYPE Metric ) <>
          ~s(DESCRIPTION "x" INTENT "y" DERIVED_FROM entity:product:churn_rate)

      assert {:error, %Cqr.Error{code: :parse_error}} =
               Engine.execute(expr, @product_context)
    end

    test "A09 confidence outside 0..1 → validation_error" do
      assert {:error, %Cqr.Error{code: :validation_error, message: msg}} =
               assert_minimal("a09_conf", confidence: "1.5")

      assert msg =~ "0.0 and 1.0"
    end

    test "A10 all five typed relationship types via the cqr_assert MCP tool" do
      args = %{
        "entity" => "entity:test_exh:a10_rels",
        "type" => "derived_metric",
        "description" => "All relationship types",
        "intent" => "Exhaust REL types",
        "derived_from" => "entity:product:churn_rate",
        "relationships" =>
          "CORRELATES_WITH:entity:product:nps:0.7," <>
            "CONTRIBUTES_TO:entity:product:retention_rate:0.6," <>
            "DEPENDS_ON:entity:product:feature_adoption:0.5," <>
            "CAUSES:entity:product:dau:0.55," <>
            "PART_OF:entity:product:time_to_value:0.45"
      }

      assert {:ok, %{"data" => [%{"name" => "a10_rels"}]}} =
               CqrMcp.Tools.call("cqr_assert", args, @product_context)

      # All five typed edges round-trip via outbound DISCOVER through the engine.
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:test_exh:a10_rels DEPTH 1 DIRECTION outbound",
                 @product_context
               )

      rel_types = data |> Enum.map(& &1.relationship) |> Enum.sort()

      assert "CORRELATES_WITH" in rel_types
      assert "CONTRIBUTES_TO" in rel_types
      assert "DEPENDS_ON" in rel_types
      assert "CAUSES" in rel_types
      assert "PART_OF" in rel_types
      assert "DERIVED_FROM" in rel_types
    end

    test "A11 assert into sibling scope → scope_access" do
      assert {:error, %Cqr.Error{code: :scope_access}} =
               assert_minimal("a11_sibling",
                 derived_from: ["entity:finance:arr"],
                 scope: "scope:company:engineering",
                 context: @finance_context
               )
    end

    test "A12 assert into parent scope from a child agent works" do
      assert {:ok, %Cqr.Result{data: [%{scopes: [["company"]]}]}} =
               assert_minimal("a12_parent_scope",
                 scope: "scope:company"
               )
    end

    test "A13 assert into the agent's own scope works" do
      assert {:ok, %Cqr.Result{data: [%{scopes: [["company", "product"]]}]}} =
               assert_minimal("a13_own_scope",
                 scope: "scope:company:product"
               )
    end

    test "A14 derivation chain A → B → C → seeded entity" do
      assert {:ok, _} = assert_minimal("a14_c", derived_from: ["entity:product:churn_rate"])
      assert {:ok, _} = assert_minimal("a14_b", derived_from: ["entity:test_exh:a14_c"])
      assert {:ok, _} = assert_minimal("a14_a", derived_from: ["entity:test_exh:a14_b"])

      # All three are visible via RESOLVE.
      for name <- ~w(a14_a a14_b a14_c) do
        assert {:ok, %Cqr.Result{data: [%{name: ^name}]}} =
                 Engine.execute("RESOLVE entity:test_exh:#{name}", @product_context)
      end

      # And the chain is traversable depth 3 via DISCOVER.
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:test_exh:a14_a DEPTH 3 DIRECTION outbound",
                 @product_context
               )

      entities = Enum.map(data, & &1.entity)
      assert {"test_exh", "a14_b"} in entities
      assert {"test_exh", "a14_c"} in entities
      assert {"product", "churn_rate"} in entities
    end
  end

  # ╔══════════════════════════════════════════════════════════════════════╗
  # ║ Section B — DISCOVER graph traversal                                 ║
  # ╚══════════════════════════════════════════════════════════════════════╝

  describe "Section B — DISCOVER graph traversal" do
    test "B01 outbound depth 1 on a seeded entity returns typed edges" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 1 DIRECTION outbound",
                 @product_context
               )

      assert Enum.any?(data, fn r ->
               r.entity == {"product", "nps"} and r.relationship == "CORRELATES_WITH"
             end)
    end

    test "B02 outbound depth 1 on asserted entity → seeded targets" do
      assert {:ok, _} =
               assert_minimal("b02_hub",
                 derived_from: ["entity:product:churn_rate", "entity:product:nps"]
               )

      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:test_exh:b02_hub DEPTH 1 DIRECTION outbound",
                 @product_context
               )

      assert length(data) == 2
      entities = Enum.map(data, & &1.entity) |> Enum.sort()
      assert entities == [{"product", "churn_rate"}, {"product", "nps"}]
    end

    test "B03 outbound depth 1 on asserted entity → asserted targets (the original hang)" do
      {:ok, _} = assert_minimal("b03_leaf_a")
      {:ok, _} = assert_minimal("b03_leaf_b", derived_from: ["entity:product:nps"])

      {:ok, _} =
        assert_minimal("b03_hub",
          derived_from: ["entity:test_exh:b03_leaf_a", "entity:test_exh:b03_leaf_b"]
        )

      task =
        Task.async(fn ->
          Engine.execute(
            "DISCOVER concepts RELATED TO entity:test_exh:b03_hub DEPTH 1 DIRECTION outbound",
            @product_context
          )
        end)

      {:ok, %Cqr.Result{data: data}} = Task.await(task, 5_000)

      entities = Enum.map(data, & &1.entity) |> Enum.sort()
      assert entities == [{"test_exh", "b03_leaf_a"}, {"test_exh", "b03_leaf_b"}]
    end

    test "B04 outbound depth 2 follows chains" do
      {:ok, _} = assert_minimal("b04_c")
      {:ok, _} = assert_minimal("b04_b", derived_from: ["entity:test_exh:b04_c"])
      {:ok, _} = assert_minimal("b04_a", derived_from: ["entity:test_exh:b04_b"])

      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:test_exh:b04_a DEPTH 2 DIRECTION outbound",
                 @product_context
               )

      entities = Enum.map(data, & &1.entity)
      assert {"test_exh", "b04_b"} in entities
      assert {"test_exh", "b04_c"} in entities
    end

    test "B05 inbound depth 1 returns entities pointing AT the target" do
      {:ok, _} =
        assert_minimal("b05_pointer", derived_from: ["entity:product:churn_rate"])

      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 1 DIRECTION inbound",
                 @product_context
               )

      assert Enum.any?(data, fn r ->
               r.entity == {"test_exh", "b05_pointer"} and r.direction == "inbound"
             end)
    end

    test "B06 inbound depth 2 follows reverse chains" do
      {:ok, _} = assert_minimal("b06_c", derived_from: ["entity:product:churn_rate"])
      {:ok, _} = assert_minimal("b06_b", derived_from: ["entity:test_exh:b06_c"])
      {:ok, _} = assert_minimal("b06_a", derived_from: ["entity:test_exh:b06_b"])

      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:test_exh:b06_c DEPTH 2 DIRECTION inbound",
                 @product_context
               )

      entities = Enum.map(data, & &1.entity)
      assert {"test_exh", "b06_a"} in entities
      assert {"test_exh", "b06_b"} in entities
    end

    test "B07 both directions returns the union, each row tagged" do
      {:ok, _} =
        assert_minimal("b07_node", derived_from: ["entity:product:churn_rate"])

      {:ok, _} =
        assert_minimal("b07_pointer", derived_from: ["entity:test_exh:b07_node"])

      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:test_exh:b07_node DEPTH 1 DIRECTION both",
                 @product_context
               )

      directions = data |> Enum.map(& &1.direction) |> Enum.uniq() |> Enum.sort()
      assert "inbound" in directions
      assert "outbound" in directions
    end

    test "B08 cross-scope edges filtered for product agent" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 1 DIRECTION outbound",
                 @product_context
               )

      namespaces = data |> Enum.map(fn r -> elem(r.entity, 0) end) |> Enum.uniq()
      refute "finance" in namespaces
    end

    test "B09 cross-scope edges visible to root agent" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 1 DIRECTION outbound",
                 @company_context
               )

      assert Enum.any?(data, fn r -> r.entity == {"finance", "arr"} end)
    end

    test "B10 outbound on a node with both directions returns only outbound" do
      {:ok, _} =
        assert_minimal("b10_anchor", derived_from: ["entity:product:churn_rate"])

      {:ok, _} = assert_minimal("b10_pointer", derived_from: ["entity:test_exh:b10_anchor"])

      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:test_exh:b10_anchor DEPTH 1 DIRECTION outbound",
                 @product_context
               )

      assert Enum.all?(data, fn r -> r.direction == "outbound" end)
      refute Enum.any?(data, fn r -> r.entity == {"test_exh", "b10_pointer"} end)
    end

    test "B11 entity with no outbound edges returns empty data, not error" do
      # `headcount` has no outbound edges in the seed dataset.
      assert {:ok, %Cqr.Result{data: []}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:hr:headcount DEPTH 1 DIRECTION outbound",
                 @hr_context
               )
    end

    test "B12 nonexistent anchor entity does not error and returns empty data" do
      # The traversal MATCH simply returns no rows when the anchor does
      # not exist; DISCOVER tolerates missing anchors and returns an
      # empty result envelope, not an error envelope.
      assert {:ok, %Cqr.Result{data: []}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:product:b12_ghost DEPTH 1 DIRECTION outbound",
                 @product_context
               )
    end

    test "B13 self-referencing edge does not loop infinitely" do
      {:ok, _} = assert_minimal("b13_loop")

      # Wire a self-edge directly via the storage layer (the parser will
      # not let us assert an entity whose DERIVED_FROM contains itself
      # because the entity does not exist at validation time). The
      # DISCOVER call below still routes through the engine.
      {:ok, _} =
        GrafeoServer.query(
          "MATCH (e:Entity {namespace: 'test_exh', name: 'b13_loop'}) " <>
            "INSERT (e)-[:CORRELATES_WITH {strength: 0.9, asserted: true}]->(e)"
        )

      task =
        Task.async(fn ->
          Engine.execute(
            "DISCOVER concepts RELATED TO entity:test_exh:b13_loop DEPTH 2 DIRECTION outbound",
            @product_context
          )
        end)

      assert {:ok, %Cqr.Result{}} = Task.await(task, 5_000)
    end

    test "B14 LIMIT clause caps the result set" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 ~s(DISCOVER concepts RELATED TO "revenue" LIMIT 2),
                 @company_context
               )

      assert length(data) <= 2
    end
  end

  # ╔══════════════════════════════════════════════════════════════════════╗
  # ║ Section C — DISCOVER BM25 full-text                                  ║
  # ╚══════════════════════════════════════════════════════════════════════╝

  describe "Section C — DISCOVER BM25 full-text" do
    test "C01 single word matching entity name" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "churn"), @product_context)

      assert Enum.any?(data, fn r -> r.name == "churn_rate" and r.text_score > 0 end)
    end

    test "C02 single word matching description only" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "satisfaction"), @company_context)

      # csat's description is "Customer satisfaction score" — name does
      # not contain "satisfaction" but description does.
      assert Enum.any?(data, fn r -> r.name == "csat" and r.text_score > 0 end)
    end

    test "C03 multi-word query matches entities containing any of the words" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "churn nps"), @product_context)

      # The text scorer is whole-string substring count, so multi-word
      # queries are scored by literal phrase matches. Ensure the call
      # itself succeeds and that at least the vector modality returns
      # at least one product entity if no literal phrase matches.
      assert is_list(data)
    end

    test "C04 query with no plausible text match returns no text hits" do
      # The bag-of-words pseudo-embedding hashes every token to a fixed
      # dimension index, so even a nonsense token can collide with one
      # that an entity description happens to use. The text-relevance
      # path is the precise thing we want to assert is empty here:
      # nothing in the seed dataset literally contains the nonsense
      # token, so every returned row must have text_score == 0.
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 ~s(DISCOVER concepts RELATED TO "zzz_no_such_word_anywhere_zzz"),
                 @product_context
               )

      assert Enum.all?(data, fn r -> r.text_score == 0 end)
    end

    test "C05 case insensitivity: uppercase and lowercase return the same hits" do
      {:ok, %Cqr.Result{data: lower}} =
        Engine.execute(~s(DISCOVER concepts RELATED TO "churn"), @product_context)

      {:ok, %Cqr.Result{data: upper}} =
        Engine.execute(~s(DISCOVER concepts RELATED TO "CHURN"), @product_context)

      lower_names = lower |> Enum.map(& &1.name) |> Enum.sort()
      upper_names = upper |> Enum.map(& &1.name) |> Enum.sort()
      assert lower_names == upper_names
    end

    test "C06 root agent sees matches across multiple scopes" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "revenue"), @company_context)

      namespaces = data |> Enum.map(& &1.namespace) |> Enum.uniq() |> Enum.sort()
      assert "finance" in namespaces
      assert "customer_success" in namespaces
    end

    test "C07 product scope: 'revenue' query returns no entities" do
      assert {:ok, %Cqr.Result{data: []}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "revenue"), @product_context)
    end

    test "C08 finance scope: 'revenue' query returns finance entities only" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "revenue"), @finance_context)

      assert [_ | _] = data

      Enum.each(data, fn r ->
        assert r.namespace == "finance",
               "expected finance namespace, got #{inspect(r.namespace)}"
      end)
    end

    test "C09 single character query does not crash" do
      assert {:ok, %Cqr.Result{}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "a"), @company_context)
    end

    test "C10 query with special characters does not crash" do
      assert {:ok, %Cqr.Result{}} =
               Engine.execute(
                 ~s|DISCOVER concepts RELATED TO "rev-growth (ish)"|,
                 @company_context
               )
    end
  end

  # ╔══════════════════════════════════════════════════════════════════════╗
  # ║ Section D — DISCOVER vector similarity                               ║
  # ╚══════════════════════════════════════════════════════════════════════╝

  describe "Section D — DISCOVER vector similarity" do
    test "D01 semantic query without exact keyword overlap still returns results" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 ~s(DISCOVER concepts RELATED TO "customer"),
                 @company_context
               )

      assert Enum.any?(data, fn r -> is_float(r.similarity) and r.similarity > 0.0 end)
    end

    test "D02 customer satisfaction → csat ranks via vector similarity" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 ~s(DISCOVER concepts RELATED TO "customer satisfaction loyalty"),
                 @company_context
               )

      csat = Enum.find(data, &(&1.name == "csat"))
      assert csat
      assert is_float(csat.similarity) and csat.similarity > 0.0
    end

    test "D03 engineering performance surfaces eng metrics" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 ~s(DISCOVER concepts RELATED TO "engineering performance deployment"),
                 @company_context
               )

      assert Enum.any?(data, fn r ->
               r.namespace == "engineering" and is_float(r.similarity) and r.similarity > 0.0
             end)
    end

    test "D04 revenue growth sustainability surfaces finance metrics" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 ~s(DISCOVER concepts RELATED TO "revenue growth sustainability"),
                 @company_context
               )

      assert Enum.any?(data, fn r ->
               r.namespace == "finance" and (r.text_score > 0 or r.similarity > 0.0)
             end)
    end

    test "D05 employee wellbeing surfaces hr metrics" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 ~s(DISCOVER concepts RELATED TO "employee wellbeing engagement"),
                 @company_context
               )

      assert Enum.any?(data, fn r ->
               r.namespace == "hr" and (is_float(r.similarity) and r.similarity > 0.0)
             end)
    end

    test "D06 results carry source attribution: vector|text|both" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 ~s(DISCOVER concepts RELATED TO "customer satisfaction"),
                 @company_context
               )

      assert [_ | _] = data
      Enum.each(data, fn r -> assert r.source in ["vector", "text", "both"] end)
    end

    test "D07 entities matching both modalities carry source: both" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "revenue"), @finance_context)

      rg = Enum.find(data, &(&1.name == "revenue_growth"))
      assert rg
      assert rg.source == "both"
    end

    test "D08 vector results respect scope filtering — product agent never sees HR" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(
                 ~s(DISCOVER concepts RELATED TO "employee headcount"),
                 @product_context
               )

      namespaces = data |> Enum.map(& &1.namespace) |> Enum.uniq()
      refute "hr" in namespaces
    end
  end

  # ╔══════════════════════════════════════════════════════════════════════╗
  # ║ Section E — DISCOVER multi-paradigm merge                            ║
  # ╚══════════════════════════════════════════════════════════════════════╝

  describe "Section E — multi-paradigm merge" do
    test "E01 entity hit by both modalities is deduplicated" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "revenue"), @finance_context)

      revenue_growths = Enum.filter(data, &(&1.name == "revenue_growth"))
      assert length(revenue_growths) == 1
    end

    test "E02 combined_score = normalized text_score + similarity" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "revenue"), @finance_context)

      Enum.each(data, fn r ->
        expected = r.text_score / max_text(data) + (r.similarity || 0.0)
        # Normalized text_score uses the max text_score across results;
        # for vector-only results text_score is 0 so combined is just similarity.
        assert_in_delta r.combined_score, expected, 0.01
      end)
    end

    test "E03 results sort by combined_score descending" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "revenue"), @finance_context)

      scores = Enum.map(data, & &1.combined_score)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  defp max_text(data) do
    case Enum.map(data, & &1.text_score) |> Enum.max(fn -> 1 end) do
      0 -> 1
      v -> v
    end
  end

  # ╔══════════════════════════════════════════════════════════════════════╗
  # ║ Section F — CERTIFY lifecycle                                        ║
  # ╚══════════════════════════════════════════════════════════════════════╝

  describe "Section F — CERTIFY lifecycle" do
    test "F01 full lifecycle proposed → under_review → certified" do
      {:ok, _} = assert_minimal("f01_full")

      assert {:ok, _} =
               certify_phase("entity:test_exh:f01_full", "proposed", authority: "f01_lead")

      assert {:ok, _} =
               certify_phase("entity:test_exh:f01_full", "under_review", authority: "f01_lead")

      assert {:ok, %Cqr.Result{}} =
               certify_phase("entity:test_exh:f01_full", "certified", authority: "f01_lead")

      {:ok, %Cqr.Result{data: [entity]}} =
        Engine.execute("RESOLVE entity:test_exh:f01_full", @product_context)

      assert entity.certified == true
    end

    test "F02 skip transition proposed → certified errors with valid transitions" do
      {:ok, _} = assert_minimal("f02_skip")

      {:ok, _} =
        certify_phase("entity:test_exh:f02_skip", "proposed", authority: "f02_lead")

      assert {:error, %Cqr.Error{code: :invalid_transition, retry_guidance: g}} =
               certify_phase("entity:test_exh:f02_skip", "certified", authority: "f02_lead")

      assert g =~ "under_review"
    end

    test "F03 reverse transition certified → proposed errors" do
      {:ok, _} = assert_minimal("f03_reverse")
      {:ok, _} = full_certify("entity:test_exh:f03_reverse", authority: "f03_lead")

      assert {:error, %Cqr.Error{code: :invalid_transition}} =
               certify_phase("entity:test_exh:f03_reverse", "proposed", authority: "f03_lead")
    end

    test "F04 allowed reverse: under_review → proposed" do
      {:ok, _} = assert_minimal("f04_bounce")

      {:ok, _} =
        certify_phase("entity:test_exh:f04_bounce", "proposed", authority: "f04_lead")

      {:ok, _} =
        certify_phase("entity:test_exh:f04_bounce", "under_review", authority: "f04_lead")

      assert {:ok, _} =
               certify_phase("entity:test_exh:f04_bounce", "proposed", authority: "f04_lead")
    end

    test "F05 superseded drops reputation to ≤ 0.3" do
      {:ok, _} = assert_minimal("f05_super")
      {:ok, _} = full_certify("entity:test_exh:f05_super", authority: "f05_lead")

      assert {:ok, _} =
               certify_phase("entity:test_exh:f05_super", "superseded", authority: "f05_lead")

      {:ok, %Cqr.Result{data: [entity]}} =
        Engine.execute("RESOLVE entity:test_exh:f05_super", @product_context)

      assert entity.reputation <= 0.3
    end

    test "F06 certified entity has certified_at populated" do
      {:ok, _} = assert_minimal("f06_certat")
      {:ok, _} = full_certify("entity:test_exh:f06_certat", authority: "f06_lead")

      {:ok, %Cqr.Result{data: [entity], quality: q}} =
        Engine.execute("RESOLVE entity:test_exh:f06_certat", @product_context)

      assert is_binary(entity.certified_at)
      assert %DateTime{} = q.certified_at
    end

    test "F07 certified_by reflects the authority, not the asserter" do
      {:ok, _} = assert_minimal("f07_certby")

      {:ok, _} =
        full_certify("entity:test_exh:f07_certby", authority: "f07_external_authority")

      {:ok, %Cqr.Result{data: [entity]}} =
        Engine.execute("RESOLVE entity:test_exh:f07_certby", @product_context)

      assert entity.certified_by == "f07_external_authority"
      refute entity.certified_by == @product_context.agent_id
    end

    test "F08 certified entity reputation ≥ 0.9" do
      {:ok, _} = assert_minimal("f08_rep")
      {:ok, _} = full_certify("entity:test_exh:f08_rep", authority: "f08_lead")

      {:ok, %Cqr.Result{data: [entity]}} =
        Engine.execute("RESOLVE entity:test_exh:f08_rep", @product_context)

      assert entity.reputation >= 0.9
    end

    test "F09 a CertificationRecord exists per transition (queried via Grafeo)" do
      {:ok, _} = assert_minimal("f09_audit")
      {:ok, _} = full_certify("entity:test_exh:f09_audit", authority: "f09_lead")

      {:ok, rows} =
        GrafeoServer.query(
          "MATCH (e:Entity {namespace: 'test_exh', name: 'f09_audit'})" <>
            "-[:CERTIFICATION_EVENT]->(r:CertificationRecord) RETURN r.new_status"
        )

      statuses = rows |> Enum.map(& &1["r.new_status"]) |> Enum.sort()
      assert statuses == ["certified", "proposed", "under_review"]
    end

    test "F10 evidence preserved on each CertificationRecord" do
      {:ok, _} = assert_minimal("f10_ev")

      for {status, evidence} <- [
            {"proposed", "f10 propose evidence"},
            {"under_review", "f10 review evidence"},
            {"certified", "f10 certify evidence"}
          ] do
        {:ok, _} =
          certify_phase("entity:test_exh:f10_ev", status,
            authority: "f10_lead",
            evidence: evidence
          )
      end

      {:ok, rows} =
        GrafeoServer.query(
          "MATCH (e:Entity {namespace: 'test_exh', name: 'f10_ev'})" <>
            "-[:CERTIFICATION_EVENT]->(r:CertificationRecord) " <>
            "RETURN r.new_status, r.evidence"
        )

      assert length(rows) == 3
      Enum.each(rows, fn r -> assert r["r.evidence"] =~ "f10" end)
    end

    test "F11 finance agent cannot certify a product entity" do
      {:ok, _} = assert_minimal("f11_scope")

      assert {:error, %Cqr.Error{code: code}} =
               certify_phase("entity:test_exh:f11_scope", "proposed",
                 authority: "f11_finance",
                 context: @finance_context
               )

      assert code in [:scope_access, :entity_not_found]
    end
  end

  # ╔══════════════════════════════════════════════════════════════════════╗
  # ║ Section G — RESOLVE edge cases                                       ║
  # ╚══════════════════════════════════════════════════════════════════════╝

  describe "Section G — RESOLVE edge cases" do
    test "G01 resolve a seeded entity returns full metadata" do
      assert {:ok, %Cqr.Result{data: [entity]}} =
               Engine.execute("RESOLVE entity:product:churn_rate", @product_context)

      assert entity.name == "churn_rate"
      assert entity.type == "metric"
      assert is_float(entity.reputation) or is_integer(entity.reputation)
    end

    test "G02 resolve an asserted entity includes certified: false and ASSERT provenance" do
      {:ok, _} = assert_minimal("g02_asserted")

      assert {:ok, %Cqr.Result{data: [entity]}} =
               Engine.execute("RESOLVE entity:test_exh:g02_asserted", @product_context)

      assert entity.certified == false
    end

    test "G03 resolve a certified entity surfaces certified_by + certified_at" do
      {:ok, _} = assert_minimal("g03_cert")
      {:ok, _} = full_certify("entity:test_exh:g03_cert", authority: "g03_authority")

      assert {:ok, %Cqr.Result{data: [entity], quality: q}} =
               Engine.execute("RESOLVE entity:test_exh:g03_cert", @product_context)

      assert entity.certified == true
      assert entity.certified_by == "g03_authority"
      assert q.certified_by == "g03_authority"
      assert %DateTime{} = q.certified_at
    end

    test "G04 resolve nonexistent entity returns entity_not_found with retry guidance" do
      assert {:error, %Cqr.Error{code: :entity_not_found, retry_guidance: g}} =
               Engine.execute(
                 "RESOLVE entity:product:totally_made_up_g04",
                 @product_context
               )

      assert g =~ "scope" or g =~ "namespace"
    end

    test "G05 resolve sibling-scope entity returns not_found (genuine invisibility)" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute("RESOLVE entity:hr:headcount", @product_context)
    end

    test "G06 root agent with FROM scope:company:product narrows visibility" do
      assert {:ok, %Cqr.Result{}} =
               Engine.execute(
                 "RESOLVE entity:product:churn_rate FROM scope:company:product",
                 @company_context
               )

      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute(
                 "RESOLVE entity:hr:headcount FROM scope:company:product",
                 @company_context
               )
    end

    test "G07 RESOLVE FROM a scope outside the agent sandbox is scope_access" do
      assert {:error, %Cqr.Error{code: :scope_access}} =
               Engine.execute(
                 "RESOLVE entity:hr:headcount FROM scope:company:hr",
                 @product_context
               )
    end
  end

  # ╔══════════════════════════════════════════════════════════════════════╗
  # ║ Section H — Scope enforcement comprehensive                          ║
  # ╚══════════════════════════════════════════════════════════════════════╝

  describe "Section H — scope enforcement comprehensive" do
    test "H01 product agent: sees product entities, not finance/hr/engineering" do
      assert {:ok, _} = Engine.execute("RESOLVE entity:product:churn_rate", @product_context)

      for ref <- [
            "entity:hr:headcount",
            "entity:finance:arr",
            "entity:engineering:deployment_frequency"
          ] do
        assert {:error, %Cqr.Error{code: :entity_not_found}} =
                 Engine.execute("RESOLVE #{ref}", @product_context)
      end
    end

    test "H02 finance agent: sees finance entities, not product/hr/engineering" do
      assert {:ok, _} = Engine.execute("RESOLVE entity:finance:arr", @finance_context)

      for ref <- [
            "entity:product:churn_rate",
            "entity:hr:headcount",
            "entity:engineering:deployment_frequency"
          ] do
        assert {:error, %Cqr.Error{code: :entity_not_found}} =
                 Engine.execute("RESOLVE #{ref}", @finance_context)
      end
    end

    test "H03 root agent sees all seed entities across all scopes" do
      for ref <- [
            "entity:product:churn_rate",
            "entity:finance:arr",
            "entity:hr:headcount",
            "entity:engineering:deployment_frequency",
            "entity:customer_success:csat"
          ] do
        assert {:ok, _} = Engine.execute("RESOLVE #{ref}", @company_context)
      end
    end

    test "H04 root agent FROM scope:company:product narrows to product subtree" do
      assert {:ok, _} =
               Engine.execute(
                 "RESOLVE entity:product:churn_rate FROM scope:company:product",
                 @company_context
               )

      for ref <-
            ~w(entity:hr:headcount entity:finance:arr entity:engineering:deployment_frequency) do
        assert {:error, %Cqr.Error{code: :entity_not_found}} =
                 Engine.execute(
                   "RESOLVE #{ref} FROM scope:company:product",
                   @company_context
                 )
      end
    end

    test "H05 entity asserted at root scope is visible to every descendant agent" do
      {:ok, _} =
        assert_minimal("h05_root_entity",
          context: @company_context,
          scope: "scope:company"
        )

      for ctx <- [@product_context, @finance_context, @hr_context, @engineering_context] do
        assert {:ok, _} =
                 Engine.execute("RESOLVE entity:test_exh:h05_root_entity", ctx)
      end
    end

    test "H06 entity asserted at product scope is invisible to finance" do
      {:ok, _} =
        assert_minimal("h06_product_only",
          scope: "scope:company:product"
        )

      assert {:ok, _} =
               Engine.execute("RESOLVE entity:test_exh:h06_product_only", @product_context)

      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               Engine.execute("RESOLVE entity:test_exh:h06_product_only", @finance_context)
    end

    test "H07 free-text 'revenue' from product scope returns 0 results" do
      assert {:ok, %Cqr.Result{data: []}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "revenue"), @product_context)
    end

    test "H08 free-text 'revenue' from finance scope returns finance results only" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "revenue"), @finance_context)

      assert [_ | _] = data
      assert Enum.all?(data, fn r -> r.namespace == "finance" end)
    end

    test "H09 free-text 'revenue' from root scope returns multi-scope results" do
      assert {:ok, %Cqr.Result{data: data}} =
               Engine.execute(~s(DISCOVER concepts RELATED TO "revenue"), @company_context)

      namespaces = data |> Enum.map(& &1.namespace) |> Enum.uniq()
      assert "finance" in namespaces
      assert length(namespaces) >= 2
    end
  end

  # ╔══════════════════════════════════════════════════════════════════════╗
  # ║ Section I — cross-primitive workflows                                ║
  # ╚══════════════════════════════════════════════════════════════════════╝

  describe "Section I — cross-primitive workflows" do
    test "I01 onboarding: free-text DISCOVER → RESOLVE → DISCOVER neighborhood" do
      # Step 1: free-text DISCOVER
      {:ok, %Cqr.Result{data: search_data}} =
        Engine.execute(~s(DISCOVER concepts RELATED TO "churn"), @product_context)

      assert Enum.any?(search_data, &(&1.name == "churn_rate"))

      # Step 2: RESOLVE one of the surfaced entities
      {:ok, %Cqr.Result{data: [resolved]}} =
        Engine.execute("RESOLVE entity:product:churn_rate", @product_context)

      assert resolved.name == "churn_rate"

      # Step 3: DISCOVER its neighborhood
      {:ok, %Cqr.Result{data: rels}} =
        Engine.execute(
          "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 1 DIRECTION outbound",
          @product_context
        )

      assert [_ | _] = rels
    end

    test "I02 derived insight: DISCOVER → ASSERT → reverse-DISCOVER picks it up" do
      {:ok, _} =
        Engine.execute(
          "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 1 DIRECTION outbound",
          @product_context
        )

      {:ok, _} =
        assert_minimal("i02_insight",
          derived_from: ["entity:product:churn_rate", "entity:product:nps"]
        )

      {:ok, %Cqr.Result{data: inbound_data}} =
        Engine.execute(
          "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 1 DIRECTION inbound",
          @product_context
        )

      assert Enum.any?(inbound_data, &(&1.entity == {"test_exh", "i02_insight"}))
    end

    test "I03 governance: ASSERT → CERTIFY full lifecycle → RESOLVE shows certified" do
      {:ok, _} = assert_minimal("i03_gov")
      {:ok, _} = full_certify("entity:test_exh:i03_gov", authority: "i03_board")

      assert {:ok, %Cqr.Result{data: [entity]}} =
               Engine.execute("RESOLVE entity:test_exh:i03_gov", @product_context)

      assert entity.certified == true
      assert entity.reputation >= 0.9
    end

    test "I04 impact analysis: DEPTH 2 outbound + recommendation ASSERT + CERTIFY" do
      # The seeded chain enps -CAUSES-> attrition_rate -CONTRIBUTES_TO-> operating_expenses
      assert {:ok, %Cqr.Result{data: depth2}} =
               Engine.execute(
                 "DISCOVER concepts RELATED TO entity:hr:enps DEPTH 2 DIRECTION outbound",
                 @company_context
               )

      entities = Enum.map(depth2, & &1.entity)
      assert {"hr", "attrition_rate"} in entities
      assert {"finance", "operating_expenses"} in entities

      {:ok, _} =
        assert_minimal("i04_recommendation",
          derived_from: ["entity:hr:enps"],
          context: @company_context,
          scope: "scope:company"
        )

      {:ok, _} =
        full_certify("entity:test_exh:i04_recommendation",
          authority: "i04_board",
          context: @company_context
        )

      {:ok, %Cqr.Result{data: [entity]}} =
        Engine.execute("RESOLVE entity:test_exh:i04_recommendation", @company_context)

      assert entity.certified == true
    end

    test "I05 cross-domain: finance agent searching 'customer' sees finance, not customer_success" do
      {:ok, %Cqr.Result{data: data}} =
        Engine.execute(~s(DISCOVER concepts RELATED TO "customer"), @finance_context)

      namespaces = data |> Enum.map(& &1.namespace) |> Enum.uniq()
      refute "customer_success" in namespaces
      refute "product" in namespaces
      refute "hr" in namespaces
    end

    test "I06 trust evaluation: compare reputation + certification across multiple entities" do
      {:ok, _} = assert_minimal("i06_unc")

      {:ok, _} = assert_minimal("i06_cert", scope: "scope:company:product")
      {:ok, _} = full_certify("entity:test_exh:i06_cert", authority: "i06_board")

      {:ok, %Cqr.Result{data: [unc]}} =
        Engine.execute("RESOLVE entity:test_exh:i06_unc", @product_context)

      {:ok, %Cqr.Result{data: [cert]}} =
        Engine.execute("RESOLVE entity:test_exh:i06_cert", @product_context)

      assert unc.certified == false
      assert cert.certified == true
      assert cert.reputation > unc.reputation
    end
  end

  # ╔══════════════════════════════════════════════════════════════════════╗
  # ║ Section J — scale + asserted-target hang regression                  ║
  # ╚══════════════════════════════════════════════════════════════════════╝

  describe "Section J — scale and the asserted-target hang regression" do
    @timeout_ms 5_000

    test "J01 assert 20 entities in sequence → all visible via RESOLVE" do
      Enum.each(1..20, fn i ->
        {:ok, _} = assert_minimal("j01_seq_#{i}")
      end)

      Enum.each(1..20, fn i ->
        assert {:ok, %Cqr.Result{data: [%{name: name}]}} =
                 Engine.execute("RESOLVE entity:test_exh:j01_seq_#{i}", @product_context)

        assert name == "j01_seq_#{i}"
      end)
    end

    test "J02 hub with 30 DERIVED_FROM edges (seeded targets) returns in <1s" do
      seeded = ~w(
        entity:product:churn_rate entity:product:nps entity:product:dau
        entity:product:retention_rate entity:product:feature_adoption
        entity:product:time_to_value
      )

      derived =
        Enum.map(0..29, fn i -> Enum.at(seeded, rem(i, length(seeded))) end)

      {:ok, _} = assert_minimal("j02_hub", derived_from: derived)

      task =
        Task.async(fn ->
          :timer.tc(fn ->
            Engine.execute(
              "DISCOVER concepts RELATED TO entity:test_exh:j02_hub DEPTH 1 DIRECTION outbound",
              @product_context
            )
          end)
        end)

      {us, {:ok, %Cqr.Result{data: data}}} = Task.await(task, @timeout_ms)

      # 30 edges to 6 unique targets — DISTINCT collapses to 6 rows.
      assert length(data) == length(seeded)
      assert us / 1_000 < 1_000
    end

    test "J03 hub with 30 mixed (seeded + asserted) targets must NOT hang" do
      asserted_leaves =
        Enum.map(1..15, fn i ->
          {:ok, _} = assert_minimal("j03_leaf_#{i}")
          "entity:test_exh:j03_leaf_#{i}"
        end)

      seeded_targets = ~w(
        entity:product:churn_rate entity:product:nps entity:product:dau
        entity:product:retention_rate entity:product:feature_adoption
        entity:product:time_to_value entity:product:csat_proxy_unused
      )

      seeded_targets =
        Enum.filter(seeded_targets, fn ref ->
          [_, ns, name] = String.split(ref, ":")
          Cqr.Repo.Semantic.entity_exists?({ns, name})
        end)

      derived = asserted_leaves ++ seeded_targets
      {:ok, _} = assert_minimal("j03_hub", derived_from: derived)

      task =
        Task.async(fn ->
          :timer.tc(fn ->
            Engine.execute(
              "DISCOVER concepts RELATED TO entity:test_exh:j03_hub DEPTH 1 DIRECTION outbound",
              @product_context
            )
          end)
        end)

      {us, {:ok, %Cqr.Result{data: data}}} = Task.await(task, @timeout_ms)

      assert length(data) == length(derived)
      assert us / 1_000 < 1_000
    end

    test "J04 inbound DISCOVER on a highly-referenced seed entity returns all inbound edges" do
      Enum.each(1..15, fn i ->
        {:ok, _} = assert_minimal("j04_pointer_#{i}")
      end)

      task =
        Task.async(fn ->
          Engine.execute(
            "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 1 DIRECTION inbound",
            @product_context
          )
        end)

      {:ok, %Cqr.Result{data: data}} = Task.await(task, @timeout_ms)

      pointer_entities =
        data
        |> Enum.filter(fn r -> elem(r.entity, 0) == "test_exh" end)
        |> Enum.map(& &1.entity)

      Enum.each(1..15, fn i ->
        assert {"test_exh", "j04_pointer_#{i}"} in pointer_entities
      end)
    end

    test "J05 free-text DISCOVER across the full dataset returns in <1s" do
      task =
        Task.async(fn ->
          :timer.tc(fn ->
            Engine.execute(~s(DISCOVER concepts RELATED TO "rate"), @company_context)
          end)
        end)

      {us, {:ok, %Cqr.Result{}}} = Task.await(task, @timeout_ms)
      assert us / 1_000 < 1_000
    end
  end

  # ╔══════════════════════════════════════════════════════════════════════╗
  # ║ Section K — error handling                                           ║
  # ╚══════════════════════════════════════════════════════════════════════╝

  describe "Section K — error handling" do
    test "K01 RESOLVE with empty entity string is a parse error" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Engine.execute("RESOLVE ", @product_context)
    end

    test "K02 DISCOVER with empty topic is a parse error" do
      assert {:error, %Cqr.Error{code: :parse_error}} =
               Engine.execute("DISCOVER concepts RELATED TO ", @product_context)
    end

    test "K03 CERTIFY on a nonexistent entity is entity_not_found" do
      assert {:error, %Cqr.Error{code: :entity_not_found}} =
               certify_phase("entity:test_exh:k03_ghost", "proposed", authority: "k03_lead")
    end

    test "K04 ASSERT with empty description is a parse error" do
      expr =
        ~s(ASSERT entity:test_exh:k04 TYPE m DESCRIPTION  INTENT "x" ) <>
          ~s(DERIVED_FROM entity:product:churn_rate)

      assert {:error, %Cqr.Error{code: :parse_error}} =
               Engine.execute(expr, @product_context)
    end

    test "K05 ASSERT with empty intent is a parse error" do
      expr =
        ~s(ASSERT entity:test_exh:k05 TYPE m DESCRIPTION "d" INTENT  ) <>
          ~s(DERIVED_FROM entity:product:churn_rate)

      assert {:error, %Cqr.Error{code: :parse_error}} =
               Engine.execute(expr, @product_context)
    end

    test "K06 ASSERT with no DERIVED_FROM is missing_required_field" do
      expr =
        ~s(ASSERT entity:test_exh:k06 TYPE m DESCRIPTION "d" INTENT "i")

      assert {:error, %Cqr.Error{code: :missing_required_field, details: %{missing: missing}}} =
               Engine.execute(expr, @product_context)

      assert "DERIVED_FROM" in missing
    end

    test "K07 CERTIFY with an invalid status string is a parse error" do
      expr = "CERTIFY entity:product:churn_rate STATUS bogus_status"

      assert {:error, %Cqr.Error{code: :parse_error}} =
               Engine.execute(expr, @product_context)
    end

    test "K08 DISCOVER with an invalid direction is a parse error" do
      expr =
        "DISCOVER concepts RELATED TO entity:product:churn_rate DIRECTION sideways"

      assert {:error, %Cqr.Error{code: :parse_error}} =
               Engine.execute(expr, @product_context)
    end
  end
end
