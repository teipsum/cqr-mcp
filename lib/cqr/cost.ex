defmodule Cqr.Cost do
  @moduledoc """
  Cost accounting per CQR query.

  Tracks adapters queried, context operations consumed, and execution time.
  Feeds into the organizational budget model.
  """

  @type t :: %__MODULE__{
          adapters_queried: non_neg_integer(),
          operations: non_neg_integer(),
          execution_ms: non_neg_integer()
        }

  defstruct adapters_queried: 0,
            operations: 0,
            execution_ms: 0
end
