defmodule Cqr.Parser.Assert do
  @moduledoc """
  ASSERT-specific parser combinators.

  Parses:

      ASSERT entity:ns:name
        TYPE <identifier>
        DESCRIPTION "<text>"
        INTENT "<text>"
        DERIVED_FROM entity:ns:name [, entity:ns:name, ...]
        [IN scope:seg1[:seg2]]
        [CONFIDENCE <score>]
        [RELATIONSHIPS REL_TYPE:entity:ns:name:<score> [, ...]]

  Clauses after the entity may appear in any order to accommodate LLM
  generation variance. The parser populates whichever clauses are present;
  presence of the required clauses (TYPE, DESCRIPTION, INTENT, DERIVED_FROM)
  is validated at the engine layer with informative errors.

  Valid relationship types: CORRELATES_WITH, CONTRIBUTES_TO, DEPENDS_ON,
  CAUSES, PART_OF.
  """

  import NimbleParsec
  alias Cqr.Parser.Terminals

  # --- Individual clauses ---

  def type_clause do
    ignore(string("TYPE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.identifier())
    |> unwrap_and_tag(:type)
    |> label("TYPE clause")
  end

  def description_clause do
    ignore(string("DESCRIPTION"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.string_literal())
    |> unwrap_and_tag(:description)
    |> label("DESCRIPTION clause")
  end

  def intent_clause do
    ignore(string("INTENT"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.string_literal())
    |> unwrap_and_tag(:intent)
    |> label("INTENT clause")
  end

  def derived_from_clause do
    ignore(string("DERIVED_FROM"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.entity())
    |> repeat(
      ignore(Terminals.optional_sp())
      |> ignore(string(","))
      |> ignore(Terminals.optional_sp())
      |> concat(Terminals.entity())
    )
    |> reduce({__MODULE__, :collect_derived_from, []})
    |> label("DERIVED_FROM clause")
  end

  def collect_derived_from(entities), do: {:derived_from, entities}

  def in_clause do
    ignore(string("IN"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.scope())
    |> unwrap_and_tag(:scope)
    |> label("IN clause")
  end

  def confidence_clause do
    ignore(string("CONFIDENCE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.score())
    |> unwrap_and_tag(:confidence)
    |> label("CONFIDENCE clause")
  end

  def relationship_type do
    choice([
      string("CORRELATES_WITH"),
      string("CONTRIBUTES_TO"),
      string("DEPENDS_ON"),
      string("CAUSES"),
      string("PART_OF")
    ])
    |> label("relationship type (CORRELATES_WITH, CONTRIBUTES_TO, DEPENDS_ON, CAUSES, PART_OF)")
  end

  def relationship do
    relationship_type()
    |> ignore(string(":"))
    |> concat(Terminals.entity())
    |> ignore(string(":"))
    |> concat(Terminals.score())
    |> reduce({__MODULE__, :to_relationship, []})
    |> label("relationship (TYPE:entity:ns:name:strength)")
  end

  def to_relationship([type, {ns, name}, strength]) do
    %{type: type, target: {ns, name}, strength: strength}
  end

  def relationships_clause do
    ignore(string("RELATIONSHIPS"))
    |> ignore(Terminals.sp())
    |> concat(relationship())
    |> repeat(
      ignore(Terminals.optional_sp())
      |> ignore(string(","))
      |> ignore(Terminals.optional_sp())
      |> concat(relationship())
    )
    |> reduce({__MODULE__, :collect_relationships, []})
    |> label("RELATIONSHIPS clause")
  end

  def collect_relationships(rels), do: {:relationships, rels}

  def optional_clause do
    choice([
      type_clause(),
      description_clause(),
      intent_clause(),
      derived_from_clause(),
      in_clause(),
      confidence_clause(),
      relationships_clause()
    ])
  end

  # --- Full ASSERT parser ---

  def assert_expression do
    ignore(string("ASSERT"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.entity() |> unwrap_and_tag(:entity))
    |> repeat(
      ignore(Terminals.sp())
      |> concat(optional_clause())
    )
    |> reduce({__MODULE__, :to_assert, []})
    |> label("ASSERT expression")
  end

  def to_assert(parts) do
    parts
    |> Enum.reduce(%Cqr.Assert{}, fn
      {:entity, entity}, acc -> %{acc | entity: entity}
      {:type, type}, acc -> %{acc | type: type}
      {:description, desc}, acc -> %{acc | description: desc}
      {:intent, intent}, acc -> %{acc | intent: intent}
      {:derived_from, list}, acc -> %{acc | derived_from: list}
      {:scope, scope}, acc -> %{acc | scope: scope}
      {:confidence, score}, acc -> %{acc | confidence: score}
      {:relationships, rels}, acc -> %{acc | relationships: rels}
    end)
  end
end
