defmodule Cqr.Parser.Signal do
  @moduledoc """
  SIGNAL-specific parser combinators.

  Parses:

      SIGNAL reputation
        ON entity:ns:name
        SCORE <score>
        EVIDENCE "<rationale>"
        [AGENT agent:<identifier>]
        [ESCALATE TO agent:<identifier>]

  Optional clauses may appear in any order after the mandatory `reputation`
  keyword. The parser only populates whichever fields are present; required
  field presence (`:entity`, `:score`, `:evidence`) is validated in the
  engine with informative errors.
  """

  import NimbleParsec
  alias Cqr.Parser.Terminals

  # --- Individual clauses ---

  def on_clause do
    ignore(string("ON"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.entity())
    |> unwrap_and_tag(:entity)
    |> label("ON clause")
  end

  def score_clause do
    ignore(string("SCORE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.score())
    |> unwrap_and_tag(:score)
    |> label("SCORE clause")
  end

  def evidence_clause do
    ignore(string("EVIDENCE"))
    |> ignore(Terminals.sp())
    |> concat(Terminals.string_literal())
    |> unwrap_and_tag(:evidence)
    |> label("EVIDENCE clause")
  end

  def agent_clause do
    ignore(string("AGENT"))
    |> ignore(Terminals.sp())
    |> concat(agent_ref())
    |> unwrap_and_tag(:agent)
    |> label("AGENT clause")
  end

  def escalate_clause do
    ignore(string("ESCALATE"))
    |> ignore(Terminals.sp())
    |> ignore(string("TO"))
    |> ignore(Terminals.sp())
    |> concat(agent_ref())
    |> unwrap_and_tag(:escalate_to)
    |> label("ESCALATE TO clause")
  end

  # `agent:identifier[:segment...]` — mirrors `scope:` shape from Terminals.
  defp agent_ref do
    ignore(string("agent:"))
    |> concat(Terminals.identifier())
    |> repeat(ignore(string(":")) |> concat(Terminals.identifier()))
    |> reduce({__MODULE__, :join_agent_ref, []})
    |> label("agent reference (agent:identifier[:segment])")
  end

  def join_agent_ref(segments) do
    "agent:" <> Enum.join(segments, ":")
  end

  def optional_clause do
    choice([
      on_clause(),
      score_clause(),
      evidence_clause(),
      agent_clause(),
      escalate_clause()
    ])
  end

  # --- Full SIGNAL parser ---

  def signal do
    ignore(string("SIGNAL"))
    |> ignore(Terminals.sp())
    |> ignore(string("reputation"))
    |> repeat(
      ignore(Terminals.sp())
      |> concat(optional_clause())
    )
    |> reduce({__MODULE__, :to_signal, []})
    |> label("SIGNAL expression")
  end

  def to_signal(parts) do
    parts
    |> Enum.reduce(%Cqr.Signal{}, fn
      {:entity, entity}, acc -> %{acc | entity: entity}
      {:score, score}, acc -> %{acc | score: score}
      {:evidence, ev}, acc -> %{acc | evidence: ev}
      {:agent, agent}, acc -> %{acc | agent: agent}
      {:escalate_to, target}, acc -> %{acc | escalate_to: target}
    end)
  end
end
