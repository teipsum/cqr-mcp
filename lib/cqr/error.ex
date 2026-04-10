defmodule Cqr.Error do
  @moduledoc """
  Informative error semantics for CQR.

  Errors are structs, not exceptions. They're data for agents to
  reason over — telling the agent what went wrong, why, and what
  to try next.
  """

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          details: map(),
          suggestions: [String.t()],
          similar_entities: [String.t()],
          partial_results: list(),
          retry_guidance: String.t() | nil
        }

  defstruct code: :unknown_error,
            message: "",
            details: %{},
            suggestions: [],
            similar_entities: [],
            partial_results: [],
            retry_guidance: nil

  @doc "Creates a parse error with position and expected tokens."
  def parse_error(message, opts \\ []) do
    %__MODULE__{
      code: :parse_error,
      message: message,
      details: %{
        position: Keyword.get(opts, :position),
        expected: Keyword.get(opts, :expected, []),
        partial: Keyword.get(opts, :partial)
      },
      suggestions: Keyword.get(opts, :suggestions, []),
      retry_guidance: Keyword.get(opts, :retry_guidance)
    }
  end

  @doc "Creates an entity-not-found error."
  def entity_not_found(entity, opts \\ []) do
    %__MODULE__{
      code: :entity_not_found,
      message: "Entity #{entity} not found in accessible scopes",
      similar_entities: Keyword.get(opts, :similar, []),
      retry_guidance: "Check entity namespace and name, or broaden scope"
    }
  end

  @doc "Creates a scope-access error."
  def scope_access(scope, opts \\ []) do
    %__MODULE__{
      code: :scope_access,
      message: "Scope #{scope} is not accessible from the current agent context",
      suggestions: Keyword.get(opts, :suggestions, []),
      retry_guidance: "Use a scope within your visibility hierarchy"
    }
  end
end
