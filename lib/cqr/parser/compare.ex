defmodule Cqr.Parser.Compare do
  @moduledoc """
  COMPARE-specific parser combinators.

  Parses:

      COMPARE entity:ns:a, entity:ns:b [, entity:ns:c, ...]
        [INCLUDE relationships, properties, quality]

  At least two entity references are required. The optional `INCLUDE`
  clause selects which comparison facets to compute; if absent every
  facet is returned. See `Cqr.Compare` for field semantics.
  """

  import NimbleParsec
  alias Cqr.Parser.Terminals

  # --- Entity list ---

  # First entity + mandatory comma + second entity guarantees the >= 2
  # arity requirement at the grammar level. Additional entities are an
  # optional `repeat` of more comma-separated references.
  defp entity_list do
    Terminals.entity()
    |> ignore(Terminals.optional_sp())
    |> ignore(string(","))
    |> ignore(Terminals.optional_sp())
    |> concat(Terminals.entity())
    |> repeat(
      ignore(Terminals.optional_sp())
      |> ignore(string(","))
      |> ignore(Terminals.optional_sp())
      |> concat(Terminals.entity())
    )
    |> reduce({__MODULE__, :collect_entities, []})
    |> unwrap_and_tag(:entities)
    |> label("entity list (entity:ns:a, entity:ns:b, ...)")
  end

  def collect_entities(items), do: items

  # --- INCLUDE clause ---

  # COMPARE-specific annotation set distinct from RESOLVE's.
  defp compare_annotation do
    choice([
      string("relationships") |> replace(:relationships),
      string("properties") |> replace(:properties),
      string("quality") |> replace(:quality)
    ])
    |> label("compare annotation (relationships, properties, quality)")
  end

  defp compare_annotation_list do
    compare_annotation()
    |> repeat(
      ignore(Terminals.optional_sp())
      |> ignore(string(","))
      |> ignore(Terminals.optional_sp())
      |> concat(compare_annotation())
    )
    |> reduce({__MODULE__, :collect_annotations, []})
  end

  def collect_annotations(items), do: items

  def include_clause do
    ignore(string("INCLUDE"))
    |> ignore(Terminals.sp())
    |> concat(compare_annotation_list())
    |> unwrap_and_tag(:include)
    |> label("INCLUDE clause")
  end

  # Only one optional clause is defined today (`INCLUDE`), so the COMPARE
  # body wires it directly via `optional` rather than wrapping a single-arm
  # `choice/1` (which NimbleParsec rejects). When more clauses are added,
  # restore the `choice([...])` wrapper.
  def compare do
    ignore(string("COMPARE"))
    |> ignore(Terminals.sp())
    |> concat(entity_list())
    |> optional(
      ignore(Terminals.sp())
      |> concat(include_clause())
    )
    |> reduce({__MODULE__, :to_compare, []})
    |> label("COMPARE expression")
  end

  def to_compare(parts) do
    parts
    |> Enum.reduce(%Cqr.Compare{}, fn
      {:entities, entities}, acc -> %{acc | entities: entities}
      {:include, annotations}, acc -> %{acc | include: annotations}
    end)
  end
end
