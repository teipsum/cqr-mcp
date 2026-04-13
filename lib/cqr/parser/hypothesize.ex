defmodule Cqr.Parser.Hypothesize do
  @moduledoc """
  HYPOTHESIZE-specific parser combinators.

  Parses:

      HYPOTHESIZE entity:ns:name
        CHANGE reputation TO <score>
        [DEPTH <integer>]
        [DECAY <score>]

  Optional clauses may appear in any order after the entity. `CHANGE`
  clauses may repeat; each appends to the `:changes` list. V1 only
  recognises the `reputation` field with a numeric target.

  See `Cqr.Hypothesize` for field semantics.
  """

  import NimbleParsec
  alias Cqr.Parser.Terminals

  # --- Individual clauses ---

  def change_clause do
    ignore(string("CHANGE"))
    |> ignore(Terminals.sp())
    |> concat(change_field())
    |> ignore(Terminals.sp())
    |> ignore(string("TO"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.score())
    |> reduce({__MODULE__, :to_change, []})
    |> label("CHANGE clause")
  end

  defp change_field do
    string("reputation")
    |> replace(:reputation)
    |> label("hypothetical change field (reputation)")
  end

  def to_change([field, value]) do
    {:change, %{field: field, value: value}}
  end

  def depth_clause do
    ignore(string("DEPTH"))
    |> ignore(Terminals.sp())
    |> concat(integer(min: 1))
    |> unwrap_and_tag(:depth)
    |> label("DEPTH clause")
  end

  def decay_clause do
    ignore(string("DECAY"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.score())
    |> unwrap_and_tag(:decay)
    |> label("DECAY clause")
  end

  def optional_clause do
    choice([
      change_clause(),
      depth_clause(),
      decay_clause()
    ])
  end

  # --- Full HYPOTHESIZE parser ---

  def hypothesize do
    ignore(string("HYPOTHESIZE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.entity() |> unwrap_and_tag(:entity))
    |> repeat(
      ignore(Terminals.sp())
      |> concat(optional_clause())
    )
    |> reduce({__MODULE__, :to_hypothesize, []})
    |> label("HYPOTHESIZE expression")
  end

  def to_hypothesize(parts) do
    parts
    |> Enum.reduce(%Cqr.Hypothesize{changes: []}, fn
      {:entity, entity}, acc -> %{acc | entity: entity}
      {:change, change}, acc -> %{acc | changes: acc.changes ++ [change]}
      {:depth, depth}, acc -> %{acc | depth: depth}
      {:decay, decay}, acc -> %{acc | decay: decay}
    end)
  end
end
