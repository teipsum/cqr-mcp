defmodule Cqr.Integration.UpdateTest do
  @moduledoc """
  Integration tests for the UPDATE primitive.

  Exercises parser -> `Cqr.Engine` -> `Cqr.Engine.Update` -> Grafeo
  (VersionRecord + PREVIOUS_VERSION edge + Entity node update) with the
  full governance matrix and round-trips through RESOLVE/TRACE.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine
  alias Cqr.Grafeo.Server, as: GrafeoServer

  @product_context %{scope: ["company", "product"], agent_id: "twin:update_product"}

  setup do
    cleanup()
    on_exit(&cleanup/0)
    :ok
  end

  defp cleanup do
    ns = "test_update"
    GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'})-[r]-() DELETE r")
    GrafeoServer.query("MATCH (e:Entity {namespace: '#{ns}'}) DELETE e")
    GrafeoServer.query("MATCH (r:AssertionRecord {entity_namespace: '#{ns}'}) DELETE r")
    GrafeoServer.query("MATCH (r:CertificationRecord {entity_namespace: '#{ns}'}) DELETE r")
    GrafeoServer.query("MATCH (r:VersionRecord {entity_namespace: '#{ns}'}) DELETE r")
    GrafeoServer.query("MATCH (r:SignalRecord {entity_namespace: '#{ns}'}) DELETE r")
    :ok
  end

  defp assert_fixture(name) do
    expr =
      ~s(ASSERT entity:test_update:#{name} TYPE derived_metric ) <>
        ~s(DESCRIPTION "Original description" ) <>
        ~s(INTENT "Exercise UPDATE governance" ) <>
        ~s(DERIVED_FROM entity:product:churn_rate)

    assert {:ok, _} = Engine.execute(expr, @product_context)
    {"test_update", name}
  end

  defp certify(name, status, authority \\ "product_lead") do
    # Authorities with colons (like "authority:data_governance_board") must be
    # quoted in the CQR grammar; bare identifiers are fine without quotes.
    auth_clause =
      if String.contains?(authority, ":"),
        do: ~s(AUTHORITY "#{authority}"),
        else: "AUTHORITY #{authority}"

    expr = "CERTIFY entity:test_update:#{name} STATUS #{status} #{auth_clause}"
    assert {:ok, _} = Engine.execute(expr, @product_context)
  end

  defp resolve(name) do
    {:ok, r} = Engine.execute("RESOLVE entity:test_update:#{name}", @product_context)
    hd(r.data)
  end

  defp update(name, change_type, opts) do
    parts = ["UPDATE entity:test_update:#{name}", "CHANGE_TYPE #{change_type}"]

    parts =
      if desc = opts[:description],
        do: parts ++ [~s(DESCRIPTION "#{desc}")],
        else: parts

    parts = if t = opts[:type], do: parts ++ ["TYPE #{t}"], else: parts

    parts =
      if ev = opts[:evidence],
        do: parts ++ [~s(EVIDENCE "#{ev}")],
        else: parts

    parts =
      if c = opts[:confidence],
        do: parts ++ ["CONFIDENCE #{c}"],
        else: parts

    Engine.execute(Enum.join(parts, " "), @product_context)
  end

  describe "uncertified updates — each change_type applies" do
    for ct <- [:correction, :refresh, :redefinition, :scope_change, :reclassification] do
      test "change_type #{ct} applies on an uncertified entity" do
        assert_fixture("uncert_#{unquote(ct)}")

        assert {:ok, r} =
                 update("uncert_#{unquote(ct)}", unquote(ct),
                   description: "Revised description (#{unquote(ct)})",
                   evidence: "Applied by test"
                 )

        row = hd(r.data)
        assert row.status == "applied"
        assert row.change_type == unquote(ct)

        resolved = resolve("uncert_#{unquote(ct)}")
        assert resolved.description == "Revised description (#{unquote(ct)})"
      end
    end
  end

  describe "version history" do
    test "VersionRecord captures previous state and links via PREVIOUS_VERSION" do
      assert_fixture("version_record")

      assert {:ok, _} =
               update("version_record", :correction,
                 description: "Second description",
                 evidence: "First correction"
               )

      {:ok, rows} =
        GrafeoServer.query(
          "MATCH (e:Entity {namespace: 'test_update', name: 'version_record'})" <>
            "-[:PREVIOUS_VERSION]->(v:VersionRecord) " <>
            "RETURN v.previous_description, v.previous_type, v.change_type, " <>
            "v.evidence, v.agent_id, v.status"
        )

      assert [row] = rows
      assert row["v.previous_description"] == "Original description"
      assert row["v.previous_type"] == "derived_metric"
      assert row["v.change_type"] == "correction"
      assert row["v.evidence"] == "First correction"
      assert row["v.agent_id"] == "twin:update_product"
      assert row["v.status"] == "applied"
    end

    test "successive updates create multiple VersionRecords" do
      assert_fixture("multi_version")

      for i <- 1..3 do
        assert {:ok, _} =
                 update("multi_version", :correction,
                   description: "Description v#{i}",
                   evidence: "Iteration #{i}"
                 )
      end

      {:ok, rows} =
        GrafeoServer.query(
          "MATCH (e:Entity {namespace: 'test_update', name: 'multi_version'})" <>
            "-[:PREVIOUS_VERSION]->(v:VersionRecord) " <>
            "RETURN v.previous_description"
        )

      assert length(rows) == 3
    end
  end

  describe "missing entity" do
    test "UPDATE on a non-existent entity returns entity_not_found" do
      assert {:error, err} =
               update("does_not_exist", :correction, description: "Will fail")

      assert err.code == :entity_not_found
    end
  end

  describe "superseded revival" do
    test "UPDATE on a superseded entity revives it (certification reset to nil)" do
      assert_fixture("superseded_revive")

      for s <- ["proposed", "under_review", "certified", "superseded"] do
        certify("superseded_revive", s)
      end

      before = resolve("superseded_revive")
      assert before.certified == false
      assert before.reputation <= 0.3

      assert {:ok, r} =
               update("superseded_revive", :refresh,
                 description: "Revived content",
                 evidence: "Bringing it back"
               )

      assert hd(r.data).status == "applied"

      after_update = resolve("superseded_revive")
      assert after_update.description == "Revived content"
      assert after_update.certified == false
      assert after_update.certification_status == nil
      assert after_update.reputation == 0.5
    end
  end

  describe "certified entity — preserving vs contesting" do
    test "correction on certified entity applies and preserves certification" do
      assert_fixture("cert_correction")

      for s <- ["proposed", "under_review", "certified"] do
        certify("cert_correction", s, "authority:data_governance_board")
      end

      assert {:ok, r} =
               update("cert_correction", :correction,
                 description: "Typo fixed",
                 evidence: "Fixing a typo"
               )

      assert hd(r.data).status == "applied"

      resolved = resolve("cert_correction")
      assert resolved.description == "Typo fixed"
      assert resolved.certified == true
      assert resolved.certification_status == "certified"
    end

    test "redefinition on certified entity transitions to contested (pending review)" do
      assert_fixture("cert_redef")

      for s <- ["proposed", "under_review", "certified"] do
        certify("cert_redef", s, "authority:data_governance_board")
      end

      before = resolve("cert_redef")
      assert before.description == "Original description"

      assert {:ok, r} =
               update("cert_redef", :redefinition,
                 description: "Completely new meaning",
                 evidence: "Semantic change proposed"
               )

      row = hd(r.data)
      assert row.status == "pending_review"
      assert row.change_type == :redefinition
      assert row.proposed_description == "Completely new meaning"

      after_update = resolve("cert_redef")
      # Description is NOT applied yet (pending review).
      assert after_update.description == "Original description"
      # Entity has been transitioned to contested.
      assert after_update.certification_status == "contested"
      assert after_update.certified == false

      # A VersionRecord with pending_review status must exist.
      {:ok, vr_rows} =
        GrafeoServer.query(
          "MATCH (v:VersionRecord {entity_namespace: 'test_update', " <>
            "entity_name: 'cert_redef'}) RETURN v.status, v.proposed_description"
        )

      assert Enum.any?(vr_rows, fn row ->
               row["v.status"] == "pending_review" and
                 row["v.proposed_description"] == "Completely new meaning"
             end)
    end
  end

  describe "blocked updates" do
    test "redefinition on under_review entity is blocked" do
      assert_fixture("blocked_review")

      for s <- ["proposed", "under_review"] do
        certify("blocked_review", s)
      end

      assert {:error, err} =
               update("blocked_review", :redefinition,
                 description: "Cannot proceed",
                 evidence: "Attempt"
               )

      assert err.code == :invalid_transition
      assert err.message =~ "under review"
    end

    test "any update on contested entity is blocked" do
      assert_fixture("blocked_contested")

      for s <- ["proposed", "under_review", "certified"] do
        certify("blocked_contested", s, "authority:data_governance_board")
      end

      # Move to contested via CERTIFY.
      certify("blocked_contested", "contested", "challenger")

      assert {:error, err} =
               update("blocked_contested", :correction,
                 description: "Blocked",
                 evidence: "Should fail"
               )

      assert err.code == :invalid_transition
      assert err.message =~ "contest"
    end
  end

  describe "TRACE integration" do
    test "TRACE on an updated entity surfaces version_history" do
      assert_fixture("trace_versions")

      assert {:ok, _} =
               update("trace_versions", :correction,
                 description: "v2",
                 evidence: "first edit"
               )

      assert {:ok, _} =
               update("trace_versions", :refresh,
                 description: "v3",
                 evidence: "freshen"
               )

      assert {:ok, trace_result} =
               Engine.execute("TRACE entity:test_update:trace_versions", @product_context)

      trace_row = hd(trace_result.data)
      assert is_list(trace_row.version_history)
      assert length(trace_row.version_history) == 2

      change_types = Enum.map(trace_row.version_history, & &1.change_type)
      assert "correction" in change_types
      assert "refresh" in change_types

      # Each VersionRecord exposes the fields TRACE consumers need.
      first = hd(trace_row.version_history)
      assert Map.has_key?(first, :previous_description)
      assert Map.has_key?(first, :previous_type)
      assert Map.has_key?(first, :change_type)
      assert Map.has_key?(first, :evidence)
      assert Map.has_key?(first, :agent)
      assert Map.has_key?(first, :timestamp)
    end
  end

  describe "certification preservation policy — :strict" do
    setup do
      Application.put_env(:cqr_mcp, :certification_preservation_policy, :strict)
      on_exit(fn -> Application.delete_env(:cqr_mcp, :certification_preservation_policy) end)
      :ok
    end

    test "correction on certified entity transitions to contested (pending review)" do
      assert_fixture("strict_correction")

      for s <- ["proposed", "under_review", "certified"] do
        certify("strict_correction", s, "authority:data_governance_board")
      end

      assert {:ok, r} =
               update("strict_correction", :correction,
                 description: "Typo fixed",
                 evidence: "Fixing a typo"
               )

      row = hd(r.data)
      assert row.status == "pending_review"
      assert row.change_type == :correction

      after_update = resolve("strict_correction")
      assert after_update.description == "Original description"
      assert after_update.certification_status == "contested"
      assert after_update.certified == false
    end

    test "refresh on certified entity transitions to contested (pending review)" do
      assert_fixture("strict_refresh")

      for s <- ["proposed", "under_review", "certified"] do
        certify("strict_refresh", s, "authority:data_governance_board")
      end

      assert {:ok, r} =
               update("strict_refresh", :refresh,
                 description: "Refreshed copy",
                 evidence: "Re-validated source"
               )

      row = hd(r.data)
      assert row.status == "pending_review"
      assert row.change_type == :refresh

      after_update = resolve("strict_refresh")
      assert after_update.description == "Original description"
      assert after_update.certification_status == "contested"
    end
  end

  describe "certification preservation policy — :standard (default)" do
    test "no config set behaves as :standard (correction preserves certification)" do
      assert Application.get_env(:cqr_mcp, :certification_preservation_policy) == nil

      assert_fixture("default_correction")

      for s <- ["proposed", "under_review", "certified"] do
        certify("default_correction", s, "authority:data_governance_board")
      end

      assert {:ok, r} =
               update("default_correction", :correction,
                 description: "Typo fixed",
                 evidence: "Fixing a typo"
               )

      assert hd(r.data).status == "applied"

      resolved = resolve("default_correction")
      assert resolved.description == "Typo fixed"
      assert resolved.certified == true
      assert resolved.certification_status == "certified"
    end

    test "explicit :standard: redefinition transitions to contested" do
      Application.put_env(:cqr_mcp, :certification_preservation_policy, :standard)
      on_exit(fn -> Application.delete_env(:cqr_mcp, :certification_preservation_policy) end)

      assert_fixture("standard_redef")

      for s <- ["proposed", "under_review", "certified"] do
        certify("standard_redef", s, "authority:data_governance_board")
      end

      assert {:ok, r} =
               update("standard_redef", :redefinition,
                 description: "New meaning",
                 evidence: "Semantic change"
               )

      assert hd(r.data).status == "pending_review"

      after_update = resolve("standard_redef")
      assert after_update.description == "Original description"
      assert after_update.certification_status == "contested"
    end
  end

  describe "certification preservation policy — :permissive" do
    setup do
      Application.put_env(:cqr_mcp, :certification_preservation_policy, :permissive)
      on_exit(fn -> Application.delete_env(:cqr_mcp, :certification_preservation_policy) end)
      :ok
    end

    test "redefinition on certified entity applies immediately, preserves certification" do
      assert_fixture("permissive_redef")

      for s <- ["proposed", "under_review", "certified"] do
        certify("permissive_redef", s, "authority:data_governance_board")
      end

      assert {:ok, r} =
               update("permissive_redef", :redefinition,
                 description: "Redefined meaning",
                 evidence: "Permissive policy allows it"
               )

      assert hd(r.data).status == "applied"

      resolved = resolve("permissive_redef")
      assert resolved.description == "Redefined meaning"
      assert resolved.certified == true
      assert resolved.certification_status == "certified"
    end

    test "reclassification on certified entity applies immediately, preserves certification" do
      assert_fixture("permissive_reclass")

      for s <- ["proposed", "under_review", "certified"] do
        certify("permissive_reclass", s, "authority:data_governance_board")
      end

      assert {:ok, r} =
               update("permissive_reclass", :reclassification,
                 description: "Reclassified",
                 evidence: "Permissive policy allows it"
               )

      assert hd(r.data).status == "applied"

      resolved = resolve("permissive_reclass")
      assert resolved.description == "Reclassified"
      assert resolved.certified == true
      assert resolved.certification_status == "certified"
    end
  end

  describe "UTF-8 round-trip through JSON serialization" do
    # Regression for: UPDATE on a certified entity with a multi-byte UTF-8
    # description used to produce a response that Claude Desktop's JSON
    # parser rejected with "Bad escaped character in JSON at position N",
    # causing the MCP call to time out. Two bugs collided:
    #
    #   1. The CQR parser used `ascii_string` for DESCRIPTION/EVIDENCE,
    #      bytewise-Latin-1-decoding every UTF-8 byte and re-encoding as
    #      UTF-8 — turning `—` (0xE2 0x80 0x94) into 6 bytes of mojibake.
    #   2. The MCP wire encoder emitted raw multi-byte UTF-8 in JSON, which
    #      Claude Desktop's stricter parser refuses.
    #
    # This test exercises the full ASSERT → CERTIFY → UPDATE path with a
    # large multi-byte description, then serializes via the same
    # Jason options the wire transports use (`escape: :unicode_safe`),
    # and round-trips the JSON to prove old + new descriptions survive
    # intact.
    test "ASSERT + CERTIFY + UPDATE preserves multi-byte UTF-8 in descriptions" do
      # Em-dash (—), en-dash (–), curly quotes (", ", ', '), ellipsis (…),
      # and accented letters (é, ñ). Every 3-byte sequence that the old
      # parser corrupted.
      original =
        "Metric — tracks churn (rolling 30‑day window). " <>
          "Don't confuse with the \u201Ccanonical\u201D definition — see policy. " <>
          "Accents: é ñ ü. Dashes: – —. Ellipsis: …"

      big_original = original |> List.duplicate(40) |> Enum.join(" / ")
      original_bytes = byte_size(big_original)
      assert original_bytes > 4000, "fixture must exceed the ~4KB threshold"

      assert_args = %{
        "entity" => "entity:test_update:utf8_roundtrip",
        "type" => "metric",
        "description" => big_original,
        "intent" => "Exercise UPDATE under UTF-8 load",
        "derived_from" => "entity:product:churn_rate"
      }

      assert {:ok, _} = CqrMcp.Tools.call("cqr_assert", assert_args, @product_context)

      for s <- ["proposed", "under_review", "certified"] do
        certify("utf8_roundtrip", s, "authority:data_governance_board")
      end

      new_desc =
        "Revised — now uses the 7‑day rolling window. " <>
          "Matches \u201Ccanonical\u201D doc. é ñ ü … – —"

      update_args = %{
        "entity" => "entity:test_update:utf8_roundtrip",
        "change_type" => "correction",
        "description" => new_desc,
        "evidence" => "Clarifying window length — see revised doc."
      }

      assert {:ok, result} =
               CqrMcp.Tools.call("cqr_update", update_args, @product_context)

      # Simulate the wire encoding used by both stdio and SSE transports.
      wire_json = Jason.encode!(result, escape: :unicode_safe)

      # Pure ASCII on the wire: every non-ASCII codepoint must be emitted
      # as a `\uXXXX` escape so strict JSON parsers (Claude Desktop's
      # included) never see a raw multi-byte sequence.
      assert Regex.match?(~r/^[\x00-\x7F]*$/, wire_json),
             "wire payload must be pure ASCII — got non-ASCII bytes"

      # Round-trip: decode the wire payload and verify old + new
      # descriptions survived intact, byte-for-byte.
      assert {:ok, decoded} = Jason.decode(wire_json)

      row = decoded["data"] |> hd()
      assert row["previous_description"] == big_original
      assert row["new_description"] == new_desc
      assert byte_size(row["previous_description"]) == original_bytes
      assert row["evidence"] == "Clarifying window length — see revised doc."
    end

    test "tool dispatch + Jason.encode!/2 produces decodable ASCII for large payloads" do
      # The `text` field path used by CqrMcp.Handler.handle_method("tools/call", …).
      # Uses the same inner `Jason.encode!(result, pretty: true)` and outer
      # `Jason.encode!(response, escape: :unicode_safe)` as the real stdio
      # transport. Proves the full MCP envelope stays decodable end-to-end
      # when the payload exceeds ~8KB with UTF-8 content.
      # Chunks joined by " / " — no trailing whitespace (sanitize_quoted
      # in CqrMcp.Tools trims it, which would otherwise shrink the payload
      # by one byte).
      chunk = "dogs — cats – é ñ ü … \u201Cquoted\u201D"
      big = chunk |> List.duplicate(300) |> Enum.join(" / ")

      assert {:ok, _} =
               CqrMcp.Tools.call(
                 "cqr_assert",
                 %{
                   "entity" => "entity:test_update:utf8_envelope",
                   "type" => "metric",
                   "description" => big,
                   "intent" => "Envelope round-trip test",
                   "derived_from" => "entity:product:churn_rate"
                 },
                 @product_context
               )

      for s <- ["proposed", "under_review", "certified"] do
        certify("utf8_envelope", s, "authority:data_governance_board")
      end

      assert {:ok, result} =
               CqrMcp.Tools.call(
                 "cqr_update",
                 %{
                   "entity" => "entity:test_update:utf8_envelope",
                   "change_type" => "correction",
                   "description" => "Shorter revision — é",
                   "evidence" => "trim"
                 },
                 @product_context
               )

      inner_text = Jason.encode!(result, pretty: true)

      envelope = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => %{
          "content" => [%{"type" => "text", "text" => inner_text}]
        }
      }

      wire = Jason.encode!(envelope, escape: :unicode_safe)
      assert Regex.match?(~r/^[\x00-\x7F]*$/, wire)

      {:ok, decoded} = Jason.decode(wire)
      text = decoded["result"]["content"] |> hd() |> Map.fetch!("text")
      {:ok, inner} = Jason.decode(text)

      assert inner["data"] |> hd() |> Map.fetch!("previous_description") == big
    end
  end

  describe "validation" do
    test "UPDATE without CHANGE_TYPE fails with missing_required_field" do
      assert_fixture("missing_ct")

      # Parse-level: bare UPDATE with no CHANGE_TYPE clause yields a
      # struct whose change_type is nil; the engine validator surfaces
      # the missing-field error.
      assert {:ok, ast} = Cqr.Parser.parse("UPDATE entity:test_update:missing_ct")
      assert ast.change_type == nil

      assert {:error, err} = Engine.execute(ast, @product_context)
      assert err.code == :missing_required_field
      assert err.message =~ "CHANGE_TYPE"
    end
  end
end
