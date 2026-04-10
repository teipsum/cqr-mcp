defmodule CqrMcp.Resources do
  @moduledoc """
  MCP resource definitions.

  Exposes organizational context as browsable MCP resources:
  - `cqr://scopes` — Scope hierarchy
  - `cqr://entities` — Entity definitions
  - `cqr://policies` — Governance policies
  - `cqr://system_prompt` — Agent generation contract
  """

  @doc "Return the list of available MCP resources."
  def list do
    [
      %{
        "uri" => "cqr://scopes",
        "name" => "Organizational Scopes",
        "description" => "Scope hierarchy with visibility rules",
        "mimeType" => "application/json"
      },
      %{
        "uri" => "cqr://entities",
        "name" => "Entity Definitions",
        "description" =>
          "All registered entities with namespace, type, scope, and certification status",
        "mimeType" => "application/json"
      },
      %{
        "uri" => "cqr://policies",
        "name" => "Governance Policies",
        "description" =>
          "Governance rules, freshness requirements, and reputation thresholds per scope",
        "mimeType" => "application/json"
      },
      %{
        "uri" => "cqr://system_prompt",
        "name" => "CQR Agent Generation Contract",
        "description" =>
          "System prompt for LLMs to generate CQR expressions from natural language",
        "mimeType" => "text/plain"
      }
    ]
  end

  @doc "Read a resource by URI."
  def read("cqr://scopes"), do: {:ok, read_scopes()}
  def read("cqr://entities"), do: {:ok, read_entities()}
  def read("cqr://policies"), do: {:ok, read_policies()}
  def read("cqr://system_prompt"), do: {:ok, read_system_prompt()}
  def read(uri), do: {:error, "Unknown resource: #{uri}"}

  # --- Scopes ---

  defp read_scopes do
    scopes = Cqr.Scope.all_scopes()

    %{
      "hierarchy" =>
        Enum.map(scopes, fn segments ->
          %{
            "path" => Cqr.Types.format_scope(segments),
            "name" => List.last(segments),
            "level" => length(segments) - 1,
            "children" =>
              Cqr.Repo.ScopeTree.children(segments)
              |> Enum.map(fn c -> Cqr.Types.format_scope(c) end)
          }
        end)
    }
  end

  # --- Entities ---

  defp read_entities do
    scopes = Cqr.Scope.all_scopes()

    entities =
      Enum.flat_map(scopes, fn scope ->
        case Cqr.Repo.Semantic.entities_in_scope(scope) do
          {:ok, ents} ->
            Enum.map(ents, fn e ->
              %{
                "entity" => "entity:#{e.namespace}:#{e.name}",
                "type" => e.type,
                "description" => e.description,
                "scope" => Cqr.Types.format_scope(scope),
                "owner" => e.owner,
                "reputation" => e.reputation
              }
            end)

          _ ->
            []
        end
      end)
      |> Enum.uniq_by(fn e -> e["entity"] end)

    %{"entities" => entities, "count" => length(entities)}
  end

  # --- Policies ---

  defp read_policies do
    %{
      "governance" => %{
        "scope_first_semantics" =>
          "Scope determines visibility BEFORE data retrieval. Out-of-scope entities are genuinely invisible, not access-denied.",
        "quality_metadata" =>
          "Every response includes mandatory quality metadata: freshness, confidence, reputation, owner, lineage.",
        "certification_lifecycle" => "proposed -> under_review -> certified -> superseded",
        "conflict_preservation" =>
          "When multiple sources disagree, all values are returned with source attribution."
      },
      "defaults" => %{
        "freshness_requirement" => "none (accept any age)",
        "reputation_threshold" => 0.0,
        "default_scope" => "scope:company",
        "default_depth" => 2
      }
    }
  end

  # --- System Prompt ---

  defp read_system_prompt do
    scopes = Cqr.Scope.all_scopes()

    entities =
      Enum.flat_map(scopes, fn scope ->
        case Cqr.Repo.Semantic.entities_in_scope(scope) do
          {:ok, ents} ->
            Enum.map(ents, fn e ->
              "  #{e.namespace}:#{e.name} (#{e.type}) -- #{e.description} [#{Cqr.Types.format_scope(scope)}]"
            end)

          _ ->
            []
        end
      end)
      |> Enum.uniq()

    scope_tree =
      Enum.map(scopes, fn segments ->
        indent = String.duplicate("  ", length(segments) - 1)
        "#{indent}#{Cqr.Types.format_scope(segments)}"
      end)

    """
    # CQR Agent Generation Contract

    You have access to governed organizational context through CQR (Semantic Query Resolution).
    Generate CQR expressions to retrieve, explore, and govern organizational data.

    ## Grammar

    ### RESOLVE -- Retrieve a canonical entity
    ```
    RESOLVE entity:namespace:name [FROM scope:...] [WITH freshness < duration] [WITH reputation > score] [INCLUDE annotations] [FALLBACK scope:... -> scope:...]
    ```

    ### DISCOVER -- Explore related concepts
    ```
    DISCOVER concepts RELATED TO entity:namespace:name [WITHIN scope:...] [DEPTH n] [ANNOTATE annotations] [LIMIT n]
    ```

    ### CERTIFY -- Govern definitions
    ```
    CERTIFY entity:namespace:name STATUS proposed|under_review|certified|superseded [AUTHORITY id] [EVIDENCE "..."]
    ```

    ## Available Scopes
    #{Enum.join(scope_tree, "\n")}

    ## Available Entities
    #{Enum.join(entities, "\n")}

    ## Examples

    User: "What's our current ARR?"
    CQR: RESOLVE entity:finance:arr

    User: "What data do we have related to customer churn?"
    CQR: DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 2

    User: "I want to certify the NPS metric definition"
    CQR: CERTIFY entity:product:nps STATUS proposed AUTHORITY product_team

    User: "Show me ARR but only if it's recent and trustworthy"
    CQR: RESOLVE entity:finance:arr WITH freshness < 24h WITH reputation > 0.8

    ## Quality Metadata
    Every response includes: freshness, confidence, reputation, owner, lineage, certification status.
    Use this metadata to assess trustworthiness before making decisions based on the data.
    """
  end
end
