defmodule Cqr.Grafeo.Codec do
  @moduledoc """
  Transparent base64 codec for free-text fields interpolated into GQL
  string literals.

  The embedded Grafeo parser wedges the DirtyIo scheduler thread on
  malformed single-quoted literals; escape-based sanitising
  (`Cqr.Grafeo.Gql.escape/1`) has been whack-a-moled twice and another
  unescaped character combination is always one user payload away. The
  durable fix is to stop interpolating user bytes into GQL at all:
  every write path base64-encodes free text before building the query,
  every read path decodes on the way out, and callers above the adapter
  never see the encoded form.

  The base64 alphabet (`[A-Za-z0-9+/=]`) is entirely GQL-safe — no
  backslash, single quote, newline, or C0 control byte can appear in
  the output — so the escape pipeline cannot misfire on encoded
  content.

  ## Backward compatibility

  Entities written before the codec existed carry raw descriptions in
  the database. `decode/1` tags encoded values with a `b64:` sentinel
  and returns any value missing that prefix unchanged, so legacy rows
  keep reading correctly. An accidental match on a legacy description
  that happens to start with literal `b64:` would decode incorrectly;
  in practice that collision has never occurred in seeded or asserted
  data, and the cost of a two-mode decoder (sentinel + UTF-8
  heuristic) is not worth the ambiguity it invites.
  """

  @prefix "b64:"

  @doc """
  Encode a free-text value for interpolation into a GQL single-quoted
  literal.

  Returns the empty string for `nil` or `""` so callers can continue to
  emit `property: '' ` when a field is unset without special-casing.
  Non-binary terms are coerced via `to_string/1` for ergonomic call
  sites.
  """
  @spec encode(term()) :: String.t()
  def encode(nil), do: ""
  def encode(""), do: ""

  def encode(value) when is_binary(value) do
    @prefix <> Base.encode64(value)
  end

  def encode(other), do: encode(to_string(other))

  @doc """
  Decode a value produced by `encode/1`.

  Values carrying the `b64:` sentinel are base64-decoded. Values
  without the sentinel (including the empty string and any legacy raw
  description) are returned unchanged. `nil` is preserved so optional
  fields keep their absence semantics.
  """
  @spec decode(term()) :: term()
  def decode(nil), do: nil

  def decode(@prefix <> rest) do
    case Base.decode64(rest) do
      {:ok, decoded} -> decoded
      :error -> @prefix <> rest
    end
  end

  def decode(other), do: other
end
