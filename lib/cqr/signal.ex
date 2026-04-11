defmodule Cqr.Signal do
  @moduledoc """
  AST struct for the SIGNAL primitive.

  SIGNAL writes a quality/reputation assessment on an entity. It updates
  the entity's reputation score and records a `SignalRecord` audit node
  for traceability.

  ## Example

      %Cqr.Signal{
        entity: {"finance", "arr"},
        score: 0.75,
        evidence: "Pipeline refresh confirmed data is current",
        agent: nil,
        escalate_to: nil
      }

  ## Fields

    * `:entity`      — semantic address of the entity to signal (required)
    * `:score`       — new reputation score in `[0.0, 1.0]` (required)
    * `:evidence`    — rationale for the assessment (required)
    * `:agent`       — optional explicit agent identifier. When nil the
                       engine defaults to the agent from the request context.
    * `:escalate_to` — optional escalation target. Parsed but escalation
                       routing is V2.
  """

  @type entity_ref :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          entity: entity_ref(),
          score: float() | nil,
          evidence: String.t() | nil,
          agent: String.t() | nil,
          escalate_to: String.t() | nil
        }

  defstruct [:entity, :score, :evidence, :agent, :escalate_to]
end
