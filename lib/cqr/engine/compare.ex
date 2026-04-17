defmodule Cqr.Engine.Compare do
  @moduledoc """
  COMPARE execution path.

  Performs a side-by-side evaluation of two or more entities:

    1. Validate that at least two entity references were supplied.
    2. RESOLVE each entity (so scope visibility is enforced; an
       agent cannot compare across entities it cannot see).
    3. Delegate to the adapter's `compare/3` to fetch per-entity
       relationships and build the comparison structure (shared
       relationships, differing properties, quality deltas, and
       per-entity relationship sets).

  The adapter does the heavy data assembly; this module stays
  focused on input validation and visibility enforcement so the
  governance boundary remains in the engine.
  """

  alias Cqr.Engine.Planner
  alias Cqr.Repo.Semantic

  @doc """
  Execute a COMPARE operation.

  Returns `{:ok, %Cqr.Result{}}` with one data row holding the
  comparison structure, or `{:error, %Cqr.Error{}}` on missing
  fields, too few entities, or a target entity that is not visible
  to the agent.
  """
  def execute(%Cqr.Compare{} = ast, context) do
    visible = resolve_visible_scopes(context)
    scope_context = %{visible_scopes: visible}

    with {:ok, adapter} <- Planner.resolve_adapter(context, :compare),
         :ok <- validate_entity_count(ast.entities),
         :ok <- ensure_unique(ast.entities),
         :ok <- ensure_all_visible(ast.entities, visible) do
      adapter.compare(ast, scope_context, [])
    end
  end

  defp resolve_visible_scopes(context) do
    Map.get_lazy(context, :visible_scopes, fn ->
      agent_scope = Map.get(context, :scope) || raise "Agent scope is required"
      Cqr.Scope.visible_scopes(agent_scope)
    end)
  end

  # --- Validation ---

  defp validate_entity_count(entities) when length(entities) >= 2, do: :ok

  defp validate_entity_count(_) do
    {:error,
     %Cqr.Error{
       code: :missing_required_field,
       message: "COMPARE requires at least two entity references",
       retry_guidance:
         "Pass two or more entities, e.g. " <>
           "COMPARE entity:product:churn_rate, entity:product:nps"
     }}
  end

  # Comparing an entity against itself is never useful and would short-circuit
  # the differing/shared computation (everything becomes shared, nothing
  # differs). Reject duplicates up front rather than returning a degenerate
  # result the caller has to interpret.
  defp ensure_unique(entities) do
    if length(entities) == length(Enum.uniq(entities)) do
      :ok
    else
      duplicates =
        entities
        |> Enum.frequencies()
        |> Enum.filter(fn {_e, count} -> count > 1 end)
        |> Enum.map(fn {e, _} -> Cqr.Types.format_entity(e) end)

      {:error,
       %Cqr.Error{
         code: :validation_error,
         message:
           "COMPARE requires distinct entities; duplicates: " <>
             Enum.join(duplicates, ", "),
         retry_guidance: "Remove duplicate entity references from the COMPARE list"
       }}
    end
  end

  defp ensure_all_visible(entities, visible) do
    Enum.reduce_while(entities, :ok, fn entity, _ ->
      case Semantic.get_entity(entity, visible) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, reason} when reason in [:not_found, :not_visible] ->
          {:halt,
           {:error,
            Cqr.Error.entity_not_found(Cqr.Types.format_entity(entity),
              similar: []
            )}}

        {:error, reason} ->
          {:halt,
           {:error, %Cqr.Error{code: :adapter_error, message: "Grafeo error: #{inspect(reason)}"}}}
      end
    end)
  end
end
