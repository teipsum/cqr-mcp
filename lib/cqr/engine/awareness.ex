defmodule Cqr.Engine.Awareness do
  @moduledoc """
  AWARENESS execution path.

  Reads ambient agent activity from audit nodes (`AssertionRecord`,
  `CertificationRecord`, `SignalRecord`) attached to entities visible
  to the calling agent. The `visible_scopes` list on the context is
  assumed to already be narrowed by `Cqr.Engine.narrow_visible_scopes/2`
  to honour any `WITHIN` clause and the agent's own sandbox.

  No mutation is performed; the caller never appears in the audit trail
  for issuing AWARENESS.
  """

  alias Cqr.Adapter.Grafeo, as: GrafeoAdapter

  @doc """
  Execute an AWARENESS scan.

  Returns `{:ok, %Cqr.Result{}}` with one row per agent observed in the
  visible scopes, sorted by recent activity volume.
  """
  def execute(%Cqr.Awareness{} = ast, context) do
    visible = Map.get(context, :visible_scopes, [])
    scope_context = %{visible_scopes: visible}

    GrafeoAdapter.awareness(ast, scope_context, [])
  end
end
