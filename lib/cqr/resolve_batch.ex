defmodule Cqr.ResolveBatch do
  @moduledoc """
  AST struct for the RESOLVE_BATCH primitive extension.

  Resolves multiple entities in a single call. Each entity in `entities`
  is resolved independently with the same filter parameters (`scope`,
  `freshness`, `reputation`); per-entity success or failure is reported
  in the result list. The batch as a whole succeeds unless the request
  itself is malformed.

  ## Privacy contract

  Per the existing `Cqr.Resolve` semantics, an entity blocked by an
  ancestor scope returns `:not_found`, indistinguishable from an entity
  that does not exist. `resolve_batch` preserves this contract per-row.

  ## Example

      %Cqr.ResolveBatch{
        entities: [
          {"engineering:proposals", "resolve_batch"},
          {"engineering:proposals", "assert_shacl"}
        ],
        scope: ["company"],
        freshness: {24, :h},
        reputation: 0.7
      }
  """

  @type entity_ref :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          entities: [entity_ref()],
          scope: [String.t()] | nil,
          freshness: {pos_integer(), atom()} | nil,
          reputation: float() | nil,
          include: [atom()] | nil
        }

  defstruct [:entities, :scope, :freshness, :reputation, :include]
end
