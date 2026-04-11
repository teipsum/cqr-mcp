defmodule Cqr.Scope do
  @moduledoc """
  Scope hierarchy and resolution engine.

  Scope-first semantics: scope determines visibility BEFORE any data retrieval.
  Uses ETS cache (via `Cqr.Repo.ScopeTree`) for sub-millisecond lookups.

  Key functions:
  - `visible_scopes/1` — all scopes an agent can see (self + ancestors + descendants)
  - `authoritative_scope/2` — nearest scope containing an entity
  - `fallback_chain/2` — validated fallback resolution order
  - `accessible?/2` — can agent_scope see target_scope?

  Visibility is bidirectional along the hierarchy: a child scope can fall
  back to its ancestors, and a parent scope owns its descendants. Siblings
  remain isolated.

  See PROJECT_KNOWLEDGE.md Section 7.
  """

  alias Cqr.Grafeo.Server, as: GrafeoServer
  alias Cqr.Repo.ScopeTree

  @doc """
  Return all scopes visible from the given agent scope.
  Includes the scope itself, all ancestors, and all descendants.
  """
  def visible_scopes(agent_scope) when is_list(agent_scope) do
    ScopeTree.visible_scopes(agent_scope)
  end

  @doc """
  Check if `target_scope` is accessible from `agent_scope`.
  A scope is accessible if it's in the agent's visible scopes.
  """
  def accessible?(agent_scope, target_scope)
      when is_list(agent_scope) and is_list(target_scope) do
    target_scope in visible_scopes(agent_scope)
  end

  @doc """
  Find the authoritative scope for an entity given the agent's scope.
  Queries Grafeo for the entity's scope assignments and returns the
  nearest accessible scope, or an error.
  """
  def authoritative_scope(entity, agent_scope) when is_list(agent_scope) do
    {ns, name} = entity
    visible = visible_scopes(agent_scope)

    query =
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'})" <>
        "-[:IN_SCOPE]->(s:Scope) RETURN s.path"

    with {:ok, rows} <- GrafeoServer.query(query),
         entity_scopes = Enum.map(rows, fn r -> String.split(r["s.path"], ":") end),
         scope when not is_nil(scope) <- Enum.find(entity_scopes, fn s -> s in visible end) do
      {:ok, scope}
    else
      nil -> {:error, :not_visible}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validate and return a fallback chain.
  Each scope in the chain must exist. Returns the validated list or an error
  with the first invalid scope.
  """
  def fallback_chain(scopes, agent_scope) when is_list(scopes) and is_list(agent_scope) do
    visible = visible_scopes(agent_scope)

    invalid =
      Enum.find(scopes, fn scope ->
        not ScopeTree.scope_exists?(scope) or scope not in visible
      end)

    case invalid do
      nil -> {:ok, scopes}
      scope -> {:error, {:inaccessible_scope, scope}}
    end
  end

  @doc "Check if a scope exists in the hierarchy."
  def exists?(scope) when is_list(scope) do
    ScopeTree.scope_exists?(scope)
  end

  @doc "Get all scopes in the hierarchy."
  def all_scopes do
    ScopeTree.all_scopes()
  end
end
