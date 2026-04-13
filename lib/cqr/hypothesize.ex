defmodule Cqr.Hypothesize do
  @moduledoc """
  AST struct for the HYPOTHESIZE primitive.

  HYPOTHESIZE projects the downstream effects of an assumed change to an
  entity. It walks the DERIVED_FROM and relationship graph outward from
  the target, computing a blast radius of entities that would be affected
  along with a confidence score that decays with hop distance.

  ## Example

      %Cqr.Hypothesize{
        entity: {"product", "churn_rate"},
        changes: [%{field: :reputation, value: 0.2}],
        depth: 3,
        decay: 0.7
      }

  ## Fields

    * `:entity`  - semantic address of the entity being hypothesized about.
    * `:changes` - list of hypothetical field changes. Each change is a
                   map with `:field` (atom) and `:value` (float | binary).
                   V1 recognises `:reputation` with a numeric target.
    * `:depth`   - how many hops to walk outward. Default 2.
    * `:decay`   - confidence multiplier applied per hop (0.0 - 1.0).
                   Default 0.7. `hop_confidence` at depth d is `decay ** d`.
  """

  @type change :: %{field: atom(), value: float() | String.t()}

  @type t :: %__MODULE__{
          entity: {String.t(), String.t()} | nil,
          changes: [change()],
          depth: pos_integer(),
          decay: float()
        }

  defstruct entity: nil,
            changes: [],
            depth: 2,
            decay: 0.7
end
