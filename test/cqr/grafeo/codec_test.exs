defmodule Cqr.Grafeo.CodecTest do
  @moduledoc """
  Unit coverage for the base64 codec. Integration-level round trips
  through the full ASSERT → RESOLVE pipeline live in
  `test/integration/nif_hang_regression_test.exs`; these tests pin the
  encoder/decoder contract in isolation.
  """

  use ExUnit.Case, async: true

  alias Cqr.Grafeo.Codec

  describe "encode/1" do
    test "returns the empty string for nil and empty input" do
      assert Codec.encode(nil) == ""
      assert Codec.encode("") == ""
    end

    test "wraps a non-empty binary with the b64: sentinel" do
      encoded = Codec.encode("hello")
      assert encoded == "b64:" <> Base.encode64("hello")
    end

    test "produces GQL-safe output (no single quote, backslash, newline, or C0 controls)" do
      payload =
        "it's \\ newline\nCRLF\r\n tab\t null\0 DEL\x7F " <>
          "smart \u201cquotes\u201d — em-dash and CJK 日本語"

      encoded = Codec.encode(payload)
      body = String.trim_leading(encoded, "b64:")

      assert Regex.match?(~r|\A[A-Za-z0-9+/=]*\z|, body)
    end

    test "coerces non-binary terms via to_string/1" do
      assert Codec.encode(42) == "b64:" <> Base.encode64("42")
      assert Codec.encode(:some_atom) == "b64:" <> Base.encode64("some_atom")
    end
  end

  describe "decode/1" do
    test "preserves nil and empty-string absence" do
      assert Codec.decode(nil) == nil
      assert Codec.decode("") == ""
    end

    test "round-trips arbitrary UTF-8 payloads" do
      for payload <- [
            "plain ASCII",
            "it's \\ quoted, with newlines\nand tabs\t",
            "smart \u201cquotes\u201d — em-dash",
            "CJK 日本語 and emoji 🚀💥",
            "Arabic مرحبا and Hebrew שלום",
            "math ∑∫∂∆ and currency €£¥"
          ] do
        assert payload |> Codec.encode() |> Codec.decode() == payload
      end
    end

    test "returns legacy raw descriptions unchanged (no sentinel → pass-through)" do
      assert Codec.decode("Annual Recurring Revenue") == "Annual Recurring Revenue"
      assert Codec.decode("Customer lifetime value") == "Customer lifetime value"
    end

    test "passes malformed base64 payload through as-is" do
      # A value that carries the sentinel but whose body does not
      # decode should be returned verbatim — the codec treats undecodable
      # content as opaque rather than raising.
      bogus = "b64:not valid base64!!!"
      assert Codec.decode(bogus) == bogus
    end

    test "non-binary terms pass through (the codec only operates on strings)" do
      assert Codec.decode(42) == 42
      assert Codec.decode([1, 2, 3]) == [1, 2, 3]
    end
  end
end
