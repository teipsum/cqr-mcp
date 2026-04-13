defmodule Cqr.Parser.Update do
  @moduledoc """
  UPDATE-specific parser combinators.

  Parses:

      UPDATE entity:ns:name
        [DESCRIPTION "<text>"]
        [TYPE <identifier>]
        CHANGE_TYPE correction|refresh|redefinition|scope_change|reclassification
        [EVIDENCE "<text>"]
        [CONFIDENCE <score>]

  Clauses after the entity may appear in any order. Only the entity and
  CHANGE_TYPE clauses are mandatory; engine-layer validation surfaces a
  clear error when CHANGE_TYPE is missing.
  """

  import NimbleParsec
  alias Cqr.Parser.Terminals

  # --- Individual clauses ---

  def description_clause do
    ignore(string("DESCRIPTION"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.string_literal())
    |> unwrap_and_tag(:description)
    |> label("DESCRIPTION clause")
  end

  def type_clause do
    ignore(string("TYPE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.identifier())
    |> unwrap_and_tag(:type)
    |> label("TYPE clause")
  end

  def change_type_clause do
    ignore(string("CHANGE_TYPE"))
    |> ignore(Terminals.sp())
    |> concat(
      choice([
        string("correction") |> replace(:correction),
        string("refresh") |> replace(:refresh),
        string("redefinition") |> replace(:redefinition),
        string("scope_change") |> replace(:scope_change),
        string("reclassification") |> replace(:reclassification)
      ])
    )
    |> unwrap_and_tag(:change_type)
    |> label(
      "CHANGE_TYPE clause (correction, refresh, redefinition, scope_change, reclassification)"
    )
  end

  def evidence_clause do
    ignore(string("EVIDENCE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.string_literal())
    |> unwrap_and_tag(:evidence)
    |> label("EVIDENCE clause")
  end

  def confidence_clause do
    ignore(string("CONFIDENCE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.score())
    |> unwrap_and_tag(:confidence)
    |> label("CONFIDENCE clause")
  end

  def optional_clause do
    choice([
      description_clause(),
      change_type_clause(),
      type_clause(),
      evidence_clause(),
      confidence_clause()
    ])
  end

  # --- Full UPDATE parser ---

  def update do
    ignore(string("UPDATE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.entity() |> unwrap_and_tag(:entity))
    |> repeat(
      ignore(Terminals.sp())
      |> concat(optional_clause())
    )
    |> reduce({__MODULE__, :to_update, []})
    |> label("UPDATE expression")
  end

  def to_update(parts) do
    parts
    |> Enum.reduce(%Cqr.Update{}, fn
      {:entity, entity}, acc -> %{acc | entity: entity}
      {:description, desc}, acc -> %{acc | description: desc}
      {:type, type}, acc -> %{acc | type: type}
      {:change_type, ct}, acc -> %{acc | change_type: ct}
      {:evidence, ev}, acc -> %{acc | evidence: ev}
      {:confidence, c}, acc -> %{acc | confidence: c}
    end)
  end
end
