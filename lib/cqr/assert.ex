defmodule Cqr.Assert do
  @moduledoc """
  AST struct for the ASSERT primitive.

  ASSERT is the context creation primitive. An agent writes governed but
  uncertified context into the organizational knowledge graph. Asserted
  entities are immediately visible to RESOLVE and DISCOVER but carry lower
  trust than certified entities — "rumor with a paper trail."

  ## Example

      %Cqr.Assert{
        entity: {"product", "churn_nps_leading_indicator"},
        type: "derived_metric",
        description: "NPS decline of >5 points predicts churn within 60d",
        intent: "Identified statistical pattern during quarterly review",
        derived_from: [{"product", "churn_rate"}, {"product", "nps"}],
        scope: ["company", "product"],
        confidence: 0.65
      }

  ## Required vs optional fields

  Required (the parser populates whatever is present; the engine validates
  presence and returns informative errors if any required field is nil):

    * `:entity`        — semantic address of the new context
    * `:type`          — entity type identifier (metric, derived_metric, ...)
    * `:description`   — human-readable description
    * `:intent`        — why the agent is asserting this (mandatory paper trail)
    * `:derived_from`  — non-empty list of source entity references (lineage)

  Optional:

    * `:scope`         — target scope; defaults to the agent's active scope
    * `:confidence`    — agent's self-assessed confidence (0.0-1.0); defaults to 0.5

  ## Relationships

  The optional `relationships` parameter on the MCP tool (typed relationship
  edges to existing entities) is **not** part of the CQR expression syntax
  and therefore not part of this AST. The MCP tool layer parses it from a
  comma-delimited shorthand and passes it to the engine through the context
  map (`context[:relationships]`), which forwards it to the adapter.
  """

  @type entity_ref :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          entity: entity_ref(),
          type: String.t() | nil,
          description: String.t() | nil,
          intent: String.t() | nil,
          derived_from: [entity_ref()] | nil,
          scope: [String.t()] | nil,
          confidence: float() | nil
        }

  defstruct [
    :entity,
    :type,
    :description,
    :intent,
    :derived_from,
    :scope,
    :confidence
  ]
end
