defmodule Cqr.Trace do
  @moduledoc """
  AST struct for the TRACE primitive.

  TRACE returns the provenance history of an entity: how it came to exist,
  what changed it, and why. The engine walks AssertionRecords,
  CertificationRecords, SignalRecords, and DERIVED_FROM edges to
  reconstruct the epistemic chain.

  ## Example

      %Cqr.Trace{
        entity: {"product", "churn_nps_leading_indicator"},
        time_window: {24, :h},
        causal_depth: 2,
        include: [:state_transitions, :actors, :triggers],
        for_entity: nil
      }

  ## Fields

    * `:entity`       — semantic address of the entity to trace (required)
    * `:time_window`  — optional `{amount, unit}` duration; when set, the
                        adapter filters events older than `now - window`.
    * `:causal_depth` — how many hops to follow through DERIVED_FROM
                        chains. Depth 1 returns direct sources only;
                        depth 2 returns sources-of-sources; etc. Default 1.
    * `:include`      — V1 annotation list (`:state_transitions`, `:actors`,
                        `:triggers`). Parsed but currently informational —
                        the default behaviour returns everything.
    * `:for_entity`   — optional "trace X relative to Y" annotation. Parsed
                        but not used in V1 execution.
  """

  @type entity_ref :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          entity: entity_ref(),
          time_window: {pos_integer(), atom()} | nil,
          causal_depth: pos_integer(),
          include: [atom()],
          for_entity: entity_ref() | nil
        }

  defstruct entity: nil,
            time_window: nil,
            causal_depth: 1,
            include: [:state_transitions, :actors, :triggers],
            for_entity: nil
end
