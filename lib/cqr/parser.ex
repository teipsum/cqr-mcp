defmodule Cqr.Parser do
  @moduledoc """
  Top-level CQR expression parser.

  Parses CQR expressions (RESOLVE, DISCOVER, CERTIFY) from string input
  into structured ASTs. Uses NimbleParsec for the PEG grammar implementation.

  ## Usage

      iex> Cqr.Parser.parse("RESOLVE entity:finance:arr")
      {:ok, %Cqr.Resolve{entity: {"finance", "arr"}}}

      iex> Cqr.Parser.parse("INVALID")
      {:error, %Cqr.Error{code: :parse_error, ...}}

  See PROJECT_KNOWLEDGE.md Section 5 for the formal grammar.
  """

  import NimbleParsec

  alias Cqr.Parser.{Anchor, Assert, Certify, Discover, Refresh, Resolve, Signal, Trace}

  defparsec(
    :parse_expression,
    choice([
      Resolve.resolve(),
      Discover.discover(),
      Certify.certify(),
      Assert.assert_expression(),
      Trace.trace(),
      Signal.signal(),
      Refresh.refresh(),
      Anchor.anchor()
    ])
    |> eos()
  )

  @doc """
  Parse a CQR expression string into an AST struct.

  Returns `{:ok, ast}` on success or `{:error, %Cqr.Error{}}` on failure.
  """
  def parse(input) when is_binary(input) do
    input = String.trim(input)

    case parse_expression(input) do
      {:ok, [result], "", _, _, _} ->
        {:ok, result}

      {:error, message, rest, _, {_line, _offset}, byte_offset} ->
        {:error,
         Cqr.Error.parse_error(
           format_error(message, input, byte_offset),
           position: byte_offset,
           expected: extract_expected(message),
           retry_guidance: suggest_fix(rest, input)
         )}
    end
  end

  def parse(_), do: {:error, Cqr.Error.parse_error("Input must be a string")}

  defp format_error(message, input, byte_offset) do
    context =
      if byte_offset > 0 do
        parsed = String.slice(input, 0, byte_offset)
        remaining = String.slice(input, byte_offset, 30)

        "Parse error at position #{byte_offset}: #{message}. Parsed so far: \"#{parsed}\", stuck at: \"#{remaining}...\""
      else
        "Parse error at start: #{message}"
      end

    context
  end

  defp extract_expected(message) when is_binary(message) do
    # NimbleParsec error messages contain "expected ..." patterns
    case Regex.scan(~r/expected (.+?)(?:\s+while|$)/, message) do
      [] -> [message]
      matches -> Enum.map(matches, fn [_, expected] -> expected end)
    end
  end

  defp extract_expected(message), do: [inspect(message)]

  defp suggest_fix(rest, _input) when rest == "" or rest == nil do
    "Expression ended unexpectedly. Check for missing required clauses."
  end

  defp suggest_fix(rest, _input) do
    cond do
      String.starts_with?(rest, "RESOLV") ->
        "Did you mean RESOLVE?"

      String.starts_with?(rest, "DISCOV") ->
        "Did you mean DISCOVER?"

      String.starts_with?(rest, "CERTIF") ->
        "Did you mean CERTIFY?"

      String.starts_with?(rest, "ASSER") ->
        "Did you mean ASSERT?"

      String.starts_with?(rest, "TRAC") ->
        "Did you mean TRACE?"

      String.starts_with?(rest, "SIGNA") ->
        "Did you mean SIGNAL?"

      String.starts_with?(rest, "REFRES") ->
        "Did you mean REFRESH?"

      String.starts_with?(rest, "ANCHO") ->
        "Did you mean ANCHOR?"

      true ->
        "Expression must start with RESOLVE, DISCOVER, CERTIFY, ASSERT, TRACE, SIGNAL, REFRESH, or ANCHOR. Unexpected: \"#{String.slice(rest, 0, 20)}\""
    end
  end
end
