defmodule Cqr.Engine.Refresh do
  @moduledoc """
  REFRESH execution path.

  Scans the entities visible to the agent for staleness above the
  requested threshold, sorting most-stale-first. Scope narrowing (the
  optional `WITHIN` clause or the agent's own sandbox) is applied
  before any data is materialised.
  """

  alias Cqr.Adapter.Grafeo, as: GrafeoAdapter

  @doc """
  Execute a REFRESH CHECK operation.

  The `visible_scopes` list on the context is assumed to already be
  narrowed by `Cqr.Engine.narrow_visible_scopes/2` to account for any
  `WITHIN` clause.
  """
  def execute(%Cqr.Refresh{} = ast, context) do
    visible = Map.get(context, :visible_scopes, [])
    scope_context = %{visible_scopes: visible}

    GrafeoAdapter.refresh_check(ast, scope_context, [])
  end
end
