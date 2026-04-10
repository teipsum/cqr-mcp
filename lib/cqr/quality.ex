defmodule Cqr.Quality do
  @moduledoc """
  Quality metadata envelope — mandatory on every CQR response.

  An agent always knows how much to trust what it received.
  Fields default to `:unknown` rather than nil to distinguish
  "not yet computed" from "not applicable".

  See PROJECT_KNOWLEDGE.md Section 6.
  """

  @type t :: %__MODULE__{
          freshness: DateTime.t() | :unknown,
          confidence: float() | :unknown,
          reputation: float() | :unknown,
          provenance: String.t() | :unknown,
          owner: String.t() | :unknown,
          lineage: [String.t()],
          certified_by: String.t() | nil,
          certified_at: DateTime.t() | nil
        }

  defstruct freshness: :unknown,
            confidence: :unknown,
            reputation: :unknown,
            provenance: :unknown,
            owner: :unknown,
            lineage: [],
            certified_by: nil,
            certified_at: nil
end
