defmodule Cqr.Engine.Assert do
  @moduledoc """
  ASSERT execution path.

  Orchestrates the validation and execution of an ASSERT expression:

    1. Validate that all required AST fields are populated (the parser
       accepts clauses in any order, so presence is checked here).
    2. Resolve the target scope (explicit IN clause or agent's active scope).
    3. Delegate the actual Grafeo writes to the adapter via `assert/3`.

  Unlike `Cqr.Engine.Certify` (which writes inline), this module delegates
  to the adapter. This keeps the "how" of storage isolated from the "what"
  of protocol-level validation — the same pattern that RESOLVE and DISCOVER
  follow.

  Relationships may come from either the CQR expression's `RELATIONSHIPS`
  clause (populated on the AST by the parser) or from the engine context
  (`context[:relationships]`) for callers like the MCP tool layer that
  parse relationships independently. The AST value wins when present.
  """

  alias Cqr.Engine.Planner

  @doc """
  Execute an ASSERT operation.

  Returns `{:ok, %Cqr.Result{}}` with the new entity in `data` and the
  quality envelope populated with the asserting agent's provenance, or
  `{:error, %Cqr.Error{}}` with informative details.
  """
  def execute(%Cqr.Assert{} = ast, context) do
    agent_id = Map.get(context, :agent_id, "anonymous")
    relationships = ast.relationships || Map.get(context, :relationships, [])

    visible = resolve_visible_scopes(context)
    scope_context = %{visible_scopes: visible}

    with {:ok, adapter} <- Planner.resolve_adapter(context, :assert),
         :ok <- validate_required_fields(ast),
         :ok <- validate_confidence(ast.confidence),
         :ok <- validate_relationships(relationships) do
      adapter.assert(ast, scope_context,
        agent_id: agent_id,
        relationships: relationships
      )
    end
  end

  defp resolve_visible_scopes(context) do
    Map.get_lazy(context, :visible_scopes, fn ->
      agent_scope = Map.get(context, :scope) || raise "Agent scope is required"
      Cqr.Scope.visible_scopes(agent_scope)
    end)
  end

  # --- Validation ---

  defp validate_required_fields(%Cqr.Assert{} = ast) do
    # Accumulate missing fields by prepending, then reverse to restore
    # declaration order for the error message.
    missing =
      []
      |> check_field(ast.entity, "entity")
      |> check_field(ast.type, "TYPE")
      |> check_field(ast.description, "DESCRIPTION")
      |> check_field(ast.intent, "INTENT")
      |> check_derived_from(ast.derived_from)
      |> Enum.reverse()

    case missing do
      [] ->
        :ok

      fields ->
        {:error,
         %Cqr.Error{
           code: :missing_required_field,
           message: "ASSERT is missing required fields: #{Enum.join(fields, ", ")}",
           details: %{missing: fields},
           retry_guidance:
             "ASSERT requires entity, TYPE, DESCRIPTION, INTENT, and DERIVED_FROM " <>
               "(at least one source entity)"
         }}
    end
  end

  defp check_field(acc, nil, field), do: [field | acc]
  defp check_field(acc, "", field), do: [field | acc]
  defp check_field(acc, _, _), do: acc

  defp check_derived_from(acc, nil), do: ["DERIVED_FROM" | acc]
  defp check_derived_from(acc, []), do: ["DERIVED_FROM" | acc]
  defp check_derived_from(acc, list) when is_list(list), do: acc

  defp validate_confidence(nil), do: :ok

  defp validate_confidence(score) when is_float(score) and score >= 0.0 and score <= 1.0,
    do: :ok

  defp validate_confidence(score) do
    {:error,
     %Cqr.Error{
       code: :validation_error,
       message: "CONFIDENCE must be between 0.0 and 1.0 (got #{inspect(score)})",
       retry_guidance: "Use a decimal value like 0.5, 0.65, 0.9"
     }}
  end

  defp validate_relationships([]), do: :ok

  defp validate_relationships(rels) when is_list(rels) do
    case Enum.find(rels, &invalid_strength?/1) do
      nil ->
        :ok

      %{type: type, strength: strength} ->
        {:error,
         %Cqr.Error{
           code: :validation_error,
           message:
             "RELATIONSHIPS strength must be between 0.0 and 1.0 " <>
               "(got #{inspect(strength)} for #{type})",
           retry_guidance: "Use a decimal value like 0.5, 0.75, 0.9"
         }}
    end
  end

  defp invalid_strength?(%{strength: s}) when is_float(s) and s >= 0.0 and s <= 1.0, do: false
  defp invalid_strength?(_), do: true
end
