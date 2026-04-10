defmodule Cqr.Cost do
  @moduledoc """
  Cost accounting per CQR query.

  Tracks adapters queried, context operations consumed, and execution time.
  Feeds into the organizational budget model.
  """

  defstruct adapters_queried: 0,
            operations: 0,
            execution_ms: 0
end
