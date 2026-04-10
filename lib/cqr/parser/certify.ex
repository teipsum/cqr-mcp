defmodule Cqr.Parser.Certify do
  @moduledoc """
  CERTIFY-specific parser combinators.

  Parses: `CERTIFY entity:ns:name STATUS status [AUTHORITY id] [SUPERSEDES entity] [EVIDENCE "..."]`

  Optional clauses may appear in any order.
  """

  import NimbleParsec
  alias Cqr.Parser.Terminals

  # --- Individual clauses ---

  def status_clause do
    ignore(string("STATUS"))
    |> ignore(Terminals.sp())
    |> concat(
      choice([
        string("under_review") |> replace(:under_review),
        string("proposed") |> replace(:proposed),
        string("certified") |> replace(:certified),
        string("superseded") |> replace(:superseded)
      ])
    )
    |> unwrap_and_tag(:status)
    |> label("STATUS clause (proposed, under_review, certified, superseded)")
  end

  def authority_clause do
    ignore(string("AUTHORITY"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.identifier())
    |> unwrap_and_tag(:authority)
  end

  def supersedes_clause do
    ignore(string("SUPERSEDES"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.entity())
    |> unwrap_and_tag(:supersedes)
  end

  def evidence_clause do
    ignore(string("EVIDENCE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.string_literal())
    |> unwrap_and_tag(:evidence)
  end

  def optional_clause do
    choice([
      status_clause(),
      authority_clause(),
      supersedes_clause(),
      evidence_clause()
    ])
  end

  # --- Full CERTIFY parser ---

  def certify do
    ignore(string("CERTIFY"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.entity() |> unwrap_and_tag(:entity))
    |> repeat(
      ignore(Terminals.sp())
      |> concat(optional_clause())
    )
    |> reduce({__MODULE__, :to_certify, []})
    |> label("CERTIFY expression")
  end

  def to_certify(parts) do
    parts
    |> Enum.reduce(%Cqr.Certify{}, fn
      {:entity, entity}, acc -> %{acc | entity: entity}
      {:status, status}, acc -> %{acc | status: status}
      {:authority, auth}, acc -> %{acc | authority: auth}
      {:supersedes, entity}, acc -> %{acc | supersedes: entity}
      {:evidence, ev}, acc -> %{acc | evidence: ev}
    end)
  end
end
