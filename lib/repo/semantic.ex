defmodule Cqr.Repo.Semantic do
  @moduledoc """
  Semantic Definition Repository.

  Manages entity queries backed by the embedded Grafeo instance.
  All queries go through `Cqr.Grafeo.Server.query/1`.
  """

  alias Cqr.Grafeo.Server, as: GrafeoServer

  # Hard ceiling on the number of rows a single traversal can materialize.
  # The DISCOVER grammar exposes an explicit LIMIT clause; when the caller
  # does not supply one, this cap prevents a high-degree hub entity from
  # materializing an unbounded result set through the NIF. 1000 is well
  # above any realistic DISCOVER consumer (the spec documents 20 as the
  # practical default) while bounded enough that a 10k-edge hub still
  # returns in well under a second.
  @default_traversal_limit 1000

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

  Accepts an optional `limit` (defaults to `@default_traversal_limit`)
  which is passed through to the underlying Cypher `LIMIT` clause.

  The scope filter is applied inside the MATCH as a single join against
  the target entity's IN_SCOPE edges; there is no N+1 follow-up query
  per result row. `DISTINCT` collapses the rows a multi-scope target
  would otherwise duplicate so the result set stays proportional to the
  number of traversed edges, not to edges × scopes.
  """
  def related_entities(entity, depth \\ 1, visible_scope_paths \\ nil, limit \\ nil)

  def related_entities(_entity, _depth, [], _limit), do: {:ok, []}

  def related_entities({ns, name}, depth, visible_scope_paths, limit) do
    traverse_related(
      traversal_query(:outbound, ns, name, depth, visible_scope_paths, limit),
      "b",
      "outbound"
    )
  end

  @doc """
  Get entities related to the given entity via INBOUND edges
  (the anchor entity is the edge target). Each result is tagged with
  `direction: "inbound"`. The relationship type is reported in its
  original stored direction — e.g. for `churn_rate -[:CONTRIBUTES_TO]-> arr`,
  discovering inbound from `arr` returns `churn_rate` with relationship
  `"CONTRIBUTES_TO"` and direction `"inbound"`.

  Scope filtering is inlined in the MATCH, same as
  `related_entities/4` — no per-row follow-up query.
  """
  def related_entities_inbound(entity, depth \\ 1, visible_scope_paths \\ nil, limit \\ nil)

  def related_entities_inbound(_entity, _depth, [], _limit), do: {:ok, []}

  def related_entities_inbound({ns, name}, depth, visible_scope_paths, limit) do
    traverse_related(
      traversal_query(:inbound, ns, name, depth, visible_scope_paths, limit),
      "a",
      "inbound"
    )
  end

  # Build the single-query Cypher for an outbound or inbound traversal.
  # When `visible_scope_paths` is non-nil the target entity's IN_SCOPE
  # edge is joined inline with a `WHERE s.path IN [...]` filter; when it
  # is nil no scope constraint is applied (callers that pass nil are
  # explicitly opting out of scope governance — currently the test suite
  # and semantic-level direct calls). `DISTINCT` prevents the Cartesian
  # product that would otherwise result from a target entity sitting in
  # multiple visible scopes. `LIMIT` caps the materialized row count.
  defp traversal_query(direction, ns, name, depth, visible_scope_paths, limit) do
    depth_pattern = if depth > 1, do: "*1..#{depth}", else: ""

    {anchor_pattern, result_alias} =
      case direction do
        :outbound ->
          {"(a:Entity {namespace: '#{ns}', name: '#{name}'})" <>
             "-[r#{depth_pattern}]->(b:Entity)", "b"}

        :inbound ->
          {"(a:Entity)-[r#{depth_pattern}]->" <>
             "(b:Entity {namespace: '#{ns}', name: '#{name}'})", "a"}
      end

    match_clause = "MATCH " <> anchor_pattern

    {scope_clause, where_clause} =
      case visible_scope_paths do
        nil ->
          {"", ""}

        paths when is_list(paths) ->
          scope_list = Enum.map_join(paths, ", ", fn seg -> "\"#{Enum.join(seg, ":")}\"" end)

          {
            ", (#{result_alias})-[:IN_SCOPE]->(s:Scope)",
            " WHERE s.path IN [#{scope_list}]"
          }
      end

    projection =
      "RETURN DISTINCT " <>
        "#{result_alias}.namespace, #{result_alias}.name, #{result_alias}.type, " <>
        "#{result_alias}.description, #{result_alias}.owner, #{result_alias}.reputation, " <>
        "type(r) AS rel_type, r.strength"

    limit_clause = " LIMIT #{limit || @default_traversal_limit}"

    match_clause <> scope_clause <> where_clause <> " " <> projection <> limit_clause
  end

  defp traverse_related(query, row_alias, direction_label) do
    case GrafeoServer.query(query) do
      {:ok, rows} ->
        related =
          Enum.map(rows, fn row ->
            %{
              entity: {row["#{row_alias}.namespace"], row["#{row_alias}.name"]},
              type: row["#{row_alias}.type"],
              description: row["#{row_alias}.description"],
              relationship: row["rel_type"],
              strength: row["r.strength"],
              direction: direction_label,
              owner: row["#{row_alias}.owner"],
              reputation: row["#{row_alias}.reputation"]
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
