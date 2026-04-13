defmodule Cqr.Parser.Awareness do
  @moduledoc """
  AWARENESS-specific parser combinators.

  Parses:

      AWARENESS active_agents
        [WITHIN scope:seg1[:seg2]]
        [OVER last <duration>]
        [LIMIT <integer>]

  `active_agents` is a literal keyword marking the scan target. The
  optional `WITHIN` clause narrows the scan to a specific scope subtree
  (intersected with the agent's sandbox by the engine). `OVER last
  <duration>` filters audit events to the recent window. `LIMIT <int>`
  caps the number of agents returned (default 20).

  Optional clauses may appear in any order to match LLM generation
  variance.
  """

  import NimbleParsec
  alias Cqr.Parser.Terminals

  # --- Individual clauses ---

  def within_clause do
    ignore(string("WITHIN"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.scope())
    |> unwrap_and_tag(:within)
    |> label("WITHIN clause")
  end

  def over_clause do
    ignore(string("OVER"))
    |> ignore(Terminals.sp())
    |> ignore(string("last"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.duration())
    |> unwrap_and_tag(:time_window)
    |> label("OVER last <duration> clause")
  end

  def limit_clause do
    ignore(string("LIMIT"))
    |> ignore(Terminals.sp())
    |> concat(integer(min: 1))
    |> unwrap_and_tag(:limit)
    |> label("LIMIT clause")
  end

  def optional_clause do
    choice([
      within_clause(),
      over_clause(),
      limit_clause()
    ])
  end

  # --- Full AWARENESS parser ---

  def awareness do
    ignore(string("AWARENESS"))
    |> ignore(Terminals.sp())
    |> ignore(string("active_agents"))
    |> repeat(
      ignore(Terminals.sp())
      |> concat(optional_clause())
    )
    |> reduce({__MODULE__, :to_awareness, []})
    |> label("AWARENESS expression")
  end

  def to_awareness(parts) do
    parts
    |> Enum.reduce(%Cqr.Awareness{}, fn
      {:within, scope}, acc -> %{acc | within: scope}
      {:time_window, dur}, acc -> %{acc | time_window: dur}
      {:limit, n}, acc -> %{acc | limit: n}
    end)
  end
end
