defmodule Cqr.Result do
  @moduledoc """
  CQR query result with mandatory quality metadata envelope.

  Every response from the engine includes data, quality metadata,
  source attribution, and cost accounting.
  """

  @type t :: %__MODULE__{
          data: list(),
          sources: [String.t()],
          conflicts: list(),
          quality: Cqr.Quality.t(),
          cost: Cqr.Cost.t()
        }

  defstruct data: [],
            sources: [],
            conflicts: [],
            quality: %Cqr.Quality{},
            cost: %Cqr.Cost{}
end
