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

  These tests exercise the full parser → engine → adapter → NIF write
  path with payloads that would have hit the old bug, plus the read
  path (RESOLVE on a missing entity) that used to queue behind the
  wedged mailbox.

  The CQR parser uses `"` as the DESCRIPTION/EVIDENCE delimiter, so
  payloads here deliberately avoid literal double quotes — the bug
  lived downstream of the parser, in the adapter's GQL construction.
  """

  use ExUnit.Case, async: false

  alias Cqr.Engine
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
    GrafeoServer.query("MATCH (r:AssertionRecord {entity_namespace: '#{@namespace}'}) DELETE r")
    GrafeoServer.query("MATCH (r:VersionRecord {entity_namespace: '#{@namespace}'}) DELETE r")
    :ok
  end

  # Build a payload of ~`size` bytes that contains every character class
  # the old escape fumbled: bare backslashes, embedded single quotes,
  # newlines, carriage returns, tabs, em-dash, and curly quotes. Double
  # quotes are intentionally omitted so the CQR parser can carry the
  # payload unchanged to the adapter. A 5 KB payload of pure ASCII text
  # would not have reproduced the hang — the bug needed the unescaped
  # metacharacters.
  defp nasty_payload(size) do
    chunk =
      "Path: C:\\Users\\alice\\notes.txt — she said 'don't forget' " <>
        "and it's important.\n\tIndented line with \r\n CRLF.\n" <>
        "Smart quotes: \u201cHello\u201d \u2018world\u2019 and em-dash — here.\n"

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
          {"mixed", "it's\nC:\\tmp\\log — \u201chello\u201d"}
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

  # Run `fun` inside a Task so we can surface a hang as a plain test
  # failure instead of waiting for the ExUnit case timeout. 5 s is
  # deliberately well inside the configured NIF timeout (30 s) so we
  # are testing the write path, not the timeout wrapper.
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
