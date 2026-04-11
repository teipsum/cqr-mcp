defmodule Cqr.Parser.Refresh do
  @moduledoc """
  REFRESH-specific parser combinators.

  V1 parses CHECK mode only:

      REFRESH CHECK active_context
        [WITHIN scope:seg1[:seg2]]
        [WHERE age > <duration>]
        [RETURN stale_items]

  `active_context` is a literal keyword marking the scan target. The
  `WITHIN` clause is a local extension (not in the protocol spec) that
  lets the MCP `cqr_refresh` tool narrow the scan to a specific scope
  subtree; when absent, the scan covers every scope visible to the
  calling agent. `WHERE age > <duration>` sets the staleness threshold
  (default `24h`). `RETURN stale_items` is accepted and ignored — V1
  always returns stale items.
  """

  import NimbleParsec
  alias Cqr.Parser.Terminals

  # --- Individual clauses ---

  def within_clause do
    ignore(string("WITHIN"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.scope())
    |> unwrap_and_tag(:scope)
    |> label("WITHIN clause")
  end

  def where_clause do
    ignore(string("WHERE"))
    |> ignore(Terminals.sp())
    |> ignore(string("age"))
    |> ignore(Terminals.sp())
    |> ignore(string(">"))
    |> ignore(Terminals.optional_sp())
    |> concat(Terminals.duration())
    |> unwrap_and_tag(:threshold)
    |> label("WHERE age > <duration> clause")
  end

  def return_clause do
    ignore(string("RETURN"))
    |> ignore(Terminals.sp())
    |> ignore(string("stale_items"))
    |> replace({:return, :stale_items})
    |> label("RETURN stale_items clause")
  end

  def optional_clause do
    choice([
      within_clause(),
      where_clause(),
      return_clause()
    ])
  end

  # --- Full REFRESH parser ---

  def refresh do
    ignore(string("REFRESH"))
    |> ignore(Terminals.sp())
    |> ignore(string("CHECK"))
    |> ignore(Terminals.sp())
    |> ignore(string("active_context"))
    |> repeat(
      ignore(Terminals.sp())
      |> concat(optional_clause())
    )
    |> reduce({__MODULE__, :to_refresh, []})
    |> label("REFRESH expression")
  end

  def to_refresh(parts) do
    parts
    |> Enum.reduce(%Cqr.Refresh{}, fn
      {:scope, scope}, acc -> %{acc | scope: scope}
      {:threshold, dur}, acc -> %{acc | threshold: dur}
      {:return, _}, acc -> acc
    end)
  end
end
