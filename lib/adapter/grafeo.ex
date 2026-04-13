defmodule Cqr.Adapter.Grafeo do
  @moduledoc """
  Grafeo adapter — implements the adapter behaviour contract
  using the embedded Grafeo NIF.

  This is the primary adapter for V1. It handles RESOLVE and DISCOVER
  by constructing GQL queries against the embedded database.
  Scope constraints are part of the query, not a post-filter.
  """

  @behaviour Cqr.Adapter.Behaviour

  alias Cqr.Grafeo.Server, as: GrafeoServer
  alias Cqr.Repo.Seed
  alias Cqr.Repo.Semantic

  @impl true
  def capabilities,
    do: [:resolve, :discover, :assert, :trace, :signal, :refresh, :awareness, :hypothesize]

  @impl true
  def resolve(%Cqr.Resolve{entity: entity} = expression, scope_context, _opts) do
    visible = scope_context[:visible_scopes] || []

    case Semantic.get_entity(entity, visible) do
      {:ok, entity_data} ->
        result = normalize_entity(entity_data, expression)
        {:ok, result}

      {:error, :not_found} ->
        similar = Semantic.search_entities(elem(entity, 1), visible)

        {:error, Cqr.Error.entity_not_found(Cqr.Types.format_entity(entity), similar: similar)}

      {:error, :not_visible} ->
        {:error,
         Cqr.Error.entity_not_found(Cqr.Types.format_entity(entity),
           similar: Semantic.search_entities(elem(entity, 1), visible)
         )}

      {:error, reason} ->
        {:error, %Cqr.Error{code: :adapter_error, message: "Grafeo error: #{inspect(reason)}"}}
    end
  end

  @impl true
  def discover(%Cqr.Discover{related_to: related_to} = expression, scope_context, _opts) do
    visible = scope_context[:visible_scopes] || []
    depth = expression.depth || 2
    direction = expression.direction || :both
    limit = expression.limit

    case related_to do
      {:entity, entity} ->
        case fetch_related(entity, depth, visible, direction, limit) do
          {:ok, related} ->
            result = normalize_discovery(related, entity, expression)
            {:ok, result}

          {:error, reason} ->
            {:error,
             %Cqr.Error{code: :adapter_error, message: "Grafeo error: #{inspect(reason)}"}}
        end

      {:search, term} ->
        search_discover(term, visible, expression)
    end
  end

  # Dispatch to the right semantic query (or both) based on the requested
  # edge direction. Edges are stored once, directionally; "both" performs
  # two queries and unions the results, tagged with their direction.
  # The `limit` is passed through to the underlying Cypher LIMIT clause
  # so high-degree hub entities cannot materialize an unbounded result
  # set through the NIF. For the `:both` case each side is capped
  # independently; the union may exceed the limit by up to 2× which is
  # acceptable for a governance budget.
  defp fetch_related(entity, depth, visible, :outbound, limit) do
    Semantic.related_entities(entity, depth, visible, limit)
  end

  defp fetch_related(entity, depth, visible, :inbound, limit) do
    Semantic.related_entities_inbound(entity, depth, visible, limit)
  end

  defp fetch_related(entity, depth, visible, :both, limit) do
    with {:ok, out} <- Semantic.related_entities(entity, depth, visible, limit),
         {:ok, inb} <- Semantic.related_entities_inbound(entity, depth, visible, limit) do
      {:ok, out ++ inb}
    end
  end

  # --- DISCOVER: free-text multi-paradigm search ---
  #
  # Governance-first ordering (patent Section 8.6): a single scope-filtered
  # Cypher query materializes the candidate set of visible entities with
  # their stored embeddings, then Elixir computes both BM25-style text
  # relevance and cosine vector similarity against the query. Results are
  # merged by entity identity with `source: "text" | "vector" | "both"`
  # attribution and ranked by combined score.
  #
  # The scope IN filter runs inside the MATCH, not in a post-filter, so
  # no entity outside the agent's visible scope set is ever materialized.

  @vector_top_k 10

  defp search_discover(term, visible, expression) do
    case fetch_candidates(visible) do
      {:ok, []} ->
        {:ok, empty_search_result()}

      {:ok, candidates} ->
        query_embedding = Seed.pseudo_embedding(term)
        ranked = rank_candidates(candidates, term, query_embedding)
        limited = maybe_limit(ranked, expression.limit)
        {:ok, build_search_result(limited)}

      {:error, reason} ->
        {:error,
         %Cqr.Error{
           code: :adapter_error,
           message: "Grafeo search error: #{inspect(reason)}"
         }}
    end
  end

  defp fetch_candidates([]), do: {:ok, []}

  defp fetch_candidates(visible_scopes) do
    scope_list =
      Enum.map_join(visible_scopes, ", ", fn segments -> "\"#{Enum.join(segments, ":")}\"" end)

    query =
      "MATCH (e:Entity)-[:IN_SCOPE]->(s:Scope) " <>
        "WHERE s.path IN [#{scope_list}] " <>
        "RETURN e.namespace, e.name, e.type, e.description, e.owner, " <>
        "e.reputation, e.certified, e.embedding, s.path"

    case GrafeoServer.query(query) do
      {:ok, rows} -> {:ok, dedupe_by_entity(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  # An entity with a secondary IN_SCOPE edge (e.g. product:nps in both
  # product and customer_success) appears once per visible scope path.
  # Collapse to one row per entity, keeping the first row and the list
  # of every scope path the entity sits in.
  defp dedupe_by_entity(rows) do
    rows
    |> Enum.group_by(fn row -> {row["e.namespace"], row["e.name"]} end)
    |> Enum.map(fn {_key, grouped} ->
      paths = Enum.map(grouped, & &1["s.path"])
      {hd(grouped), paths}
    end)
  end

  # Rank the candidate set by text relevance + vector similarity, merging
  # by entity identity. Every returned map has a `source` tag.
  defp rank_candidates(candidates, term, query_embedding) do
    normalized_term = String.downcase(term)

    scored =
      Enum.map(candidates, fn {row, paths} ->
        text_score = text_relevance(row, normalized_term)
        similarity = vector_similarity(row["e.embedding"], query_embedding)

        %{
          row: row,
          scope_paths: paths,
          text_score: text_score,
          similarity: similarity
        }
      end)

    text_hits = Enum.filter(scored, fn s -> s.text_score > 0 end)

    vector_hits =
      scored
      |> Enum.filter(fn s -> is_float(s.similarity) and s.similarity > 0.0 end)
      |> Enum.sort_by(fn s -> -s.similarity end)
      |> Enum.take(@vector_top_k)

    merge_modalities(text_hits, vector_hits)
  end

  # Simple case-insensitive substring count across name + description.
  # This stands in for BM25 since Grafeo v0.5 exposes no fulltext
  # procedure. Score = (name hits * 2) + (description hits).
  defp text_relevance(row, normalized_term) do
    name = String.downcase(row["e.name"] || "")
    desc = String.downcase(row["e.description"] || "")

    name_hits = substring_count(name, normalized_term)
    desc_hits = substring_count(desc, normalized_term)

    name_hits * 2 + desc_hits
  end

  defp substring_count("", _needle), do: 0
  defp substring_count(_haystack, ""), do: 0

  defp substring_count(haystack, needle) do
    haystack
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end

  defp vector_similarity(nil, _query), do: nil
  defp vector_similarity([], _query), do: nil

  defp vector_similarity(entity_vec, query_vec)
       when is_list(entity_vec) and is_list(query_vec) do
    cosine_similarity(entity_vec, query_vec)
  end

  defp cosine_similarity(a, b) when length(a) != length(b), do: 0.0

  defp cosine_similarity(a, b) do
    {dot, mag_a_sq, mag_b_sq} =
      a
      |> Enum.zip(b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {d, ma, mb} ->
        {d + x * y, ma + x * x, mb + y * y}
      end)

    mag_a = :math.sqrt(mag_a_sq)
    mag_b = :math.sqrt(mag_b_sq)

    cond do
      mag_a == 0.0 -> 0.0
      mag_b == 0.0 -> 0.0
      true -> dot / (mag_a * mag_b)
    end
  end

  # Merge text_hits and vector_hits by entity identity, tagging each
  # result with the retrieval modality that surfaced it. Results that
  # appear in both modalities carry source: "both" and keep both scores.
  # Ranking: results from either modality are ordered by combined score
  # (text normalized to [0, 1] + similarity).
  defp merge_modalities(text_hits, vector_hits) do
    max_text =
      text_hits
      |> Enum.map(& &1.text_score)
      |> Enum.max(fn -> 1 end)

    by_key = %{}

    by_key =
      Enum.reduce(text_hits, by_key, fn hit, acc ->
        key = {hit.row["e.namespace"], hit.row["e.name"]}
        Map.put(acc, key, %{hit: hit, source: "text"})
      end)

    by_key =
      Enum.reduce(vector_hits, by_key, fn hit, acc ->
        key = {hit.row["e.namespace"], hit.row["e.name"]}

        case Map.fetch(acc, key) do
          {:ok, %{source: "text"}} ->
            Map.put(acc, key, %{hit: hit, source: "both"})

          _ ->
            Map.put(acc, key, %{hit: hit, source: "vector"})
        end
      end)

    by_key
    |> Map.values()
    |> Enum.map(fn %{hit: hit, source: source} ->
      text_normalized =
        case max_text do
          0 -> 0.0
          m -> hit.text_score / m
        end

      combined = text_normalized + (hit.similarity || 0.0)
      build_search_row(hit, source, combined)
    end)
    |> Enum.sort_by(fn m -> -m.combined_score end)
  end

  defp build_search_row(hit, source, combined) do
    row = hit.row

    %{
      entity: {row["e.namespace"], row["e.name"]},
      namespace: row["e.namespace"],
      name: row["e.name"],
      type: row["e.type"],
      description: row["e.description"],
      owner: row["e.owner"],
      reputation: row["e.reputation"],
      certified: row["e.certified"],
      scopes: Enum.map(hit.scope_paths, fn path -> String.split(path, ":") end),
      source: source,
      text_score: hit.text_score,
      similarity: hit.similarity,
      combined_score: combined
    }
  end

  defp maybe_limit(results, nil), do: results
  defp maybe_limit(results, n) when is_integer(n) and n > 0, do: Enum.take(results, n)
  defp maybe_limit(results, _), do: results

  defp empty_search_result do
    %Cqr.Result{data: [], sources: ["grafeo"], quality: %Cqr.Quality{}}
  end

  defp build_search_result([]), do: empty_search_result()

  defp build_search_result(ranked) do
    top = hd(ranked)

    %Cqr.Result{
      data: ranked,
      sources: ["grafeo"],
      quality: %Cqr.Quality{
        reputation: top[:reputation],
        owner: top[:owner],
        provenance: "DISCOVER multi-paradigm search (graph + text + vector)"
      }
    }
  end

  @impl true
  def assert(%Cqr.Assert{} = expression, scope_context, opts) do
    visible = scope_context[:visible_scopes] || []
    agent_id = Keyword.get(opts, :agent_id, "anonymous")
    relationships = Keyword.get(opts, :relationships, [])

    with {:ok, target_scope} <- resolve_target_scope(expression, visible),
         :ok <- ensure_entity_absent(expression.entity),
         :ok <- ensure_derived_from_accessible(expression.derived_from, visible),
         :ok <- ensure_relationship_targets_accessible(relationships, visible),
         {:ok, record_id} <- generate_record_id(),
         :ok <- write_entity_node(expression, agent_id),
         :ok <- write_in_scope_edge(expression.entity, target_scope),
         :ok <- write_derived_from_edges(expression, agent_id),
         :ok <- write_relationship_edges(expression.entity, relationships),
         :ok <- write_assertion_record(expression, agent_id, record_id, target_scope),
         :ok <- write_asserted_by_edge(expression.entity, record_id) do
      result = build_result(expression, agent_id, target_scope)
      {:ok, result}
    else
      {:error, %Cqr.Error{} = err} ->
        # Best-effort cleanup if a write failed partway. Validation errors
        # fire before any writes so the rollback path only triggers on
        # adapter system errors.
        cleanup_partial_assert(expression.entity)
        {:error, err}
    end
  end

  @impl true
  def normalize(raw_results, _metadata) do
    %Cqr.Result{
      data: raw_results,
      sources: ["grafeo"],
      quality: %Cqr.Quality{}
    }
  end

  @impl true
  def health_check do
    case GrafeoServer.health() do
      {:ok, version} -> {:ok, %{adapter: "grafeo", version: version, status: :healthy}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- ASSERT: validation helpers ---

  defp resolve_target_scope(%Cqr.Assert{scope: nil}, [agent_self | _] = _visible) do
    # Default target scope: the first scope in the agent's visibility set,
    # which is the agent's own active scope (see Cqr.Repo.ScopeTree.visible_scopes/1).
    {:ok, agent_self}
  end

  defp resolve_target_scope(%Cqr.Assert{scope: nil}, []) do
    {:error,
     %Cqr.Error{
       code: :scope_access,
       message: "No active scope for the agent; cannot determine target scope for ASSERT"
     }}
  end

  defp resolve_target_scope(%Cqr.Assert{scope: target}, visible) do
    if target in visible do
      {:ok, target}
    else
      {:error,
       Cqr.Error.scope_access(Cqr.Types.format_scope(target),
         suggestions: Enum.map(visible, &Cqr.Types.format_scope/1)
       )}
    end
  end

  defp ensure_entity_absent({ns, name} = entity) do
    if Semantic.entity_exists?(entity) do
      formatted = Cqr.Types.format_entity(entity)

      {:error,
       %Cqr.Error{
         code: :entity_exists,
         message:
           "Entity #{formatted} already exists. Use CERTIFY to update governance " <>
             "status or SIGNAL to update quality.",
         details: %{namespace: ns, name: name},
         retry_guidance:
           "Choose a different entity name, or use CERTIFY/SIGNAL on the existing entity."
       }}
    else
      :ok
    end
  end

  defp ensure_derived_from_accessible(nil, _visible) do
    {:error,
     %Cqr.Error{
       code: :missing_required_field,
       message: "ASSERT requires DERIVED_FROM with at least one source entity",
       retry_guidance:
         "Add a DERIVED_FROM clause listing the entities this assertion was derived from"
     }}
  end

  defp ensure_derived_from_accessible([], _visible) do
    {:error,
     %Cqr.Error{
       code: :missing_required_field,
       message: "ASSERT requires at least one entity in DERIVED_FROM",
       retry_guidance:
         "Add a DERIVED_FROM clause listing the entities this assertion was derived from"
     }}
  end

  defp ensure_derived_from_accessible(entities, visible) when is_list(entities) do
    missing =
      Enum.filter(entities, fn entity ->
        case Semantic.get_entity(entity, visible) do
          {:ok, _} -> false
          _ -> true
        end
      end)

    case missing do
      [] ->
        :ok

      _ ->
        formatted = Enum.map(missing, &Cqr.Types.format_entity/1)

        {:error,
         %Cqr.Error{
           code: :entity_not_found,
           message:
             "ASSERT failed: derived_from entities not found or not accessible: " <>
               Enum.join(formatted, ", "),
           similar_entities: formatted,
           retry_guidance:
             "Verify each DERIVED_FROM entity exists in a scope visible to this agent"
         }}
    end
  end

  defp ensure_relationship_targets_accessible([], _visible), do: :ok

  defp ensure_relationship_targets_accessible(relationships, visible) do
    missing =
      Enum.filter(relationships, fn %{target: target} ->
        case Semantic.get_entity(target, visible) do
          {:ok, _} -> false
          _ -> true
        end
      end)

    case missing do
      [] ->
        :ok

      _ ->
        formatted = Enum.map(missing, fn %{target: t} -> Cqr.Types.format_entity(t) end)

        {:error,
         %Cqr.Error{
           code: :entity_not_found,
           message:
             "ASSERT failed: relationship target entities not found or not accessible: " <>
               Enum.join(formatted, ", "),
           similar_entities: formatted,
           retry_guidance:
             "Verify each relationship target entity exists in a scope visible to this agent"
         }}
    end
  end

  # --- ASSERT: write helpers ---

  # RFC 4122 UUIDv4. Used to give each AssertionRecord a stable identity
  # so the ASSERTED_BY edge can MATCH it unambiguously.
  defp generate_record_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    uuid =
      :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
      |> IO.iodata_to_binary()

    {:ok, uuid}
  end

  defp write_entity_node(%Cqr.Assert{entity: {ns, name}} = expression, agent_id) do
    confidence = expression.confidence || 0.5
    reputation = 0.5
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    # Pseudo-embedding over name + description matches the seeder's format,
    # so the free-text DISCOVER vector path surfaces asserted entities the
    # same way it surfaces seeded ones.
    embedding_literal =
      "#{name} #{expression.description}"
      |> Seed.pseudo_embedding()
      |> Seed.format_embedding()

    query =
      "INSERT (:Entity {" <>
        "namespace: '#{ns}', name: '#{name}', " <>
        "type: '#{escape(expression.type)}', " <>
        "description: '#{escape(expression.description)}', " <>
        "certified: false, " <>
        "confidence: #{confidence}, " <>
        "asserted_by: '#{escape(agent_id)}', " <>
        "asserted_at: '#{now}', " <>
        "intent: '#{escape(expression.intent)}', " <>
        "owner: '#{escape(agent_id)}', " <>
        "reputation: #{reputation}, " <>
        "freshness_hours_ago: 0, " <>
        "embedding: #{embedding_literal}" <>
        "})"

    exec_write(query)
  end

  defp write_in_scope_edge({ns, name}, scope_segments) do
    scope_path = Enum.join(scope_segments, ":")

    query =
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}), " <>
        "(s:Scope {path: '#{scope_path}'}) " <>
        "INSERT (e)-[:IN_SCOPE {primary: true}]->(s)"

    exec_write(query)
  end

  defp write_derived_from_edges(%Cqr.Assert{entity: {ns, name}} = expression, agent_id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.reduce_while(expression.derived_from, :ok, fn {src_ns, src_name}, _ ->
      query =
        "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}), " <>
          "(src:Entity {namespace: '#{src_ns}', name: '#{src_name}'}) " <>
          "INSERT (e)-[:DERIVED_FROM {asserted_by: '#{escape(agent_id)}', " <>
          "asserted_at: '#{now}'}]->(src)"

      case exec_write(query) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp write_relationship_edges(_entity, []), do: :ok

  defp write_relationship_edges({ns, name}, relationships) do
    Enum.reduce_while(relationships, :ok, fn
      %{type: rel_type, target: {tgt_ns, tgt_name}, strength: strength}, _ ->
        query =
          "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}), " <>
            "(t:Entity {namespace: '#{tgt_ns}', name: '#{tgt_name}'}) " <>
            "INSERT (e)-[:#{rel_type} {strength: #{strength}, asserted: true}]->(t)"

        case exec_write(query) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
    end)
  end

  defp write_assertion_record(
         %Cqr.Assert{entity: {ns, name}} = expression,
         agent_id,
         record_id,
         target_scope
       ) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    confidence = expression.confidence || 0.5

    derived_from_str = Enum.map_join(expression.derived_from, ",", &Cqr.Types.format_entity/1)

    expression_text =
      "ASSERT #{Cqr.Types.format_entity(expression.entity)} " <>
        "TYPE #{expression.type} " <>
        "DESCRIPTION \"#{expression.description}\" " <>
        "INTENT \"#{expression.intent}\" " <>
        "DERIVED_FROM #{derived_from_str} " <>
        "IN #{Cqr.Types.format_scope(target_scope)} " <>
        "CONFIDENCE #{confidence}"

    query =
      "INSERT (:AssertionRecord {" <>
        "record_id: '#{record_id}', " <>
        "entity_namespace: '#{ns}', entity_name: '#{name}', " <>
        "agent_id: '#{escape(agent_id)}', " <>
        "timestamp: '#{now}', " <>
        "intent: '#{escape(expression.intent)}', " <>
        "confidence: #{confidence}, " <>
        "derived_from: '#{escape(derived_from_str)}', " <>
        "expression_text: '#{escape(expression_text)}'" <>
        "})"

    exec_write(query)
  end

  defp write_asserted_by_edge({ns, name}, record_id) do
    query =
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}), " <>
        "(r:AssertionRecord {record_id: '#{record_id}'}) " <>
        "INSERT (e)-[:ASSERTED_BY]->(r)"

    exec_write(query)
  end

  defp build_result(%Cqr.Assert{entity: {ns, name}} = expression, agent_id, target_scope) do
    now = DateTime.utc_now()
    confidence = expression.confidence || 0.5

    entity_data = %{
      namespace: ns,
      name: name,
      type: expression.type,
      description: expression.description,
      certified: false,
      confidence: confidence,
      asserted_by: agent_id,
      asserted_at: now,
      intent: expression.intent,
      derived_from: Enum.map(expression.derived_from, &Cqr.Types.format_entity/1),
      scopes: [target_scope],
      reputation: 0.5,
      owner: agent_id
    }

    %Cqr.Result{
      data: [entity_data],
      sources: ["grafeo"],
      quality: %Cqr.Quality{
        freshness: now,
        confidence: confidence,
        reputation: 0.5,
        owner: agent_id,
        provenance: "ASSERT operation by #{agent_id}",
        certified_by: nil,
        certified_at: nil
      }
    }
  end

  # Best-effort cleanup if a write step failed after the entity node was
  # created. Without explicit transaction primitives in the NIF, this is
  # the closest we can get to rollback. Validation errors fire before any
  # writes, so this path only triggers on adapter system errors.
  defp cleanup_partial_assert({ns, name}) do
    cleanup_queries = [
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'})-[r]-() DELETE r",
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}) DELETE e",
      "MATCH (r:AssertionRecord {entity_namespace: '#{ns}', entity_name: '#{name}'}) DELETE r"
    ]

    Enum.each(cleanup_queries, fn q -> GrafeoServer.query(q) end)
  end

  defp exec_write(query) do
    case GrafeoServer.query(query) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error,
         %Cqr.Error{code: :adapter_error, message: "Grafeo write failed: #{inspect(reason)}"}}
    end
  end

  defp escape(nil), do: ""
  defp escape(str) when is_binary(str), do: String.replace(str, "'", "\\'")
  defp escape(other), do: to_string(other)

  # --- Private ---

  defp normalize_entity(entity_data, _expression) do
    # certified_by / certified_at come from the Entity node directly so
    # CERTIFY's authority and timestamp round-trip through RESOLVE. Before
    # the certify-audit-trail fixes, certified_by was synthesized from the
    # owner field, which meant RESOLVE returned the original asserter even
    # after certification by an external authority.
    quality = %Cqr.Quality{
      reputation: entity_data[:reputation],
      owner: entity_data[:owner],
      certified_by: entity_data[:certified_by],
      certified_at: parse_timestamp(entity_data[:certified_at])
    }

    %Cqr.Result{
      data: [entity_data],
      sources: ["grafeo"],
      quality: quality
    }
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp normalize_discovery(related, _anchor_entity, _expression) do
    quality =
      case related do
        [] ->
          %Cqr.Quality{}

        [first | _] ->
          %Cqr.Quality{
            reputation: first[:reputation],
            owner: first[:owner]
          }
      end

    %Cqr.Result{
      data: related,
      sources: ["grafeo"],
      quality: quality,
      conflicts:
        related
        |> Enum.group_by(& &1.entity)
        |> Enum.filter(fn {_k, v} -> length(v) > 1 end)
        |> Enum.map(fn {entity, entries} ->
          %{entity: entity, conflicting_values: entries}
        end)
    }
  end

  # --- TRACE ---

  @impl true
  def trace(%Cqr.Trace{entity: {ns, name}} = expression, _scope_context, _opts) do
    with {:ok, entity_data} <- Semantic.get_entity(expression.entity, nil),
         {:ok, assertion} <- fetch_assertion_record(ns, name),
         {:ok, cert_history} <- fetch_certification_history(ns, name),
         {:ok, signal_history} <- fetch_signal_history(ns, name),
         {:ok, derived_chain} <- fetch_derived_from_chain(ns, name, expression.causal_depth),
         {:ok, referenced} <- fetch_referenced_by(ns, name) do
      filtered_certs = apply_time_window(cert_history, expression.time_window)
      filtered_signals = apply_time_window(signal_history, expression.time_window)

      trace_row = %{
        entity: Cqr.Types.format_entity(expression.entity),
        current_state: current_state(entity_data),
        assertion: assertion,
        certification_history: filtered_certs,
        signal_history: filtered_signals,
        derived_from_chain: derived_chain,
        referenced_by: referenced
      }

      {:ok,
       %Cqr.Result{
         data: [trace_row],
         sources: ["grafeo"],
         quality: %Cqr.Quality{
           reputation: entity_data[:reputation],
           owner: entity_data[:owner],
           provenance: "TRACE operation on #{Cqr.Types.format_entity(expression.entity)}",
           certified_by: entity_data[:certified_by],
           certified_at: parse_timestamp(entity_data[:certified_at])
         }
       }}
    else
      {:error, %Cqr.Error{}} = err ->
        err

      {:error, reason} ->
        {:error,
         %Cqr.Error{code: :adapter_error, message: "Grafeo TRACE failed: #{inspect(reason)}"}}
    end
  end

  defp current_state(entity_data) do
    %{
      type: entity_data[:type],
      description: entity_data[:description],
      reputation: entity_data[:reputation],
      certified: entity_data[:certified],
      certified_by: entity_data[:certified_by],
      certified_at: entity_data[:certified_at],
      owner: entity_data[:owner],
      freshness_hours_ago: entity_data[:freshness_hours_ago]
    }
  end

  defp fetch_assertion_record(ns, name) do
    query =
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'})-[:ASSERTED_BY]->" <>
        "(ar:AssertionRecord) " <>
        "RETURN ar.record_id, ar.timestamp, ar.agent_id, ar.intent, " <>
        "ar.confidence, ar.derived_from"

    case GrafeoServer.query(query) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, [row | _]} ->
        {:ok,
         %{
           record_id: row["ar.record_id"],
           asserted_at: row["ar.timestamp"],
           asserted_by: row["ar.agent_id"],
           intent: row["ar.intent"],
           confidence: row["ar.confidence"],
           derived_from: split_derived_from(row["ar.derived_from"])
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_derived_from(nil), do: []
  defp split_derived_from(""), do: []

  defp split_derived_from(str) when is_binary(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp fetch_certification_history(ns, name) do
    query =
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'})-[:CERTIFICATION_EVENT]->" <>
        "(cr:CertificationRecord) " <>
        "RETURN cr.timestamp, cr.previous_status, cr.new_status, " <>
        "cr.agent_id, cr.authority, cr.evidence"

    case GrafeoServer.query(query) do
      {:ok, rows} ->
        history =
          rows
          |> Enum.map(fn row ->
            %{
              timestamp: row["cr.timestamp"],
              from_status: nilify_empty(row["cr.previous_status"]),
              to_status: row["cr.new_status"],
              agent: row["cr.agent_id"],
              authority: nilify_empty(row["cr.authority"]),
              evidence: nilify_empty(row["cr.evidence"])
            }
          end)
          |> Enum.sort_by(& &1.timestamp)

        {:ok, history}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_signal_history(ns, name) do
    query =
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'})-[:SIGNAL_EVENT]->" <>
        "(sr:SignalRecord) " <>
        "RETURN sr.timestamp, sr.agent_id, sr.previous_reputation, " <>
        "sr.new_reputation, sr.evidence"

    case GrafeoServer.query(query) do
      {:ok, rows} ->
        history =
          rows
          |> Enum.map(fn row ->
            %{
              timestamp: row["sr.timestamp"],
              agent: row["sr.agent_id"],
              previous_reputation: row["sr.previous_reputation"],
              new_reputation: row["sr.new_reputation"],
              evidence: nilify_empty(row["sr.evidence"])
            }
          end)
          |> Enum.sort_by(& &1.timestamp)

        {:ok, history}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Grafeo's Cypher dialect does not support variable-length edges inside a
  # pattern like `-[:DERIVED_FROM*1..2]->` alongside property predicates,
  # so we walk the chain one hop at a time and merge the per-depth rows
  # with a depth tag. The depths are at most 10 (hard cap) so the extra
  # round-trips are acceptable and kept under the 3s MCP budget.
  defp fetch_derived_from_chain(ns, name, depth) when depth > 0 do
    capped_depth = min(depth, 10)

    Enum.reduce_while(1..capped_depth, {:ok, [], [{ns, name}]}, fn level, {:ok, acc, frontier} ->
      case expand_derived_frontier(frontier, level) do
        {:ok, [], _next} ->
          {:halt, {:ok, acc, []}}

        {:ok, new_rows, next_frontier} ->
          {:cont, {:ok, acc ++ new_rows, next_frontier}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, rows, _} -> {:ok, rows}
      other -> other
    end
  end

  defp fetch_derived_from_chain(_ns, _name, _depth), do: {:ok, []}

  defp expand_derived_frontier(frontier, level) do
    Enum.reduce_while(frontier, {:ok, [], []}, &step_expand_frontier(&1, &2, level))
  end

  defp step_expand_frontier({src_ns, src_name}, {:ok, acc, next}, level) do
    query =
      "MATCH (e:Entity {namespace: '#{src_ns}', name: '#{src_name}'})-[:DERIVED_FROM]->" <>
        "(source:Entity) " <>
        "RETURN source.namespace, source.name, source.type, source.description, " <>
        "source.reputation, source.certified"

    case GrafeoServer.query(query) do
      {:ok, rows} ->
        new_rows = Enum.map(rows, &derived_row(&1, level))
        new_frontier = Enum.map(rows, fn row -> {row["source.namespace"], row["source.name"]} end)
        {:cont, {:ok, acc ++ new_rows, next ++ new_frontier}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp derived_row(row, level) do
    %{
      entity: Cqr.Types.format_entity({row["source.namespace"], row["source.name"]}),
      depth: level,
      type: row["source.type"],
      description: row["source.description"],
      reputation: row["source.reputation"],
      certified: row["source.certified"]
    }
  end

  defp fetch_referenced_by(ns, name) do
    query =
      "MATCH (dependent:Entity)-[:DERIVED_FROM]->(e:Entity {namespace: '#{ns}', name: '#{name}'}) " <>
        "RETURN dependent.namespace, dependent.name, dependent.type, dependent.description"

    case GrafeoServer.query(query) do
      {:ok, rows} ->
        result =
          Enum.map(rows, fn row ->
            %{
              entity:
                Cqr.Types.format_entity({row["dependent.namespace"], row["dependent.name"]}),
              relationship: "DERIVED_FROM",
              type: row["dependent.type"],
              description: row["dependent.description"]
            }
          end)

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Filter a history list to events whose timestamp is newer than
  # `now - window`. When no window is set, return everything.
  defp apply_time_window(events, nil), do: events

  defp apply_time_window(events, {amount, unit}) do
    cutoff_seconds = duration_to_seconds(amount, unit)
    cutoff = DateTime.add(DateTime.utc_now(), -cutoff_seconds, :second)

    Enum.filter(events, fn event ->
      case parse_timestamp(event.timestamp) do
        nil -> true
        dt -> DateTime.compare(dt, cutoff) != :lt
      end
    end)
  end

  defp duration_to_seconds(amount, :m), do: amount * 60
  defp duration_to_seconds(amount, :h), do: amount * 60 * 60
  defp duration_to_seconds(amount, :d), do: amount * 60 * 60 * 24
  defp duration_to_seconds(amount, :w), do: amount * 60 * 60 * 24 * 7

  defp nilify_empty(nil), do: nil
  defp nilify_empty(""), do: nil
  defp nilify_empty(v), do: v

  # --- SIGNAL ---

  @impl true
  def signal(%Cqr.Signal{entity: {ns, name}} = expression, _scope_context, opts) do
    agent_id = Keyword.get(opts, :agent_id, "anonymous")
    previous_reputation = Keyword.get(opts, :previous_reputation)
    now = DateTime.utc_now()
    timestamp = DateTime.to_iso8601(now)

    with {:ok, record_id} <- generate_signal_record_id(),
         :ok <-
           write_signal_record(expression, agent_id, record_id, previous_reputation, timestamp),
         :ok <- write_signal_event_edge({ns, name}, record_id),
         :ok <- update_entity_reputation({ns, name}, expression.score) do
      result = %Cqr.Result{
        data: [
          %{
            entity: Cqr.Types.format_entity(expression.entity),
            previous_reputation: previous_reputation,
            new_reputation: expression.score,
            evidence: expression.evidence,
            signaled_by: agent_id,
            signaled_at: now,
            record_id: record_id
          }
        ],
        sources: ["grafeo"],
        quality: %Cqr.Quality{
          freshness: now,
          reputation: expression.score,
          owner: agent_id,
          provenance: "SIGNAL operation by #{agent_id}"
        }
      }

      {:ok, result}
    end
  end

  defp generate_signal_record_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    uuid =
      :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
      |> IO.iodata_to_binary()

    {:ok, uuid}
  end

  defp write_signal_record(
         %Cqr.Signal{entity: {ns, name}} = signal,
         agent_id,
         record_id,
         previous_reputation,
         timestamp
       ) do
    previous_val = previous_reputation || 0.0

    query =
      "INSERT (:SignalRecord {" <>
        "record_id: '#{record_id}', " <>
        "entity_namespace: '#{ns}', entity_name: '#{name}', " <>
        "agent_id: '#{escape(agent_id)}', " <>
        "previous_reputation: #{previous_val}, " <>
        "new_reputation: #{signal.score}, " <>
        "evidence: '#{escape(signal.evidence)}', " <>
        "timestamp: '#{timestamp}'" <>
        "})"

    exec_write(query)
  end

  defp write_signal_event_edge({ns, name}, record_id) do
    query =
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}), " <>
        "(r:SignalRecord {record_id: '#{record_id}'}) " <>
        "INSERT (e)-[:SIGNAL_EVENT]->(r)"

    exec_write(query)
  end

  defp update_entity_reputation({ns, name}, new_score) do
    query =
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}) " <>
        "SET e.reputation = #{new_score}"

    exec_write(query)
  end

  # --- REFRESH CHECK ---

  @impl true
  def refresh_check(%Cqr.Refresh{} = expression, scope_context, _opts) do
    visible = scope_context[:visible_scopes] || []
    threshold_hours = threshold_to_hours(expression.threshold)

    case query_stale_entities(visible, threshold_hours) do
      {:ok, rows} ->
        stale =
          rows
          |> Enum.map(fn row ->
            freshness = row["e.freshness_hours_ago"] || 0

            %{
              entity: Cqr.Types.format_entity({row["e.namespace"], row["e.name"]}),
              type: row["e.type"],
              description: row["e.description"],
              owner: row["e.owner"],
              freshness_hours_ago: freshness,
              threshold_exceeded_by: max(freshness - threshold_hours, 0),
              reputation: row["e.reputation"],
              certified: row["e.certified"]
            }
          end)
          |> Enum.sort_by(fn item -> -item.freshness_hours_ago end)

        {:ok,
         %Cqr.Result{
           data: stale,
           sources: ["grafeo"],
           quality: %Cqr.Quality{
             freshness: DateTime.utc_now(),
             provenance: "REFRESH CHECK (threshold: #{threshold_hours}h)"
           }
         }}

      {:error, reason} ->
        {:error,
         %Cqr.Error{
           code: :adapter_error,
           message: "Grafeo REFRESH failed: #{inspect(reason)}"
         }}
    end
  end

  defp query_stale_entities([], _threshold_hours), do: {:ok, []}

  defp query_stale_entities(visible_scopes, threshold_hours) do
    scope_list =
      Enum.map_join(visible_scopes, ", ", fn segments -> "\"#{Enum.join(segments, ":")}\"" end)

    query =
      "MATCH (e:Entity)-[:IN_SCOPE]->(s:Scope) " <>
        "WHERE s.path IN [#{scope_list}] " <>
        "AND e.freshness_hours_ago > #{threshold_hours} " <>
        "RETURN DISTINCT e.namespace, e.name, e.type, e.description, e.owner, " <>
        "e.reputation, e.freshness_hours_ago, e.certified"

    GrafeoServer.query(query)
  end

  defp threshold_to_hours({amount, :m}), do: max(div(amount, 60), 0)
  defp threshold_to_hours({amount, :h}), do: amount
  defp threshold_to_hours({amount, :d}), do: amount * 24
  defp threshold_to_hours({amount, :w}), do: amount * 24 * 7

  # --- AWARENESS ---
  #
  # AWARENESS reads three audit-record kinds for entities that sit in
  # the agent's visible scopes: AssertionRecord, CertificationRecord,
  # SignalRecord. It groups by `agent_id`, sorts by recent activity
  # volume, and returns one row per agent with the entities they touched
  # and the intents they declared.
  #
  # The scope filter runs inside the MATCH so no audit row about an
  # entity outside the visible set is ever materialised. The optional
  # `time_window` is applied in Elixir after fetch — Grafeo's Cypher
  # has no parameterised timestamp comparison, and the audit row count
  # per scope subtree is small enough that post-filtering is fine for
  # V1 agent budgets.

  @impl true
  def awareness(%Cqr.Awareness{} = expression, scope_context, _opts) do
    visible = scope_context[:visible_scopes] || []

    case fetch_audit_rows(visible) do
      {:ok, rows} ->
        cutoff = window_cutoff(expression.time_window)

        agents =
          rows
          |> Enum.filter(&within_window?(&1, cutoff))
          |> group_by_agent()
          |> Enum.map(&summarise_agent/1)
          |> Enum.sort_by(fn a -> {-a.activity_count, a.last_seen} end)
          |> apply_limit(expression.limit)

        {:ok,
         %Cqr.Result{
           data: agents,
           sources: ["grafeo"],
           quality: %Cqr.Quality{
             freshness: DateTime.utc_now(),
             provenance: awareness_provenance(expression, visible)
           }
         }}

      {:error, reason} ->
        {:error,
         %Cqr.Error{
           code: :adapter_error,
           message: "Grafeo AWARENESS failed: #{inspect(reason)}"
         }}
    end
  end

  defp fetch_audit_rows([]), do: {:ok, []}

  defp fetch_audit_rows(visible_scopes) do
    with {:ok, assertions} <- fetch_assertion_audit(visible_scopes),
         {:ok, certifications} <- fetch_certification_audit(visible_scopes),
         {:ok, signals} <- fetch_signal_audit(visible_scopes) do
      {:ok, assertions ++ certifications ++ signals}
    end
  end

  defp fetch_assertion_audit(visible_scopes) do
    scope_list = scope_in_clause(visible_scopes)

    query =
      "MATCH (e:Entity)-[:IN_SCOPE]->(s:Scope), " <>
        "(e)-[:ASSERTED_BY]->(ar:AssertionRecord) " <>
        "WHERE s.path IN [#{scope_list}] " <>
        "RETURN DISTINCT ar.agent_id, ar.timestamp, ar.intent, " <>
        "e.namespace, e.name"

    case GrafeoServer.query(query) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn row ->
           %{
             kind: :assertion,
             agent_id: row["ar.agent_id"],
             timestamp: row["ar.timestamp"],
             intent: nilify_empty(row["ar.intent"]),
             entity: Cqr.Types.format_entity({row["e.namespace"], row["e.name"]})
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_certification_audit(visible_scopes) do
    scope_list = scope_in_clause(visible_scopes)

    query =
      "MATCH (e:Entity)-[:IN_SCOPE]->(s:Scope), " <>
        "(e)-[:CERTIFICATION_EVENT]->(cr:CertificationRecord) " <>
        "WHERE s.path IN [#{scope_list}] " <>
        "RETURN DISTINCT cr.agent_id, cr.timestamp, cr.new_status, " <>
        "cr.previous_status, cr.authority, e.namespace, e.name"

    case GrafeoServer.query(query) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn row ->
           %{
             kind: :certification,
             agent_id: row["cr.agent_id"],
             timestamp: row["cr.timestamp"],
             from_status: nilify_empty(row["cr.previous_status"]),
             to_status: row["cr.new_status"],
             authority: nilify_empty(row["cr.authority"]),
             entity: Cqr.Types.format_entity({row["e.namespace"], row["e.name"]})
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_signal_audit(visible_scopes) do
    scope_list = scope_in_clause(visible_scopes)

    query =
      "MATCH (e:Entity)-[:IN_SCOPE]->(s:Scope), " <>
        "(e)-[:SIGNAL_EVENT]->(sr:SignalRecord) " <>
        "WHERE s.path IN [#{scope_list}] " <>
        "RETURN DISTINCT sr.agent_id, sr.timestamp, sr.previous_reputation, " <>
        "sr.new_reputation, sr.evidence, e.namespace, e.name"

    case GrafeoServer.query(query) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn row ->
           %{
             kind: :signal,
             agent_id: row["sr.agent_id"],
             timestamp: row["sr.timestamp"],
             previous_reputation: row["sr.previous_reputation"],
             new_reputation: row["sr.new_reputation"],
             evidence: nilify_empty(row["sr.evidence"]),
             entity: Cqr.Types.format_entity({row["e.namespace"], row["e.name"]})
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scope_in_clause(visible_scopes) do
    Enum.map_join(visible_scopes, ", ", fn segments -> "\"#{Enum.join(segments, ":")}\"" end)
  end

  defp window_cutoff(nil), do: nil

  defp window_cutoff({amount, unit}) do
    DateTime.add(DateTime.utc_now(), -duration_to_seconds(amount, unit), :second)
  end

  defp within_window?(_row, nil), do: true

  defp within_window?(row, %DateTime{} = cutoff) do
    case parse_timestamp(row.timestamp) do
      nil -> false
      dt -> DateTime.compare(dt, cutoff) != :lt
    end
  end

  defp group_by_agent(rows) do
    rows
    |> Enum.reject(fn row -> is_nil(row.agent_id) or row.agent_id == "" end)
    |> Enum.group_by(& &1.agent_id)
  end

  defp summarise_agent({agent_id, rows}) do
    {assertions, certifications, signals} = split_by_kind(rows)

    entities =
      rows
      |> Enum.map(& &1.entity)
      |> Enum.uniq()

    intents =
      assertions
      |> Enum.map(& &1.intent)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    last_seen =
      rows
      |> Enum.map(& &1.timestamp)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    %{
      agent_id: agent_id,
      activity_count: length(rows),
      last_seen: last_seen,
      assertions: Enum.map(assertions, &assertion_summary/1),
      certifications: Enum.map(certifications, &certification_summary/1),
      signals: Enum.map(signals, &signal_summary/1),
      entities_touched: entities,
      intents: intents
    }
  end

  defp split_by_kind(rows) do
    Enum.reduce(rows, {[], [], []}, fn
      %{kind: :assertion} = r, {a, c, s} -> {[r | a], c, s}
      %{kind: :certification} = r, {a, c, s} -> {a, [r | c], s}
      %{kind: :signal} = r, {a, c, s} -> {a, c, [r | s]}
    end)
  end

  defp assertion_summary(row) do
    %{entity: row.entity, intent: row.intent, at: row.timestamp}
  end

  defp certification_summary(row) do
    %{
      entity: row.entity,
      from_status: row.from_status,
      to_status: row.to_status,
      authority: row.authority,
      at: row.timestamp
    }
  end

  defp signal_summary(row) do
    %{
      entity: row.entity,
      previous_reputation: row.previous_reputation,
      new_reputation: row.new_reputation,
      evidence: row.evidence,
      at: row.timestamp
    }
  end

  defp apply_limit(agents, nil), do: agents

  defp apply_limit(agents, n) when is_integer(n) and n > 0,
    do: Enum.take(agents, n)

  defp apply_limit(agents, _), do: agents

  defp awareness_provenance(%Cqr.Awareness{time_window: nil}, visible) do
    "AWARENESS scan over #{length(visible)} visible scope(s), full history"
  end

  defp awareness_provenance(%Cqr.Awareness{time_window: {amount, unit}}, visible) do
    "AWARENESS scan over #{length(visible)} visible scope(s), last #{amount}#{unit}"
  end

  # --- HYPOTHESIZE ---
  #
  # Walks the relationship graph outward from the target entity using BFS,
  # capped at `expression.depth` hops. At each hop the projection carries
  # two pieces of state:
  #
  #   * `hop_confidence`     — `decay ** depth`. How much trust to place
  #                            in this projection given the distance from
  #                            the source of the hypothesis.
  #   * `projected_delta`    — `original_delta * hop_confidence * strength`.
  #                            How the assumed change ripples to this
  #                            entity along the traversed edge. Edges
  #                            without a strength are treated as 1.0.
  #
  # Both inbound and outbound edges are traversed because relationship
  # semantics are mixed: `(A)-[:DEPENDS_ON]->(B)` makes A a dependent of
  # B (inbound from B), while `(A)-[:CAUSES]->(B)` makes B a dependent
  # of A (outbound from A). The walk does not interpret edge semantics;
  # it surfaces the path so the agent can reason about it. Each affected
  # entity is reported once, at the smallest depth it was reached.

  @impl true
  def hypothesize(%Cqr.Hypothesize{entity: entity} = expression, scope_context, _opts) do
    visible = scope_context[:visible_scopes] || []

    with {:ok, baseline} <- Semantic.get_entity(entity, visible),
         change <- primary_change(expression),
         {:ok, blast_radius} <- walk_blast_radius(entity, expression, visible) do
      delta = compute_delta(baseline, change)
      affected = annotate_affected(blast_radius, delta, expression.decay)

      hypothetical_change =
        change
        |> Map.put(:original_value, original_value(baseline, change))
        |> Map.put(:delta, delta)

      row = %{
        entity: Cqr.Types.format_entity(entity),
        hypothetical_change: hypothetical_change,
        depth: expression.depth,
        decay: expression.decay,
        blast_radius: affected,
        summary: summarize(affected, expression.depth)
      }

      {:ok,
       %Cqr.Result{
         data: [row],
         sources: ["grafeo"],
         quality: %Cqr.Quality{
           reputation: baseline[:reputation],
           owner: baseline[:owner],
           provenance:
             "HYPOTHESIZE on #{Cqr.Types.format_entity(entity)} " <>
               "(#{length(affected)} affected, decay=#{expression.decay})"
         }
       }}
    else
      {:error, %Cqr.Error{}} = err ->
        err

      {:error, reason} ->
        {:error,
         %Cqr.Error{
           code: :adapter_error,
           message: "Grafeo HYPOTHESIZE failed: #{inspect(reason)}"
         }}
    end
  end

  defp primary_change(%Cqr.Hypothesize{changes: [first | _]}), do: first

  defp original_value(baseline, %{field: :reputation}), do: baseline[:reputation]
  defp original_value(_baseline, _change), do: nil

  defp compute_delta(baseline, %{field: :reputation, value: new}) do
    case baseline[:reputation] do
      nil -> 0.0
      original when is_number(original) -> new - original
      _ -> 0.0
    end
  end

  defp compute_delta(_baseline, _change), do: 0.0

  defp walk_blast_radius({ns, name}, %Cqr.Hypothesize{} = ast, visible) do
    capped_depth = min(ast.depth, 10)
    seed = %{key: {ns, name}, depth: 0}
    walk_loop([seed], MapSet.new([seed.key]), [], 1, capped_depth, visible)
  end

  defp walk_loop(_frontier, _visited, acc, level, max_depth, _visible) when level > max_depth do
    {:ok, Enum.reverse(acc)}
  end

  defp walk_loop([], _visited, acc, _level, _max_depth, _visible) do
    {:ok, Enum.reverse(acc)}
  end

  defp walk_loop(frontier, visited, acc, level, max_depth, visible) do
    case expand_frontier(frontier, visited, level, visible) do
      {:ok, new_rows, next_frontier, next_visited} ->
        walk_loop(
          next_frontier,
          next_visited,
          Enum.reverse(new_rows) ++ acc,
          level + 1,
          max_depth,
          visible
        )

      {:error, _} = err ->
        err
    end
  end

  defp expand_frontier(frontier, visited, level, visible) do
    Enum.reduce_while(frontier, {:ok, [], [], visited}, fn node,
                                                           {:ok, rows_acc, next_acc, visited_acc} ->
      case neighbors(node.key, visible) do
        {:ok, raw_neighbors} ->
          {new_rows, new_next, new_visited} =
            absorb_neighbors(raw_neighbors, level, visited_acc)

          {:cont, {:ok, rows_acc ++ new_rows, next_acc ++ new_next, new_visited}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, rows, next, visited_out} -> {:ok, rows, next, visited_out}
      other -> other
    end
  end

  defp neighbors({ns, name}, visible) do
    with {:ok, out} <- Semantic.related_entities({ns, name}, 1, visible, nil),
         {:ok, inb} <- Semantic.related_entities_inbound({ns, name}, 1, visible, nil) do
      {:ok, out ++ inb}
    end
  end

  defp absorb_neighbors(neighbors, level, visited) do
    Enum.reduce(neighbors, {[], [], visited}, fn neighbor, {rows_acc, next_acc, visited_acc} ->
      key = neighbor.entity

      if MapSet.member?(visited_acc, key) do
        {rows_acc, next_acc, visited_acc}
      else
        row = %{
          entity: Cqr.Types.format_entity(key),
          depth: level,
          relationship: neighbor.relationship,
          direction: neighbor.direction,
          strength: neighbor.strength,
          current_reputation: neighbor.reputation,
          type: neighbor.type,
          owner: neighbor.owner
        }

        {rows_acc ++ [row], next_acc ++ [%{key: key, depth: level}], MapSet.put(visited_acc, key)}
      end
    end)
  end

  defp annotate_affected(rows, delta, decay) do
    Enum.map(rows, &annotate_row(&1, delta, decay))
  end

  defp annotate_row(row, delta, decay) do
    hop_confidence = :math.pow(decay, row.depth)
    strength_factor = row.strength || 1.0
    propagated_delta = delta * hop_confidence * strength_factor

    projected_reputation =
      case row.current_reputation do
        nil -> nil
        current -> clamp(current + propagated_delta)
      end

    Map.merge(row, %{
      hop_confidence: hop_confidence,
      projected_delta: propagated_delta,
      projected_reputation: projected_reputation
    })
  end

  defp clamp(v) when v < 0.0, do: 0.0
  defp clamp(v) when v > 1.0, do: 1.0
  defp clamp(v), do: v

  defp summarize([], _max_depth) do
    %{total_affected: 0, max_depth_reached: 0, mean_hop_confidence: 0.0}
  end

  defp summarize(rows, _max_depth) do
    confidences = Enum.map(rows, & &1.hop_confidence)
    max_depth_reached = rows |> Enum.map(& &1.depth) |> Enum.max(fn -> 0 end)

    %{
      total_affected: length(rows),
      max_depth_reached: max_depth_reached,
      mean_hop_confidence: Enum.sum(confidences) / length(confidences)
    }
  end
end
