defmodule Cqr.Parser.Resolve do
  @moduledoc """
  RESOLVE-specific parser combinators.

  Parses: `RESOLVE entity:ns:name [FROM scope] [WITH ...] [INCLUDE ...] [FALLBACK ...]`

  Optional clauses may appear in any order to accommodate LLM generation variance.
  """

  import NimbleParsec
  alias Cqr.Parser.Terminals

  # --- Individual clauses ---

  def from_clause do
    ignore(string("FROM"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.scope())
    |> unwrap_and_tag(:scope)
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
  end

  def include_clause do
    ignore(string("INCLUDE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.annotation_list())
    |> unwrap_and_tag(:include)
  end

  def fallback_clause do
    ignore(string("FALLBACK"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.scope())
    |> repeat(
      ignore(Terminals.optional_sp())
      |> ignore(Terminals.arrow())
      |> ignore(Terminals.optional_sp())
      |> concat(Terminals.scope())
    )
    |> reduce({__MODULE__, :collect_fallbacks, []})
  end

  def collect_fallbacks(scopes), do: {:fallback, scopes}

  def optional_clause do
    choice([
      freshness_clause(),
      reputation_clause(),
      from_clause(),
      include_clause(),
      fallback_clause()
    ])
  end

  # --- Full RESOLVE parser ---

  def resolve do
    ignore(string("RESOLVE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.entity() |> unwrap_and_tag(:entity))
    |> repeat(
      ignore(Terminals.sp())
      |> concat(optional_clause())
    )
    |> reduce({__MODULE__, :to_resolve, []})
    |> label("RESOLVE expression")
  end

  def to_resolve(parts) do
    parts
    |> Enum.reduce(%Cqr.Resolve{}, fn
      {:entity, entity}, acc -> %{acc | entity: entity}
      {:scope, scope}, acc -> %{acc | scope: scope}
      {:freshness, dur}, acc -> %{acc | freshness: dur}
      {:reputation, score}, acc -> %{acc | reputation: score}
      {:include, annots}, acc -> %{acc | include: annots}
      {:fallback, scopes}, acc -> %{acc | fallback: scopes}
    end)
  end
end
