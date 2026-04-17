defmodule Cqr.Integration.NifHangRegressionTest do
  @moduledoc """
  Regression coverage for the DirtyIo NIF hang triggered by unescaped
  free-text fields in GQL writes.

  The prior `escape/1` only substituted the single quote, which left
  backslashes, newlines, carriage returns, and tabs raw inside the
  single-quoted literal. A 4-5 KB description pulled from source code or
  a log line almost always carried one of those characters, which
  produced malformed GQL and wedged the Rust parser on the DirtyIo
  scheduler — the entire embedded server had to be restarted to recover.

  The second wave of the same bug lived in `Cqr.Engine.Certify.escape/1`,
  which was still single-quote-only after the adapter was fixed. Every
  CertificationRecord written with a backslash or newline in authority or
  evidence produced malformed nodes; a subsequent UPDATE redefinition on
  the same entity (which writes the full previous-description snapshot
  into a VersionRecord plus the proposed description in a single INSERT
  of ~2× the original payload) was the trigger that finally wedged the
  NIF.

  These tests exercise the full parser → engine → adapter → NIF write
  path with payloads that would have hit either bug, plus the read
  path (RESOLVE on a missing entity) that used to queue behind the
  wedged mailbox, plus the full ASSERT → CERTIFY(×3) → UPDATE
  redefinition lifecycle on a hierarchical entity — the shape that
  reproduced the original report.

  The CQR parser uses `"` as the DESCRIPTION/EVIDENCE delimiter, so
  payloads here deliberately avoid literal double quotes — the bug
  lived downstream of the parser, in the adapter's GQL construction.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine
  alias Cqr.Grafeo.Codec
  alias Cqr.Grafeo.Gql
  alias Cqr.Grafeo.Server, as: GrafeoServer

  @product_context %{scope: ["company", "product"], agent_id: "twin:nif_hang"}

  @namespace "test_nif_hang"

  setup do
    cleanup()
    on_exit(&cleanup/0)
    :ok
  end

  defp cleanup do
    GrafeoServer.query("MATCH (e:Entity {namespace: '#{@namespace}'})-[r]-() DELETE r")
    GrafeoServer.query("MATCH (e:Entity {namespace: '#{@namespace}'}) DELETE e")

    GrafeoServer.query("MATCH (e:Entity {namespace: '#{@namespace}:patent'})-[r]-() DELETE r")

    GrafeoServer.query("MATCH (e:Entity {namespace: '#{@namespace}:patent'}) DELETE e")
    GrafeoServer.query("MATCH (r:AssertionRecord {entity_namespace: '#{@namespace}'}) DELETE r")
    GrafeoServer.query("MATCH (r:VersionRecord {entity_namespace: '#{@namespace}'}) DELETE r")

    GrafeoServer.query(
      "MATCH (r:VersionRecord {entity_namespace: '#{@namespace}:patent'}) DELETE r"
    )

    GrafeoServer.query(
      "MATCH (r:CertificationRecord {entity_namespace: '#{@namespace}'}) DELETE r"
    )

    GrafeoServer.query(
      "MATCH (r:CertificationRecord {entity_namespace: '#{@namespace}:patent'}) DELETE r"
    )

    :ok
  end

  # Build a payload of ~`size` bytes that contains every character
  # class the escape pipeline must survive: the four classes the old
  # adapter escape fumbled (backslash, embedded single quotes, raw
  # newlines/CRLFs/tabs), UTF-8 punctuation (em-dash, curly quotes),
  # and the full ASCII punctuation set the user flagged as suspect —
  # `$ ~ ( ) / + : * # @ % | [ ] { } < > ; ! ? & = ^`. Double quotes
  # are intentionally omitted so the CQR parser can carry the payload
  # unchanged to the adapter. A 5 KB payload of pure ASCII text
  # would not have reproduced the hang — the bug needed the unescaped
  # metacharacters.
  defp nasty_payload(size) do
    chunk =
      "Path: C:\\Users\\alice\\notes.txt — she said 'don't forget' " <>
        "and it's important.\n\tIndented line with \r\n CRLF.\n" <>
        "Smart quotes: \u201cHello\u201d \u2018world\u2019 and em-dash — here.\n" <>
        "Money $99.95 ~ about 100 USD; rate is +3.5% (approx).\n" <>
        "Path /usr/local/bin/app with flags -Xmx2g @config.yml #tag %02d\n" <>
        "Regex [a-z]+ and glob *.ex* and brace {x,y} and <tag> and </tag>\n" <>
        "Email user@example.com ref #123 && check a|b or a=b; ^caret! ok? 42.\n"

    [chunk]
    |> Stream.cycle()
    |> Enum.reduce_while("", fn part, acc ->
      next = acc <> part
      if byte_size(next) >= size, do: {:halt, next}, else: {:cont, next}
    end)
  end

  describe "ASSERT with large payloads" do
    for {label, size} <- [{"5kb", 5_000}, {"10kb", 10_000}] do
      test "completes within timeout for a #{label} description with metacharacters" do
        name = "assert_#{unquote(label)}"
        payload = nasty_payload(unquote(size))

        expr =
          ~s(ASSERT entity:#{@namespace}:#{name} TYPE derived_metric ) <>
            ~s(DESCRIPTION "#{payload}" ) <>
            ~s(INTENT "Regression coverage for NIF hang" ) <>
            ~s(DERIVED_FROM entity:product:churn_rate)

        # Bounded wall-clock: a hung NIF used to block indefinitely. Any
        # value well under the configured NIF timeout proves the write
        # path, not the timeout wrapper, finished the work.
        assert_completes_within(5_000, fn ->
          assert {:ok, result} = Engine.execute(expr, @product_context)
          assert [%{description: ^payload}] = result.data
        end)

        # Round-trip through RESOLVE so we know the description was
        # stored faithfully, not silently truncated or mojibake'd.
        assert_completes_within(5_000, fn ->
          assert {:ok, resolved} =
                   Engine.execute(
                     "RESOLVE entity:#{@namespace}:#{name}",
                     @product_context
                   )

          assert [%{description: ^payload}] = resolved.data
        end)
      end
    end
  end

  describe "UPDATE with large payloads" do
    for {label, size} <- [{"5kb", 5_000}, {"10kb", 10_000}] do
      test "applies a #{label} description over an existing entity" do
        name = "update_#{unquote(label)}"
        original = "Original seed description"
        new_payload = nasty_payload(unquote(size))

        # Seed the entity with a small description so UPDATE has
        # somewhere to write the previous snapshot.
        seed_expr =
          ~s(ASSERT entity:#{@namespace}:#{name} TYPE derived_metric ) <>
            ~s(DESCRIPTION "#{original}" ) <>
            ~s(INTENT "Seed for UPDATE regression" ) <>
            ~s(DERIVED_FROM entity:product:churn_rate)

        assert {:ok, _} = Engine.execute(seed_expr, @product_context)

        # UPDATE doubles the wire payload because the VersionRecord
        # captures the previous description alongside the entity's new
        # description. The old bug fired at ~4-5 KB so the 10 KB case
        # is the real stress test.
        update_expr =
          ~s(UPDATE entity:#{@namespace}:#{name} CHANGE_TYPE correction ) <>
            ~s(DESCRIPTION "#{new_payload}" ) <>
            ~s(EVIDENCE "Regression evidence with 'quotes' and backslashes \\path\\to\\file")

        assert_completes_within(5_000, fn ->
          assert {:ok, _} = Engine.execute(update_expr, @product_context)
        end)

        assert_completes_within(5_000, fn ->
          assert {:ok, resolved} =
                   Engine.execute(
                     "RESOLVE entity:#{@namespace}:#{name}",
                     @product_context
                   )

          assert [%{description: ^new_payload}] = resolved.data
        end)
      end
    end
  end

  describe "certified-entity redefinition lifecycle on a hierarchical address" do
    # Reproduces the shape the user reported: a hierarchical entity
    # (e.g. entity:agent:patent_agent:bootstrap) that has been walked
    # through the full proposed → under_review → certified lifecycle
    # with free-text AUTHORITY and EVIDENCE, then receives an UPDATE
    # redefinition carrying a 5 KB+ payload. The :standard certification
    # preservation policy routes a redefinition on a certified entity
    # through the :pending_review write path, which emits a single
    # INSERT whose body contains both the previous description and the
    # proposed description — that ~2× payload is the fingerprint of
    # the production hang. This test MUST complete well inside the 30 s
    # NIF timeout; a failure here is a real regression.
    test "full ASSERT + 3× CERTIFY + UPDATE redefinition completes under 30s" do
      name = "bootstrap"
      ns = "#{@namespace}:patent"
      entity_ref = "entity:#{ns}:#{name}"

      original = nasty_payload(5_200)
      redefinition = nasty_payload(5_200) <> " (revision 2)"
      long_evidence = "Board review notes:\n" <> nasty_payload(2_000)

      assert_completes_within(30_000, fn ->
        # ASSERT with the hierarchical address. The adapter cascades
        # a container entity for `#{@namespace}:patent` as part of this
        # write, which exercises the multi-ancestor write path.
        assert {:ok, _} =
                 Engine.execute(
                   ~s(ASSERT #{entity_ref} TYPE derived_metric ) <>
                     ~s(DESCRIPTION "#{original}" ) <>
                     ~s(INTENT "Hierarchical regression fixture" ) <>
                     ~s(DERIVED_FROM entity:product:churn_rate),
                   @product_context
                 )

        # proposed → under_review → certified. Each CERTIFY writes a
        # CertificationRecord whose evidence and authority previously
        # bypassed the shared escape function.
        for status <- ["proposed", "under_review", "certified"] do
          assert {:ok, _} =
                   Engine.execute(
                     ~s(CERTIFY #{entity_ref} STATUS #{status} ) <>
                       ~s(AUTHORITY "authority:review_board:stage:#{status}" ) <>
                       ~s(EVIDENCE "#{long_evidence}"),
                     @product_context
                   )
        end

        # Redefinition on a certified entity — routes through the
        # :pending_review path, which writes a VersionRecord holding
        # both `previous_description` (~5 KB) and `proposed_description`
        # (~5 KB) in a single INSERT. This is the worst-case stress
        # test the production bug triggered.
        assert {:ok, _} =
                 Engine.execute(
                   ~s(UPDATE #{entity_ref} CHANGE_TYPE redefinition ) <>
                     ~s(DESCRIPTION "#{redefinition}" ) <>
                     ~s(EVIDENCE "#{long_evidence}"),
                   @product_context
                 )
      end)

      # Post-lifecycle sanity: a simple RESOLVE on an unrelated entity
      # must still return promptly. If the Grafeo NIF had wedged on any
      # of the writes above, this read would hang behind the stuck
      # dirty-scheduler thread.
      assert_completes_within(2_000, fn ->
        assert {:ok, _} =
                 Engine.execute(
                   "RESOLVE entity:product:churn_rate",
                   @product_context
                 )
      end)
    end
  end

  describe "round-trip fidelity for individual metacharacter classes" do
    # Each case isolates one character class so a future regression in
    # the escape function fingerprints precisely which escape pass broke.
    # (No literal double quotes — the parser would truncate the payload
    # before the adapter ever saw it, and that truncation is not what
    # this test exercises.)
    for {label, fragment} <- [
          {"single_quote", "it's a careful word"},
          {"backslash", "path C:\\Users\\Alice\\file.txt"},
          {"newline", "line one\nline two\nline three"},
          {"crlf", "carriage\r\nreturn"},
          {"tab", "col\ta\tcol\tb"},
          {"em_dash", "clause one — clause two"},
          {"curly_quotes", "\u201csmart\u201d \u2018quotes\u2019"},
          {"trailing_backslash", "ends with a backslash\\"},
          {"mixed", "it's\nC:\\tmp\\log — \u201chello\u201d"},
          {"shell_metas", "cmd $VAR ~ok /path * & | ; < > ="},
          {"brackets_braces", "[a] {b} (c) <d> matches"},
          {"punctuation_misc", "rate +3% @home #42 ?maybe !sure ^caret"}
        ] do
      test "ASSERT round-trips #{label}" do
        name = "rt_#{unquote(label)}"
        payload = unquote(fragment)

        expr =
          ~s(ASSERT entity:#{@namespace}:#{name} TYPE derived_metric ) <>
            ~s(DESCRIPTION "#{payload}" ) <>
            ~s(INTENT "Regression for #{unquote(label)}" ) <>
            ~s(DERIVED_FROM entity:product:churn_rate)

        assert {:ok, _} = Engine.execute(expr, @product_context)

        assert {:ok, resolved} =
                 Engine.execute(
                   "RESOLVE entity:#{@namespace}:#{name}",
                   @product_context
                 )

        assert [%{description: ^payload}] = resolved.data
      end
    end
  end

  describe "Cqr.Grafeo.Gql.escape/1" do
    # Unit coverage for the shared escape function. The write-path
    # regression tests above exercise it end-to-end; these pin the
    # contract so a future refactor that broadened the strip set (or
    # rolled back to single-quote-only) trips immediately.
    test "escapes backslash, single quote, and C0 whitespace escapes" do
      assert Gql.escape("a'b\\c\nd\re\tf") == "a\\'b\\\\c\\nd\\re\\tf"
    end

    test "drops null bytes and other C0 controls including DEL" do
      raw = <<"a", 0x00, "b", 0x01, "c", 0x08, "d", 0x0B, "e", 0x1F, "f", 0x7F, "g">>
      assert Gql.escape(raw) == "abcdefg"
    end

    test "preserves multibyte UTF-8 sequences" do
      # em-dash (U+2014), curly-quote (U+201C), CJK — all multibyte,
      # none should touch the C0 strip pass.
      assert Gql.escape("— \u201chi\u201d 日") == "— \u201chi\u201d 日"
    end

    test "coerces nil to empty and other terms via to_string/1" do
      assert Gql.escape(nil) == ""
      assert Gql.escape(42) == "42"
      assert Gql.escape(:atom_value) == "atom_value"
    end
  end

  describe "RESOLVE on missing entity" do
    test "returns entity_not_found without timing out" do
      # Before the fix a prior hung write would wedge the server, so even
      # a trivial miss would queue behind it forever. With the escape
      # fix and the Task-based NIF timeout the miss should surface as
      # an error in well under a second.
      assert_completes_within(2_000, fn ->
        assert {:error, err} =
                 Engine.execute(
                   "RESOLVE entity:#{@namespace}:does_not_exist",
                   @product_context
                 )

        assert err.code == :entity_not_found
      end)
    end

    test "returns entity_not_found even after a large-payload ASSERT in the same session" do
      payload = nasty_payload(6_000)

      expr =
        ~s(ASSERT entity:#{@namespace}:warmup TYPE derived_metric ) <>
          ~s(DESCRIPTION "#{payload}" ) <>
          ~s(INTENT "Warm the server before the miss" ) <>
          ~s(DERIVED_FROM entity:product:churn_rate)

      assert {:ok, _} = Engine.execute(expr, @product_context)

      assert_completes_within(2_000, fn ->
        assert {:error, err} =
                 Engine.execute(
                   "RESOLVE entity:#{@namespace}:still_missing",
                   @product_context
                 )

        assert err.code == :entity_not_found
      end)
    end
  end

  describe "Cqr.Grafeo.Server.run_with_timeout/2" do
    # The timeout wrapper is the last line of defence if a malformed
    # query slips past the escape pipeline. These tests pin the
    # contract without relying on an actually-hung NIF, so the
    # regression surface stays observable even if the NIF's behaviour
    # under pathological input changes over time.
    test "returns :nif_timeout when the callable exceeds the budget" do
      assert {:error, :nif_timeout} =
               GrafeoServer.run_with_timeout(50, fn ->
                 Process.sleep(500)
                 :should_not_be_returned
               end)
    end

    test "returns the callable's value when it finishes inside the budget" do
      assert {:ok, 7} = GrafeoServer.run_with_timeout(500, fn -> {:ok, 7} end)
      assert :done = GrafeoServer.run_with_timeout(500, fn -> :done end)
    end
  end

  describe "base64 codec — full-Unicode payload stress" do
    # The codec keeps every free-text byte out of the GQL literal by
    # base64-encoding on the way in and decoding on the way out
    # (see `Cqr.Grafeo.Codec`). These tests cover the character
    # classes the task required: ASCII metachars, Latin-1, CJK, emoji,
    # math symbols, Arabic, and Hebrew — any one of which would have
    # tripped the old escape-only pipeline. The 10 KB payload exercises
    # the worst-case UPDATE-on-certified path that writes two copies
    # of the description into a single VersionRecord INSERT.
    test "10KB all-Unicode ASSERT + CERTIFY + UPDATE redefinition completes under 30s" do
      name = "unicode_lifecycle"
      ns = "#{@namespace}:patent"
      entity_ref = "entity:#{ns}:#{name}"
      payload = unicode_payload(10_000)
      evidence = "Review — " <> unicode_payload(1_500)

      assert_completes_within(30_000, fn ->
        assert {:ok, assert_result} =
                 Engine.execute(
                   ~s(ASSERT #{entity_ref} TYPE derived_metric ) <>
                     ~s(DESCRIPTION "#{payload}" ) <>
                     ~s(INTENT "Unicode lifecycle regression" ) <>
                     ~s(DERIVED_FROM entity:product:churn_rate),
                   @product_context
                 )

        assert [%{description: ^payload, intent: "Unicode lifecycle regression"}] =
                 assert_result.data

        for status <- ["proposed", "under_review", "certified"] do
          assert {:ok, _} =
                   Engine.execute(
                     ~s(CERTIFY #{entity_ref} STATUS #{status} ) <>
                       ~s(AUTHORITY "authority:review_board — é" ) <>
                       ~s(EVIDENCE "#{evidence}"),
                     @product_context
                   )
        end

        # Redefinition on a certified entity — pending_review path
        # writes both previous and proposed descriptions in a single
        # INSERT, roughly 2× the payload size on one statement.
        assert {:ok, _} =
                 Engine.execute(
                   ~s(UPDATE #{entity_ref} CHANGE_TYPE redefinition ) <>
                     ~s(DESCRIPTION "#{payload} revision" ) <>
                     ~s(EVIDENCE "#{evidence}"),
                   @product_context
                 )
      end)

      # Redefinition on a certified entity under the :standard policy
      # routes through pending_review — the entity's description is
      # NOT applied, the revision lives only on the VersionRecord. The
      # fidelity check is therefore against the original payload.
      assert {:ok, resolved} =
               Engine.execute(
                 "RESOLVE #{entity_ref}",
                 @product_context
               )

      assert [%{description: description}] = resolved.data
      assert description == payload
    end

    test "CERTIFY authority and evidence with special characters round-trip through TRACE" do
      name = "cert_special"
      entity_ref = "entity:#{@namespace}:#{name}"
      authority = "authority:board — é ñ ü 'quoted' and \\backslash"
      evidence = "Evidence: é ∑ 日 🚀"

      assert {:ok, _} =
               Engine.execute(
                 ~s(ASSERT #{entity_ref} TYPE derived_metric ) <>
                   ~s(DESCRIPTION "seed" ) <>
                   ~s(INTENT "cert special regression" ) <>
                   ~s(DERIVED_FROM entity:product:churn_rate),
                 @product_context
               )

      assert {:ok, _} =
               Engine.execute(
                 ~s(CERTIFY #{entity_ref} STATUS proposed ) <>
                   ~s(AUTHORITY "#{authority}" ) <>
                   ~s(EVIDENCE "#{evidence}"),
                 @product_context
               )

      assert {:ok, trace_result} =
               Engine.execute(
                 "TRACE #{entity_ref}",
                 @product_context
               )

      [row] = trace_result.data
      [cert | _] = row.certification_history
      assert cert.authority == authority
      assert cert.evidence == evidence
    end

    test "SIGNAL evidence with special characters round-trips via TRACE signal_history" do
      name = "signal_special"
      entity_ref = "entity:#{@namespace}:#{name}"
      evidence = "Signal — é ñ 日 'quoted' with \\backslash"

      assert {:ok, _} =
               Engine.execute(
                 ~s(ASSERT #{entity_ref} TYPE derived_metric ) <>
                   ~s(DESCRIPTION "seed" ) <>
                   ~s(INTENT "signal special regression" ) <>
                   ~s(DERIVED_FROM entity:product:churn_rate),
                 @product_context
               )

      assert {:ok, _} =
               Engine.execute(
                 ~s(SIGNAL reputation ON #{entity_ref} SCORE 0.7 EVIDENCE "#{evidence}"),
                 @product_context
               )

      assert {:ok, trace_result} =
               Engine.execute(
                 "TRACE #{entity_ref}",
                 @product_context
               )

      [row] = trace_result.data
      [signal | _] = row.signal_history
      assert signal.evidence == evidence
    end

    test "DISCOVER search surfaces entities by decoded description keyword" do
      name = "unicode_findable"
      payload = "Uniqueneedlephrase " <> unicode_payload(500) <> " haystack"

      assert {:ok, _} =
               Engine.execute(
                 ~s(ASSERT entity:#{@namespace}:#{name} TYPE derived_metric ) <>
                   ~s(DESCRIPTION "#{payload}" ) <>
                   ~s(INTENT "DISCOVER coverage" ) <>
                   ~s(DERIVED_FROM entity:product:churn_rate),
                 @product_context
               )

      assert {:ok, result} =
               Engine.execute(
                 ~s(DISCOVER concepts RELATED TO "Uniqueneedlephrase"),
                 @product_context
               )

      assert Enum.any?(result.data, fn row ->
               row[:entity] == {@namespace, name}
             end)
    end

    test "legacy raw description (no b64: sentinel) still reads through RESOLVE" do
      # Simulate a pre-codec entity by writing raw text directly via GQL.
      # `decode/1` passes values missing the `b64:` sentinel through
      # unchanged, so pre-migration rows keep reading correctly.
      name = "legacy_raw"
      raw_description = "Raw legacy description"

      assert {:ok, _} =
               GrafeoServer.query(
                 "INSERT (:Entity {namespace: '#{@namespace}', name: '#{name}', " <>
                   "type: 'container', " <>
                   "description: '#{raw_description}', " <>
                   "certified: false, confidence: 1.0, " <>
                   "asserted_by: 'legacy_seed', asserted_at: '2026-01-01T00:00:00Z', " <>
                   "intent: 'legacy intent', owner: 'legacy_seed', " <>
                   "reputation: 0.5, freshness_hours_ago: 0, embedding: []})"
               )

      assert {:ok, _} =
               GrafeoServer.query(
                 "MATCH (e:Entity {namespace: '#{@namespace}', name: '#{name}'}), " <>
                   "(s:Scope {path: 'company:product'}) " <>
                   "INSERT (e)-[:IN_SCOPE {primary: true}]->(s)"
               )

      assert {:ok, resolved} =
               Engine.execute(
                 "RESOLVE entity:#{@namespace}:#{name}",
                 @product_context
               )

      assert [%{description: ^raw_description}] = resolved.data
    end

    test "RESOLVE on a non-existent entity returns entity_not_found within 1 second" do
      assert_completes_within(1_000, fn ->
        assert {:error, err} =
                 Engine.execute(
                   "RESOLVE entity:#{@namespace}:never_written",
                   @product_context
                 )

        assert err.code == :entity_not_found
      end)
    end

    # The codec decodes the empty string to the empty string (rather
    # than treating it as the `b64:` sentinel with an empty payload),
    # so fields like `Codec.decode` stay safe to call on every row a
    # query returns. Proves the encoder never expands `""` into a
    # sentinel that would collide with a legitimately empty value.
    test "Cqr.Grafeo.Codec handles nil, empty, and round-trips arbitrary UTF-8" do
      assert Codec.encode(nil) == ""
      assert Codec.encode("") == ""
      assert Codec.decode(nil) == nil
      assert Codec.decode("") == ""

      for value <- [
            "plain ASCII",
            "em-dash — and \u201Cquotes\u201D",
            "CJK 日本語 and emoji 🚀",
            "backslash \\ quote ' newline \n tab \t"
          ] do
        assert value |> Codec.encode() |> Codec.decode() == value
      end
    end
  end

  # Build a 10 KB+ payload with every Unicode class required by the
  # base64 codec regression spec: ASCII metacharacters, Latin-1
  # supplement, CJK, emoji, mathematical symbols, Arabic, Hebrew.
  # Pure-ASCII payloads never reproduced the NIF hang; the bug required
  # one of the unescaped classes below.
  defp unicode_payload(target_bytes) do
    chunk =
      "ASCII meta: $~()/+:*#@%|[]{}<>;!?&=^ — " <>
        "Latin-1: café naïve résumé — " <>
        "CJK: 日本語 中文 한국어 — " <>
        "emoji: 🚀💥✨🎯 — " <>
        "math: ∑∫∂∆ ≠ ≤ ≥ ∞ π — " <>
        "Arabic: مرحبا بالعالم — " <>
        "Hebrew: שלום עולם — " <>
        "path: C:\\Users\\alice\\notes.txt, it's 'quoted'\n\ttab and CRLF\r\n"

    [chunk]
    |> Stream.cycle()
    |> Enum.reduce_while("", fn part, acc ->
      next = acc <> part
      if byte_size(next) >= target_bytes, do: {:halt, next}, else: {:cont, next}
    end)
  end

  # Run `fun` inside a Task so we can surface a hang as a plain test
  # failure instead of waiting for the ExUnit case timeout. The outer
  # budget for most cases is 5 s (well inside the configured NIF
  # timeout of 30 s), so we are testing the write path, not the
  # timeout wrapper. The certified-entity lifecycle test uses a
  # 30 s budget because the specific production hang was reported
  # at "hangs indefinitely past 30 seconds".
  defp assert_completes_within(timeout_ms, fun) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} ->
        value

      nil ->
        flunk("operation did not complete within #{timeout_ms}ms — probable NIF hang")
    end
  end
end
