defmodule Cqr.Repo.Semantic do
  @moduledoc """
  Semantic Definition Repository.

  Manages entity queries backed by the embedded Grafeo instance.
  All queries go through `Cqr.Grafeo.Server.query/1`.
  """

  alias Cqr.Grafeo.Server, as: GrafeoServer

  @doc "Check if an entity exists."
  def entity_exists?({ns, name}) do
    case GrafeoServer.query(
           "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}) RETURN count(e)"
         ) do
      {:ok, [%{"countnonnull(...)" => count}]} -> count > 0
      _ -> false
    end
  end

  @doc """
  Get an entity by namespace and name, optionally filtered to visible scopes.
  Returns `{:ok, entity_map}` or `{:error, :not_found}`.
  """
  def get_entity({ns, name}, visible_scope_paths \\ nil) do
    case GrafeoServer.query(
           "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'})" <>
             "-[:IN_SCOPE]->(s:Scope) " <>
             "RETURN e.namespace, e.name, e.type, e.description, e.owner, " <>
             "e.reputation, e.freshness_hours_ago, e.certified, s.path"
         ) do
      {:ok, []} ->
        {:error, :not_found}

      {:ok, rows} ->
        rows = maybe_filter_by_scope(rows, visible_scope_paths)

        case rows do
          [] -> {:error, :not_visible}
          _ -> {:ok, build_entity(rows)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Get all entities within a scope (by scope name)."
  def entities_in_scope(scope_path) when is_list(scope_path) do
    scope_key = Enum.join(scope_path, ":")

    case GrafeoServer.query(
           "MATCH (e:Entity)-[:IN_SCOPE]->(s:Scope {path: '#{scope_key}'}) " <>
             "RETURN e.namespace, e.name, e.type, e.description, e.owner, " <>
             "e.reputation, e.freshness_hours_ago"
         ) do
      {:ok, rows} ->
        {:ok, Enum.map(rows, &row_to_entity_summary/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get entities related to the given entity, with relationship type and strength.
  """
  def related_entities({ns, name}, depth \\ 1, visible_scope_paths \\ nil) do
    depth_pattern = if depth > 1, do: "*1..#{depth}", else: ""

    case GrafeoServer.query(
           "MATCH (a:Entity {namespace: '#{ns}', name: '#{name}'})" <>
             "-[r#{depth_pattern}]->(b:Entity) " <>
             "RETURN b.namespace, b.name, b.type, b.description, b.owner, " <>
             "b.reputation, type(r) AS rel_type, r.strength"
         ) do
      {:ok, rows} ->
        rows = maybe_filter_entities_by_scope(rows, visible_scope_paths)

        related =
          Enum.map(rows, fn row ->
            %{
              entity: {row["b.namespace"], row["b.name"]},
              type: row["b.type"],
              description: row["b.description"],
              relationship: row["rel_type"],
              strength: row["r.strength"],
              owner: row["b.owner"],
              reputation: row["b.reputation"]
            }
          end)

        {:ok, related}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Find entities similar to a search term (by name or description substring)."
  def search_entities(term, visible_scope_paths \\ nil) do
    case GrafeoServer.query(
           "MATCH (e:Entity)-[:IN_SCOPE]->(s:Scope) " <>
             "WHERE e.name CONTAINS '#{String.downcase(term)}' " <>
             "OR e.description CONTAINS '#{term}' " <>
             "RETURN e.namespace, e.name, e.type, e.description, s.path"
         ) do
      {:ok, rows} ->
        rows = maybe_filter_by_scope(rows, visible_scope_paths)

        Enum.map(rows, fn row ->
          {row["e.namespace"], row["e.name"]}
        end)
        |> Enum.uniq()

      {:error, _} ->
        []
    end
  end

  # --- Private ---

  defp maybe_filter_by_scope(rows, nil), do: rows

  defp maybe_filter_by_scope(rows, visible_scope_paths) do
    visible_keys = Enum.map(visible_scope_paths, &Enum.join(&1, ":"))
    Enum.filter(rows, fn row -> row["s.path"] in visible_keys end)
  end

  defp maybe_filter_entities_by_scope(rows, nil), do: rows

  defp maybe_filter_entities_by_scope(rows, visible_scope_paths) do
    # For related entities, check if each entity is in a visible scope
    Enum.filter(rows, fn row ->
      {ns, name} = {row["b.namespace"], row["b.name"]}

      case Cqr.Grafeo.Server.query(
             "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'})" <>
               "-[:IN_SCOPE]->(s:Scope) RETURN s.path"
           ) do
        {:ok, scope_rows} ->
          visible_keys = Enum.map(visible_scope_paths, &Enum.join(&1, ":"))
          Enum.any?(scope_rows, fn sr -> sr["s.path"] in visible_keys end)

        _ ->
          false
      end
    end)
  end

  defp build_entity(rows) do
    first = hd(rows)
    scopes = Enum.map(rows, fn r -> String.split(r["s.path"], ":") end) |> Enum.uniq()

    %{
      namespace: first["e.namespace"],
      name: first["e.name"],
      type: first["e.type"],
      description: first["e.description"],
      owner: first["e.owner"],
      reputation: first["e.reputation"],
      freshness_hours_ago: first["e.freshness_hours_ago"],
      certified: first["e.certified"],
      scopes: scopes
    }
  end

  defp row_to_entity_summary(row) do
    %{
      namespace: row["e.namespace"],
      name: row["e.name"],
      type: row["e.type"],
      description: row["e.description"],
      owner: row["e.owner"],
      reputation: row["e.reputation"]
    }
  end
end
