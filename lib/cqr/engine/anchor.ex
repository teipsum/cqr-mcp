defmodule Cqr.Engine.Anchor do
  @moduledoc """
  ANCHOR execution path.

  Evaluates the composite confidence of a chain of entities used
  together as a reasoning step. For each entity the engine:

    1. Resolves it under the agent's visible scopes (so an entity the
       agent cannot see is flagged `missing`, not silently skipped).
    2. Collects reputation, freshness, certification, and ownership.

  Then it computes:

    * `weakest_link_confidence` — the minimum reputation across the
      chain. Missing entities count as `0.0`. This is the epistemic
      floor of the chain: a decision can't trust the chain further
      than its weakest link.
    * `average_reputation` — arithmetic mean over the entities that
      resolved, for a smoother second opinion.
    * `chain_confidence` — the weakest-link floor multiplied by
      penalty factors for uncertified links (×0.8 each) and missing
      links (×0.5 each). Never exceeds the floor.
    * `missing`, `uncertified`, `stale`, `below_reputation` — bucketed
      lists of entity references so an agent can see, at a glance,
      exactly which links are the problem.
    * `recommendations` — imperative sentences the agent can act on:
      certify X, refresh Y, raise reputation on Z.

  The engine calls the adapter's `anchor/3` so alternative backends can
  provide richer per-entity metadata; the default Grafeo adapter walks
  `Cqr.Repo.Semantic.get_entity/2` for each chain link.
  """

  alias Cqr.Adapter.Grafeo, as: GrafeoAdapter

  @doc """
  Execute an ANCHOR operation.

  Returns `{:ok, %Cqr.Result{}}` with one data row describing the
  composite assessment, or `{:error, %Cqr.Error{}}` when the input
  chain is empty.
  """
  def execute(%Cqr.Anchor{entities: []}, _context) do
    {:error,
     %Cqr.Error{
       code: :invalid_input,
       message: "ANCHOR requires at least one entity reference",
       retry_guidance: "Pass a non-empty comma-separated entity list"
     }}
  end

  def execute(%Cqr.Anchor{} = ast, context) do
    visible = resolve_visible_scopes(context)
    scope_context = %{visible_scopes: visible}

    GrafeoAdapter.anchor(ast, scope_context, [])
  end

  defp resolve_visible_scopes(context) do
    Map.get_lazy(context, :visible_scopes, fn ->
      agent_scope = Map.get(context, :scope) || raise "Agent scope is required"
      Cqr.Scope.visible_scopes(agent_scope)
    end)
  end
end
