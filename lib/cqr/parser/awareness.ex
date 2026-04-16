defmodule Cqr.Parser.Awareness do
  @moduledoc """
  AWARENESS-specific parser combinators.

  Parses two modes:

      AWARENESS active_agents
        [WITHIN scope:seg1[:seg2]]
        [OVER last <duration>]
        [LIMIT <integer>]

      AWARENESS search
        [WITHIN scope:seg1[:seg2]]
        [OVER last <duration>]
        [LIMIT <integer>]
        [NAMESPACE <prefix>]
        [PRIMITIVE <assert|certify|signal>]
        [INTENT "<text>"]
        [AGENT "<agent_id>"]

  Optional clauses may appear in any order to match LLM generation
  variance. Search-mode filters are AND-composed: a row must pass
  every non-nil filter.
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

  # --- Search-mode filter clauses ---

  # Token: non-whitespace characters, used for namespace prefixes and
  # agent IDs which may contain colons (e.g. "product:retention",
  # "twin:investigator").
  defp token do
    ascii_string([{:not, ?\s}, {:not, ?\t}, {:not, ?\n}], min: 1)
    |> label("token")
  end

  def namespace_clause do
    ignore(string("NAMESPACE"))
    |> ignore(Terminals.sp())
    |> concat(token())
    |> unwrap_and_tag(:namespace_prefix)
    |> label("NAMESPACE clause")
  end

  def primitive_clause do
    ignore(string("PRIMITIVE"))
    |> ignore(Terminals.sp())
    |> concat(
      choice([
        string("assert") |> replace(:assert),
        string("certify") |> replace(:certify),
        string("signal") |> replace(:signal)
      ])
    )
    |> unwrap_and_tag(:primitive_filter)
    |> label("PRIMITIVE clause")
  end

  def intent_clause do
    ignore(string("INTENT"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.string_literal())
    |> unwrap_and_tag(:intent_search)
    |> label("INTENT clause")
  end

  def agent_clause do
    ignore(string("AGENT"))
    |> ignore(Terminals.sp())
    |> concat(token())
    |> unwrap_and_tag(:agent_filter)
    |> label("AGENT clause")
  end

  def optional_clause do
    choice([
      within_clause(),
      over_clause(),
      limit_clause(),
      namespace_clause(),
      primitive_clause(),
      intent_clause(),
      agent_clause()
    ])
  end

  # --- Full AWARENESS parser ---

  def awareness do
    ignore(string("AWARENESS"))
    |> ignore(Terminals.sp())
    |> concat(
      choice([
        string("active_agents") |> replace(:active_agents),
        string("search") |> replace(:search)
      ])
    )
    |> unwrap_and_tag(:mode)
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
      {:mode, mode}, acc -> %{acc | mode: mode}
      {:within, scope}, acc -> %{acc | within: scope}
      {:time_window, dur}, acc -> %{acc | time_window: dur}
      {:limit, n}, acc -> %{acc | limit: n}
      {:namespace_prefix, prefix}, acc -> %{acc | namespace_prefix: prefix}
      {:primitive_filter, prim}, acc -> %{acc | primitive_filter: prim}
      {:intent_search, text}, acc -> %{acc | intent_search: text}
      {:agent_filter, agent_id}, acc -> %{acc | agent_filter: agent_id}
    end)
  end
end
