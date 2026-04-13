defmodule Cqr.Engine.Hypothesize do
  @moduledoc """
  HYPOTHESIZE execution path.

  Projects the downstream impact of an assumed change to an entity:

    1. Resolve the target entity (so scope visibility is enforced and
       the current baseline values are known).
    2. Delegate to the adapter's `hypothesize/3` to walk the relationship
       graph outward and compute the blast radius with confidence decay.

  Scope narrowing and baseline validation live here; graph traversal and
  confidence arithmetic live in the adapter so this module stays focused
  on governance and dispatch.
  """

  alias Cqr.Engine.Planner
  alias Cqr.Repo.Semantic

  @doc """
  Execute a HYPOTHESIZE operation.

  Returns `{:ok, %Cqr.Result{}}` with one data row describing the
  hypothetical change and the projected blast radius, or
  `{:error, %Cqr.Error{}}` when the entity is not visible or the
  hypothesis is malformed.
  """
  def execute(%Cqr.Hypothesize{} = ast, context) do
    visible = resolve_visible_scopes(context)
    scope_context = %{visible_scopes: visible}

    with {:ok, adapter} <- Planner.resolve_adapter(context, :hypothesize),
         {:ok, _} <- validate_changes(ast),
         {:ok, _entity_data} <- fetch_visible_entity(ast.entity, visible) do
      adapter.hypothesize(ast, scope_context, [])
    end
  end

  defp resolve_visible_scopes(context) do
    Map.get_lazy(context, :visible_scopes, fn ->
      agent_scope = Map.get(context, :scope) || raise "Agent scope is required"
      Cqr.Scope.visible_scopes(agent_scope)
    end)
  end

  defp validate_changes(%Cqr.Hypothesize{changes: []}) do
    {:error,
     %Cqr.Error{
       code: :invalid_input,
       message: "HYPOTHESIZE requires at least one CHANGE clause"
     }}
  end

  defp validate_changes(%Cqr.Hypothesize{changes: changes}) do
    case Enum.find(changes, fn c -> not valid_change?(c) end) do
      nil ->
        {:ok, changes}

      bad ->
        {:error,
         %Cqr.Error{
           code: :invalid_input,
           message:
             "Unsupported CHANGE clause: #{inspect(bad)}. V1 supports reputation with a numeric target in [0.0, 1.0]."
         }}
    end
  end

  defp valid_change?(%{field: :reputation, value: v}) when is_float(v),
    do: v >= 0.0 and v <= 1.0

  defp valid_change?(_), do: false

  defp fetch_visible_entity(entity, visible) do
    case Semantic.get_entity(entity, visible) do
      {:ok, data} ->
        {:ok, data}

      {:error, :not_found} ->
        {:error,
         Cqr.Error.entity_not_found(Cqr.Types.format_entity(entity),
           similar: Semantic.search_entities(elem(entity, 1), visible)
         )}

      {:error, :not_visible} ->
        {:error,
         Cqr.Error.entity_not_found(Cqr.Types.format_entity(entity),
           similar: Semantic.search_entities(elem(entity, 1), visible)
         )}

      {:error, reason} ->
        {:error, %Cqr.Error{code: :adapter_error, message: "Grafeo error: #{inspect(reason)}"}}
    end
  end
end
