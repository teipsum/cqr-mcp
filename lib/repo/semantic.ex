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
             "e.reputation, e.freshness_hours_ago, e.certified, " <>
             "e.certified_by, e.certified_at, e.certification_status, s.path"
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
  Get entities related to the given entity via OUTBOUND edges
  (the anchor entity is the edge source). Each result is tagged with
  `direction: "outbound"`. The relationship type is reported in its
  original stored direction.
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
        rows = maybe_filter_entities_by_scope(rows, visible_scope_paths, "b")

        related =
          Enum.map(rows, fn row ->
            %{
              entity: {row["b.namespace"], row["b.name"]},
              type: row["b.type"],
              description: row["b.description"],
              relationship: row["rel_type"],
              strength: row["r.strength"],
              direction: "outbound",
              owner: row["b.owner"],
              reputation: row["b.reputation"]
            }
          end)

        {:ok, related}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get entities related to the given entity via INBOUND edges
  (the anchor entity is the edge target). Each result is tagged with
  `direction: "inbound"`. The relationship type is reported in its
  original stored direction — e.g. for `churn_rate -[:CONTRIBUTES_TO]-> arr`,
  discovering inbound from `arr` returns `churn_rate` with relationship
  `"CONTRIBUTES_TO"` and direction `"inbound"`.
  """
  def related_entities_inbound({ns, name}, depth \\ 1, visible_scope_paths \\ nil) do
    depth_pattern = if depth > 1, do: "*1..#{depth}", else: ""

    case GrafeoServer.query(
           "MATCH (a:Entity)-[r#{depth_pattern}]->" <>
             "(b:Entity {namespace: '#{ns}', name: '#{name}'}) " <>
             "RETURN a.namespace, a.name, a.type, a.description, a.owner, " <>
             "a.reputation, type(r) AS rel_type, r.strength"
         ) do
      {:ok, rows} ->
        rows = maybe_filter_entities_by_scope(rows, visible_scope_paths, "a")

        related =
          Enum.map(rows, fn row ->
            %{
              entity: {row["a.namespace"], row["a.name"]},
              type: row["a.type"],
              description: row["a.description"],
              relationship: row["rel_type"],
              strength: row["r.strength"],
              direction: "inbound",
              owner: row["a.owner"],
              reputation: row["a.reputation"]
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

  defp maybe_filter_entities_by_scope(rows, nil, _prefix), do: rows

  defp maybe_filter_entities_by_scope(rows, visible_scope_paths, prefix) do
    # For related entities, check if each entity is in a visible scope.
    # `prefix` selects which row alias holds the related entity's fields:
    # "b" for outbound queries (anchor is source, related is target),
    # "a" for inbound queries (anchor is target, related is source).
    Enum.filter(rows, fn row ->
      {ns, name} = {row["#{prefix}.namespace"], row["#{prefix}.name"]}

      query =
        "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'})" <>
          "-[:IN_SCOPE]->(s:Scope) RETURN s.path"

      entity_in_visible_scope?(GrafeoServer.query(query), visible_scope_paths)
    end)
  end

  defp entity_in_visible_scope?({:ok, scope_rows}, visible_scope_paths) do
    visible_keys = Enum.map(visible_scope_paths, &Enum.join(&1, ":"))
    Enum.any?(scope_rows, fn sr -> sr["s.path"] in visible_keys end)
  end

  defp entity_in_visible_scope?(_other, _visible_scope_paths), do: false

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
      certified_by: nilify_empty(first["e.certified_by"]),
      certified_at: nilify_empty(first["e.certified_at"]),
      certification_status: nilify_empty(first["e.certification_status"]),
      scopes: scopes
    }
  end

  defp nilify_empty(nil), do: nil
  defp nilify_empty(""), do: nil
  defp nilify_empty(value), do: value

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
