defmodule Cqr.Discover do
  @moduledoc """
  AST struct for the DISCOVER primitive.

  Returns a navigable map of concepts related to an anchor entity,
  combining graph traversal and vector similarity.

  ## Example

      %Cqr.Discover{
        related_to: {:entity, {"product", "churn_rate"}},
        within: [["product"], ["customer_success"]],
        depth: 3,
        annotate: [:freshness, :reputation, :owner],
        limit: 10,
        direction: :both
      }

  ## Example with `near` (search mode)

      %Cqr.Discover{
        related_to: {:search, "patent strategy"},
        near: {"patent:filings", "provisional"},
        limit: 10
      }

  ## Direction

  Edges are stored once, directionally. The `direction` field controls
  which side of an edge is followed during discovery:

    * `:outbound` — the anchor entity is the edge source
    * `:inbound`  — the anchor entity is the edge target
    * `:both`     — union of both queries (default when nil)

  ## Near

  Optional. When set on a `{:search, term}` discovery, ranking is biased
  toward entities that are both semantically related to the term AND
  structurally adjacent to the `near` anchor in the relationship graph.
  Ignored by anchor-mode and prefix-mode discovery.
  """

  @type direction :: :outbound | :inbound | :both

  @type t :: %__MODULE__{
          related_to:
            {:entity, {String.t(), String.t()}}
            | {:search, String.t()}
            | {:prefix, [String.t()]},
          within: [[String.t()]] | nil,
          depth: pos_integer() | nil,
          annotate: [atom()] | nil,
          limit: pos_integer() | nil,
          direction: direction() | nil,
          near: {String.t(), String.t()} | nil
        }

  defstruct [:related_to, :within, :depth, :annotate, :limit, :direction, :near]
end
