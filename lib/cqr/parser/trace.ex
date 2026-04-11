defmodule Cqr.Parser.Trace do
  @moduledoc """
  TRACE-specific parser combinators.

  Parses:

      TRACE entity:ns:name
        [FOR entity:ns:name]
        [OVER last <duration>]
        [INCLUDE state_transitions, actors, triggers]
        [DEPTH causal:<integer>]

  Optional clauses may appear in any order to accommodate LLM generation
  variance. See `Cqr.Trace` for field semantics.
  """

  import NimbleParsec
  alias Cqr.Parser.Terminals

  # --- Individual clauses ---

  def for_clause do
    ignore(string("FOR"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.entity())
    |> unwrap_and_tag(:for_entity)
    |> label("FOR clause")
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

  def include_clause do
    ignore(string("INCLUDE"))
    |> ignore(Terminals.sp())
    |> concat(trace_annotation_list())
    |> unwrap_and_tag(:include)
    |> label("INCLUDE clause")
  end

  def depth_clause do
    ignore(string("DEPTH"))
    |> ignore(Terminals.sp())
    |> ignore(string("causal:"))
    |> concat(integer(min: 1))
    |> unwrap_and_tag(:causal_depth)
    |> label("DEPTH causal:<integer> clause")
  end

  # TRACE-specific annotation set — distinct from the RESOLVE annotation
  # list which uses (freshness, confidence, reputation, owner, lineage).
  defp trace_annotation do
    choice([
      string("state_transitions") |> replace(:state_transitions),
      string("actors") |> replace(:actors),
      string("triggers") |> replace(:triggers)
    ])
    |> label("trace annotation (state_transitions, actors, triggers)")
  end

  defp trace_annotation_list do
    trace_annotation()
    |> repeat(
      ignore(Terminals.optional_sp())
      |> ignore(string(","))
      |> ignore(Terminals.optional_sp())
      |> concat(trace_annotation())
    )
    |> reduce({__MODULE__, :collect_annotations, []})
  end

  def collect_annotations(items), do: items

  def optional_clause do
    choice([
      for_clause(),
      over_clause(),
      include_clause(),
      depth_clause()
    ])
  end

  # --- Full TRACE parser ---

  def trace do
    ignore(string("TRACE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.entity() |> unwrap_and_tag(:entity))
    |> repeat(
      ignore(Terminals.sp())
      |> concat(optional_clause())
    )
    |> reduce({__MODULE__, :to_trace, []})
    |> label("TRACE expression")
  end

  def to_trace(parts) do
    parts
    |> Enum.reduce(%Cqr.Trace{}, fn
      {:entity, entity}, acc -> %{acc | entity: entity}
      {:for_entity, entity}, acc -> %{acc | for_entity: entity}
      {:time_window, dur}, acc -> %{acc | time_window: dur}
      {:include, annotations}, acc -> %{acc | include: annotations}
      {:causal_depth, depth}, acc -> %{acc | causal_depth: depth}
    end)
  end
end
