defmodule Cqr.Parser.Anchor do
  @moduledoc """
  ANCHOR-specific parser combinators.

  Parses:

      ANCHOR entity:ns:name[, entity:ns:name, ...]
        [FOR "rationale"]
        [WITH freshness < <duration>]
        [WITH reputation > <score>]

  Optional clauses may appear in any order to accommodate LLM generation
  variance. See `Cqr.Anchor` for field semantics.
  """

  import NimbleParsec
  alias Cqr.Parser.Terminals

  # --- Entity list ---

  def entity_list do
    Terminals.entity()
    |> repeat(
      ignore(Terminals.optional_sp())
      |> ignore(string(","))
      |> ignore(Terminals.optional_sp())
      |> concat(Terminals.entity())
    )
    |> reduce({__MODULE__, :collect_entities, []})
    |> label("comma-separated entity list")
  end

  def collect_entities(entities), do: {:entities, entities}

  # --- Individual clauses ---

  def for_clause do
    ignore(string("FOR"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.string_literal())
    |> unwrap_and_tag(:rationale)
    |> label("FOR \"rationale\" clause")
  end

  def freshness_clause do
    ignore(string("WITH"))
    |> ignore(Terminals.sp())
    |> ignore(string("freshness"))
    |> ignore(Terminals.sp())
    |> ignore(string("<"))
    |> ignore(Terminals.optional_sp())
    |> concat(Terminals.duration())
    |> unwrap_and_tag(:freshness)
    |> label("WITH freshness < <duration> clause")
  end

  def reputation_clause do
    ignore(string("WITH"))
    |> ignore(Terminals.sp())
    |> ignore(string("reputation"))
    |> ignore(Terminals.sp())
    |> ignore(string(">"))
    |> ignore(Terminals.optional_sp())
    |> concat(Terminals.score())
    |> unwrap_and_tag(:reputation)
    |> label("WITH reputation > <score> clause")
  end

  def optional_clause do
    choice([
      freshness_clause(),
      reputation_clause(),
      for_clause()
    ])
  end

  # --- Full ANCHOR parser ---

  def anchor do
    ignore(string("ANCHOR"))
    |> ignore(Terminals.sp())
    |> concat(entity_list())
    |> repeat(
      ignore(Terminals.sp())
      |> concat(optional_clause())
    )
    |> reduce({__MODULE__, :to_anchor, []})
    |> label("ANCHOR expression")
  end

  def to_anchor(parts) do
    parts
    |> Enum.reduce(%Cqr.Anchor{}, fn
      {:entities, entities}, acc -> %{acc | entities: entities}
      {:rationale, rationale}, acc -> %{acc | rationale: rationale}
      {:freshness, dur}, acc -> %{acc | freshness: dur}
      {:reputation, score}, acc -> %{acc | reputation: score}
    end)
  end
end
