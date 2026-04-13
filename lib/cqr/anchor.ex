defmodule Cqr.Anchor do
  @moduledoc """
  AST struct for the ANCHOR primitive.

  ANCHOR evaluates the composite confidence of a set of entities used
  together as a reasoning chain. It returns the weakest-link confidence
  floor, average reputation, and flags any entities that are missing,
  uncertified, stale, or below a requested reputation threshold — along
  with actionable recommendations for certifying or refreshing links
  before the chain is relied on for a decision.

  ## Example

      %Cqr.Anchor{
        entities: [
          {"finance", "arr"},
          {"product", "churn_rate"},
          {"company", "health_score"}
        ],
        rationale: "Q4 board health assessment",
        freshness: {24, :h},
        reputation: 0.7
      }

  ## Fields

    * `:entities`   — ordered list of entity references forming the
                      reasoning chain (required, at least one).
    * `:rationale`  — free-text description of the decision this chain
                      underwrites. Surfaced back in the result so audit
                      trails record *why* the chain was anchored.
    * `:freshness`  — optional `{amount, unit}` threshold. Entities whose
                      `freshness_hours_ago` exceeds the window are
                      flagged `stale`.
    * `:reputation` — optional minimum reputation threshold. Entities
                      below it are flagged `below_reputation` and feed
                      into the recommendations list.
  """

  @type entity_ref :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          entities: [entity_ref()],
          rationale: String.t() | nil,
          freshness: {pos_integer(), atom()} | nil,
          reputation: float() | nil
        }

  defstruct entities: [], rationale: nil, freshness: nil, reputation: nil
end
