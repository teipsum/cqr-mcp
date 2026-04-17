defmodule Cqr.Grafeo.Gql do
  @moduledoc """
  Free-text escaping for single-quoted GQL/Cypher string literals.

  The embedded Grafeo parser will wedge on malformed single-quoted
  literals; an unescaped backslash, a raw newline, or a stray C0 control
  byte can leave the dirty scheduler thread spinning long enough that
  any subsequent NIF call backs up behind an internal lock. Every write
  path that interpolates user-controlled text into a GQL string MUST
  route it through `escape/1`.

  This is the single source of truth — `Cqr.Adapter.Grafeo`,
  `Cqr.Engine.Certify`, `Cqr.Repo.Semantic`, and `Cqr.Repo.Seed` all
  call it. Duplicating the logic per module is how CERTIFY drifted
  back to a single-quote-only escape and started producing malformed
  writes for certified entities with large evidence or authority
  strings.
  """

  # C0 control bytes that have no valid encoding inside a GQL string
  # literal and that the parser does not recognise via a backslash
  # escape. Nulls, vertical tab, form feed, backspace, and friends are
  # dropped outright — keeping them would trade a hang for a silent
  # truncation, which is strictly worse.
  @stripped_controls Enum.to_list(0x00..0x08) ++
                       [0x0B, 0x0C] ++
                       Enum.to_list(0x0E..0x1F) ++
                       [0x7F]

  @doc """
  Escape `value` for safe interpolation into a single-quoted GQL string
  literal.

  Handles the four classes the parser actually cares about:

    * backslash — escaped to `\\\\` so the parser does not start a new
      escape sequence in the middle of user content
    * single quote — escaped to `\\'` so the string does not close early
    * `\\n`, `\\r`, `\\t` — emitted as the backslash-letter forms the
      parser accepts; raw control bytes here used to wedge writes with
      multi-line descriptions
    * other C0 controls and DEL — stripped; these have no supported
      escape in the GQL literal grammar and a literal byte can crash or
      hang the parser depending on the build

  Order matters: backslashes are handled first so escape sequences
  introduced in later passes (`\\'`, `\\n`, ...) are not themselves
  re-escaped. `nil` and non-binary values coerce through `to_string/1`
  for ergonomic caller code.
  """
  @spec escape(term()) :: String.t()
  def escape(nil), do: ""

  def escape(str) when is_binary(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
    |> strip_controls()
  end

  def escape(other), do: escape(to_string(other))

  defp strip_controls(str) do
    for <<byte <- str>>, byte not in @stripped_controls, into: <<>>, do: <<byte>>
  end
end
