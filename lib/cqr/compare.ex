defmodule Cqr.Compare do
  @moduledoc """
  AST struct for the COMPARE primitive.

  COMPARE returns a side-by-side evaluation of two or more entities:
  shared relationships, differing properties, quality metadata
  differences (reputation, certification, freshness), and the
  relationship overlap set. The engine RESOLVEs every named entity
  first so scope visibility is enforced before any comparison work.

  ## Example

      %Cqr.Compare{
        entities: [{"product", "churn_rate"}, {"product", "nps"}],
        include: [:relationships, :properties, :quality]
      }

  ## Fields

    * `:entities` — list of entity references to compare. At least two
                    are required; the parser rejects single-entity calls.
    * `:include`  — annotation list selecting which comparison facets
                    to compute (`:relationships`, `:properties`,
                    `:quality`). Defaults to all three.
  """

  @type entity_ref :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          entities: [entity_ref()],
          include: [atom()]
        }

  defstruct entities: [],
            include: [:relationships, :properties, :quality]
end
