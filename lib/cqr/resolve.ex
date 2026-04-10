defmodule Cqr.Resolve do
  @moduledoc """
  AST struct for the RESOLVE primitive.

  Retrieves a canonical entity by semantic address from the nearest
  matching scope, with quality metadata.

  ## Example

      %Cqr.Resolve{
        entity: {"finance", "arr"},
        scope: ["company", "finance"],
        freshness: {24, :h},
        reputation: 0.7,
        include: [:lineage, :confidence, :owner],
        fallback: [["product"], ["global"]]
      }
  """

  @type t :: %__MODULE__{
          entity: {String.t(), String.t()},
          scope: [String.t()] | nil,
          freshness: {pos_integer(), atom()} | nil,
          reputation: float() | nil,
          include: [atom()] | nil,
          fallback: [[String.t()]] | nil
        }

  defstruct [:entity, :scope, :freshness, :reputation, :include, :fallback]
end
