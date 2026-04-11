defmodule Cqr.Engine.Trace do
  @moduledoc """
  TRACE execution path.

  Walks the provenance chain of an entity:

    1. Resolve the entity (so scope visibility is enforced and the
       current state is returned as part of the trace).
    2. Delegate to the adapter's `trace/3` to fetch AssertionRecord,
       CertificationRecords, SignalRecords, the DERIVED_FROM chain,
       and inbound references.

  Time-window and causal-depth handling live in the adapter so this
  module stays focused on scope validation and dispatch.
  """

  alias Cqr.Adapter.Grafeo, as: GrafeoAdapter
  alias Cqr.Repo.Semantic

  @doc """
  Execute a TRACE operation.

  Returns `{:ok, %Cqr.Result{}}` with one data row describing the full
  provenance chain for the target entity, or `{:error, %Cqr.Error{}}`
  when the entity is not visible or an adapter write fails.
  """
  def execute(%Cqr.Trace{} = ast, context) do
    agent_scope = Map.get(context, :scope) || raise "Agent scope is required"
    visible = Cqr.Scope.visible_scopes(agent_scope)
    scope_context = %{visible_scopes: visible}

    with {:ok, _entity_data} <- fetch_visible_entity(ast.entity, visible) do
      GrafeoAdapter.trace(ast, scope_context, [])
    end
  end

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
