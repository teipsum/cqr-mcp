defmodule Cqr.Parser.Discover do
  @moduledoc """
  DISCOVER-specific parser combinators.

  Parses: `DISCOVER concepts RELATED TO entity/string [WITHIN ...] [DEPTH n] [ANNOTATE ...] [LIMIT n]`

  Optional clauses may appear in any order.
  """

  import NimbleParsec
  alias Cqr.Parser.Terminals

  # --- Individual clauses ---

  def related_clause do
    ignore(string("RELATED"))
    |> ignore(Terminals.sp())
    |> ignore(string("TO"))
    |> ignore(Terminals.sp())
    |> concat(
      choice([
        Terminals.entity() |> map({__MODULE__, :tag_entity, []}),
        Terminals.string_literal() |> map({__MODULE__, :tag_search, []})
      ])
    )
    |> unwrap_and_tag(:related_to)
  end

  def tag_entity(entity), do: {:entity, entity}
  def tag_search(text), do: {:search, text}

  def within_clause do
    ignore(string("WITHIN"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.scope())
    |> repeat(
      ignore(Terminals.optional_sp())
      |> ignore(string(","))
      |> ignore(Terminals.optional_sp())
      |> concat(Terminals.scope())
    )
    |> reduce({__MODULE__, :collect_scopes, []})
  end

  def collect_scopes(scope_segments) do
    {:within, scope_segments}
  end

  def depth_clause do
    ignore(string("DEPTH"))
    |> ignore(Terminals.sp())
    |> integer(min: 1)
    |> unwrap_and_tag(:depth)
  end

  def annotate_clause do
    ignore(string("ANNOTATE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.annotation_list())
    |> unwrap_and_tag(:annotate)
  end

  def limit_clause do
    ignore(string("LIMIT"))
    |> ignore(Terminals.sp())
    |> integer(min: 1)
    |> unwrap_and_tag(:limit)
  end

  def optional_clause do
    choice([
      within_clause(),
      depth_clause(),
      annotate_clause(),
      limit_clause()
    ])
  end

  # --- Full DISCOVER parser ---

  def discover do
    ignore(string("DISCOVER"))
    |> ignore(Terminals.sp())
    |> ignore(string("concepts"))
    |> ignore(Terminals.sp())
    |> concat(related_clause())
    |> repeat(
      ignore(Terminals.sp())
      |> concat(optional_clause())
    )
    |> reduce({__MODULE__, :to_discover, []})
    |> label("DISCOVER expression")
  end

  def to_discover(parts) do
    parts
    |> Enum.reduce(%Cqr.Discover{}, fn
      {:related_to, rel}, acc -> %{acc | related_to: rel}
      {:within, scopes}, acc -> %{acc | within: scopes}
      {:depth, d}, acc -> %{acc | depth: d}
      {:annotate, annots}, acc -> %{acc | annotate: annots}
      {:limit, l}, acc -> %{acc | limit: l}
    end)
  end
end
