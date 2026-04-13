defmodule Cqr.Repo.Seed do
  @moduledoc """
  Sample organizational data seeder.

  Seeds the embedded Grafeo instance with a realistic SaaS company dataset
  on first boot. Idempotent — checks for existing data before inserting.

  See PROJECT_KNOWLEDGE.md Section 10 for the dataset specification.
  """

  alias Cqr.Grafeo.Native

  require Logger

  @doc """
  Seed the database if empty, using a NIF db handle directly.
  Called during Grafeo.Server init (before GenServer is registered).
  """
  def seed_if_empty_direct(db) do
    case Native.execute(db, "MATCH (n:Scope) RETURN count(n)") do
      {:ok, [%{"countnonnull(...)" => 0}]} ->
        Logger.info("Empty database detected — seeding sample dataset")
        seed_direct(db)

      {:ok, _} ->
        Logger.info("Database already contains data — skipping seed")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Seed all data using a NIF db handle directly."
  def seed_direct(db) do
    with :ok <- seed_scopes(db),
         :ok <- seed_entities(db),
         :ok <- seed_relationships(db) do
      Logger.info(
        "Seeded #{length(scopes())} scopes, #{length(entities())} entities, #{length(relationships())} relationships"
      )

      :ok
    end
  end

  # --- Scopes ---

  defp seed_scopes(db) do
    q!(db, "INSERT (:Scope {name: 'company', path: 'company', level: 0})")

    for {name, path, level, parent_name} <- child_scopes() do
      q!(
        db,
        "MATCH (parent:Scope {name: '#{parent_name}'}) " <>
          "INSERT (:Scope {name: '#{name}', path: '#{path}', level: #{level}})" <>
          "-[:CHILD_OF]->(parent)"
      )
    end

    :ok
  end

  defp child_scopes do
    [
      {"finance", "company:finance", 1, "company"},
      {"product", "company:product", 1, "company"},
      {"engineering", "company:engineering", 1, "company"},
      {"hr", "company:hr", 1, "company"},
      {"customer_success", "company:customer_success", 1, "company"}
    ]
  end

  # --- Entities ---

  # Embedding dimension. Fixed at seed time and reused for query-time
  # pseudo-embeddings in the Grafeo adapter. Kept public (via the module
  # attribute reflected through embedding_dims/0) so the adapter can call
  # Cqr.Repo.Seed.embedding_dims/0 without hardcoding the value.
  @embedding_dims 384

  @doc "Returns the dimensionality of seeded pseudo-embeddings."
  def embedding_dims, do: @embedding_dims

  @doc """
  Deterministic bag-of-words pseudo-embedding.

  Tokenizes `text` (lowercased, punctuation stripped), hashes each word to
  a dimension index in `0..#{@embedding_dims - 1}`, increments that dimension,
  and L2-normalizes the resulting vector.

  This is *not* a trained embedding — there's no semantic learning. But
  because overlapping vocabulary produces overlapping non-zero dimensions,
  cosine similarity between two pseudo-embeddings reflects word-level
  overlap between the source texts. That's enough signal to validate the
  BM25 + vector + graph pipeline end-to-end without introducing an
  embedding model dependency.
  """
  def pseudo_embedding(text) when is_binary(text) do
    empty = List.duplicate(0.0, @embedding_dims)

    vec =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9 ]/, " ")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce(empty, fn word, acc ->
        idx = :erlang.phash2(word, @embedding_dims)
        List.update_at(acc, idx, fn v -> v + 1.0 end)
      end)

    normalize(vec)
  end

  defp normalize(vec) do
    mag = :math.sqrt(Enum.reduce(vec, 0.0, fn x, acc -> acc + x * x end))

    if mag == 0.0 do
      vec
    else
      Enum.map(vec, fn x -> x / mag end)
    end
  end

  @doc """
  Format an embedding vector as a Cypher list literal for INSERT statements.
  Exposed so the Grafeo adapter can write the same format on ASSERT as the
  seeder does, keeping the free-text DISCOVER vector path usable across
  both seeded and asserted entities.
  """
  def format_embedding(vec) do
    body =
      Enum.map_join(vec, ", ", fn x ->
        :erlang.float_to_binary(x * 1.0, decimals: 6)
      end)

    "[" <> body <> "]"
  end

  defp seed_entities(db) do
    for {ns, name, type, desc, scope_name, owner, reputation, freshness_h} <- entities() do
      embedding = pseudo_embedding("#{name} #{desc}")
      embedding_literal = format_embedding(embedding)

      q!(
        db,
        "INSERT (:Entity {" <>
          "namespace: '#{ns}', name: '#{name}', type: '#{type}', " <>
          "description: '#{escape(desc)}', owner: '#{owner}', " <>
          "reputation: #{reputation}, freshness_hours_ago: #{freshness_h}, " <>
          "certified: false, embedding: #{embedding_literal}})"
      )

      q!(
        db,
        "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}), " <>
          "(s:Scope {name: '#{scope_name}'}) " <>
          "INSERT (e)-[:IN_SCOPE {primary: true}]->(s)"
      )
    end

    # NPS has a secondary scope (customer_success)
    q!(
      db,
      "MATCH (e:Entity {namespace: 'product', name: 'nps'}), " <>
        "(s:Scope {name: 'customer_success'}) " <>
        "INSERT (e)-[:IN_SCOPE {primary: false}]->(s)"
    )

    # Note: Grafeo v0.5 has a `CREATE VECTOR INDEX` statement but it requires
    # native vector-typed properties which this Cypher surface cannot declare,
    # and no query-side procedure exposes the index to MATCH / CALL clauses.
    # The adapter stores embeddings as regular list-of-float properties and
    # computes cosine similarity in Elixir at query time. The storage pipeline
    # is fully validated by the seed → MATCH round-trip on the list property.

    :ok
  end

  # --- Relationships ---

  defp seed_relationships(db) do
    for {from_ns, from_name, rel_type, to_ns, to_name, strength} <- relationships() do
      q!(
        db,
        "MATCH (a:Entity {namespace: '#{from_ns}', name: '#{from_name}'}), " <>
          "(b:Entity {namespace: '#{to_ns}', name: '#{to_name}'}) " <>
          "INSERT (a)-[:#{rel_type} {strength: #{strength}}]->(b)"
      )
    end

    :ok
  end

  # --- Data definitions ---

  defp scopes do
    [
      {"company", "company", 0},
      {"finance", "company:finance", 1},
      {"product", "company:product", 1},
      {"engineering", "company:engineering", 1},
      {"hr", "company:hr", 1},
      {"customer_success", "company:customer_success", 1}
    ]
  end

  @doc false
  def entities do
    [
      # {namespace, name, type, description, scope, owner, reputation, freshness_hours_ago}
      {"finance", "arr", "metric", "Annual Recurring Revenue", "finance", "finance_team", 0.95,
       2},
      {"finance", "mrr", "metric", "Monthly Recurring Revenue", "finance", "finance_team", 0.93,
       2},
      {"finance", "burn_rate", "metric", "Monthly cash burn rate", "finance", "finance_team",
       0.88, 24},
      {"finance", "operating_expenses", "metric", "Total operating expenses", "finance",
       "finance_team", 0.90, 48},
      {"finance", "revenue_growth", "metric", "Quarter-over-quarter revenue growth rate",
       "finance", "finance_team", 0.92, 168},
      {"finance", "ltv", "metric", "Customer lifetime value", "finance", "finance_team", 0.85,
       72},
      {"finance", "cac", "metric", "Customer acquisition cost", "finance", "finance_team", 0.84,
       72},
      {"product", "churn_rate", "metric", "Customer churn rate", "product", "product_team", 0.87,
       12},
      {"product", "nps", "metric", "Net Promoter Score", "product", "product_team", 0.82, 168},
      {"product", "dau", "metric", "Daily Active Users", "product", "product_team", 0.91, 1},
      {"product", "feature_adoption", "metric", "Feature adoption rate for new releases",
       "product", "product_team", 0.78, 48},
      {"product", "retention_rate", "metric", "30-day user retention rate", "product",
       "product_team", 0.86, 24},
      {"product", "time_to_value", "metric", "Average time from signup to first value event",
       "product", "product_team", 0.75, 168},
      {"engineering", "deployment_frequency", "metric", "Production deployments per week",
       "engineering", "engineering_team", 0.94, 1},
      {"engineering", "mttr", "metric", "Mean time to recovery from incidents", "engineering",
       "engineering_team", 0.91, 4},
      {"engineering", "incident_rate", "metric", "Production incidents per week", "engineering",
       "engineering_team", 0.93, 1},
      {"engineering", "code_coverage", "metric", "Test code coverage percentage", "engineering",
       "engineering_team", 0.89, 24},
      {"engineering", "lead_time", "metric", "Lead time from commit to production", "engineering",
       "engineering_team", 0.88, 4},
      {"engineering", "change_failure_rate", "metric",
       "Percentage of deployments causing failures", "engineering", "engineering_team", 0.90, 12},
      {"hr", "headcount", "metric", "Total employee headcount", "hr", "hr_team", 0.97, 24},
      {"hr", "attrition_rate", "metric", "Employee attrition rate", "hr", "hr_team", 0.85, 168},
      {"hr", "enps", "metric", "Employee Net Promoter Score", "hr", "hr_team", 0.80, 720},
      {"hr", "hiring_velocity", "metric", "Average days to fill open positions", "hr", "hr_team",
       0.83, 168},
      {"hr", "compensation_ratio", "metric", "Compensation relative to market median", "hr",
       "hr_team", 0.79, 2160},
      {"customer_success", "csat", "metric", "Customer satisfaction score", "customer_success",
       "cs_team", 0.86, 48},
      {"customer_success", "ticket_resolution_time", "metric",
       "Average support ticket resolution time", "customer_success", "cs_team", 0.90, 4},
      {"customer_success", "expansion_revenue", "metric",
       "Revenue from existing customer expansions", "customer_success", "cs_team", 0.84, 168}
    ]
  end

  @doc false
  def relationships do
    [
      {"hr", "enps", "CAUSES", "hr", "attrition_rate", 0.8},
      {"hr", "attrition_rate", "CONTRIBUTES_TO", "finance", "operating_expenses", 0.6},
      {"product", "churn_rate", "CORRELATES_WITH", "product", "nps", 0.7},
      {"product", "nps", "DEPENDS_ON", "product", "feature_adoption", 0.5},
      {"product", "churn_rate", "CONTRIBUTES_TO", "finance", "arr", 0.75},
      {"product", "retention_rate", "CORRELATES_WITH", "product", "churn_rate", 0.85},
      {"product", "time_to_value", "CAUSES", "product", "retention_rate", 0.6},
      {"product", "dau", "CORRELATES_WITH", "product", "retention_rate", 0.65},
      {"engineering", "deployment_frequency", "CORRELATES_WITH", "engineering", "lead_time", 0.7},
      {"engineering", "change_failure_rate", "CORRELATES_WITH", "engineering", "incident_rate",
       0.8},
      {"engineering", "incident_rate", "CAUSES", "engineering", "mttr", 0.5},
      {"hr", "hiring_velocity", "CONTRIBUTES_TO", "hr", "headcount", 0.4},
      {"hr", "compensation_ratio", "CAUSES", "hr", "attrition_rate", 0.55},
      {"customer_success", "csat", "CORRELATES_WITH", "product", "nps", 0.75},
      {"customer_success", "ticket_resolution_time", "CAUSES", "customer_success", "csat", 0.6},
      {"customer_success", "expansion_revenue", "CONTRIBUTES_TO", "finance", "arr", 0.3},
      {"finance", "cac", "CORRELATES_WITH", "finance", "ltv", 0.65}
    ]
  end

  # --- Helpers ---

  defp q!(db, query) do
    case Native.execute(db, query) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Seed query failed: #{reason}\nQuery: #{query}"
    end
  end

  defp escape(str) do
    String.replace(str, "'", "\\'")
  end
end
