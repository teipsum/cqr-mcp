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
        limit: 10
      }
  """

  @type t :: %__MODULE__{
          related_to: {:entity, {String.t(), String.t()}} | {:search, String.t()},
          within: [[String.t()]] | nil,
          depth: pos_integer() | nil,
          annotate: [atom()] | nil,
          limit: pos_integer() | nil
        }

  defstruct [:related_to, :within, :depth, :annotate, :limit]
end
