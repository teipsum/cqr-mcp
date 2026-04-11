defmodule CqrMcp.Resources do
  @moduledoc """
  MCP resource definitions.

  Exposes organizational context as browsable MCP resources:
  - `cqr://scopes` — Scope hierarchy
  - `cqr://entities` — Entity definitions
  - `cqr://policies` — Governance policies
  - `cqr://system_prompt` — Agent generation contract
  """

  alias Cqr.Repo.ScopeTree
  alias Cqr.Repo.Semantic
  alias Cqr.Scope
  alias Cqr.Types

  @doc "Return the list of available MCP resources."
  def list do
    [
      %{
        "uri" => "cqr://session",
        "name" => "Agent Session",
        "description" => "Current agent identity, scope, permissions, and connection metadata",
        "mimeType" => "application/json"
      },
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
  def read("cqr://session"), do: {:ok, read_session()}
  def read("cqr://scopes"), do: {:ok, read_scopes()}
  def read("cqr://entities"), do: {:ok, read_entities()}
  def read("cqr://policies"), do: {:ok, read_policies()}
  def read("cqr://system_prompt"), do: {:ok, read_system_prompt()}
  def read(uri), do: {:error, "Unknown resource: #{uri}"}

  # --- Session ---

  defp read_session do
    agent_id = System.get_env("CQR_AGENT_ID", "anonymous")
    agent_scope_str = System.get_env("CQR_AGENT_SCOPE", "scope:company")
    agent_scope_segments = parse_scope(agent_scope_str)

    visible =
      agent_scope_segments
      |> ScopeTree.visible_scopes()
      |> Enum.map(&Types.format_scope/1)

    boot_unix = :persistent_term.get({CqrMcp.Application, :boot_unix})
    boot_iso = :persistent_term.get({CqrMcp.Application, :boot_iso})
    session_id = :persistent_term.get({CqrMcp.Application, :session_id})

    %{
      "agent_id" => agent_id,
      "agent_scope" => Types.format_scope(agent_scope_segments),
      "visible_scopes" => visible,
      "permissions" => ["resolve", "discover", "certify", "assert", "trace", "signal", "refresh"],
      "connected_adapters" => ["grafeo"],
      "server_version" => server_version(),
      "protocol" => "CQR/1.0",
      "uptime_seconds" => System.system_time(:second) - boot_unix,
      "connection" => %{
        "transport" => "stdio",
        "connected_at" => boot_iso,
        "session_id" => session_id
      }
    }
  end

  defp parse_scope(str) do
    str
    |> String.trim_leading("scope:")
    |> String.split(":", trim: true)
  end

  defp server_version do
    case Application.spec(:cqr_mcp, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  # --- Scopes ---

  defp read_scopes do
    scopes = Scope.all_scopes()

    %{
      "hierarchy" =>
        Enum.map(scopes, fn segments ->
          %{
            "path" => Types.format_scope(segments),
            "name" => List.last(segments),
            "level" => length(segments) - 1,
            "children" =>
              segments
              |> ScopeTree.children()
              |> Enum.map(&Types.format_scope/1)
          }
        end)
    }
  end

  # --- Entities ---

  defp read_entities do
    entities =
      Scope.all_scopes()
      |> Enum.flat_map(&entities_for_scope/1)
      |> Enum.uniq_by(fn e -> e["entity"] end)

    %{"entities" => entities, "count" => length(entities)}
  end

  defp entities_for_scope(scope) do
    case Semantic.entities_in_scope(scope) do
      {:ok, ents} -> Enum.map(ents, &format_entity_json(&1, scope))
      _ -> []
    end
  end

  defp format_entity_json(e, scope) do
    %{
      "entity" => "entity:#{e.namespace}:#{e.name}",
      "type" => e.type,
      "description" => e.description,
      "scope" => Types.format_scope(scope),
      "owner" => e.owner,
      "reputation" => e.reputation
    }
  end

  defp entity_lines_for_scope(scope) do
    case Semantic.entities_in_scope(scope) do
      {:ok, ents} -> Enum.map(ents, &format_entity_line(&1, scope))
      _ -> []
    end
  end

  defp format_entity_line(e, scope) do
    "  #{e.namespace}:#{e.name} (#{e.type}) -- #{e.description} [#{Types.format_scope(scope)}]"
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
    scopes = Scope.all_scopes()

    entities =
      scopes
      |> Enum.flat_map(&entity_lines_for_scope/1)
      |> Enum.uniq()

    scope_tree =
      Enum.map(scopes, fn segments ->
        indent = String.duplicate("  ", length(segments) - 1)
        "#{indent}#{Types.format_scope(segments)}"
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

    ### TRACE -- Walk the provenance chain
    ```
    TRACE entity:namespace:name [OVER last <duration>] [DEPTH causal:<n>] [INCLUDE state_transitions, actors, triggers]
    ```

    ### SIGNAL -- Write a reputation assessment
    ```
    SIGNAL reputation ON entity:namespace:name SCORE <0.0-1.0> EVIDENCE "rationale" [AGENT agent:id]
    ```

    ### REFRESH -- Scan for stale context
    ```
    REFRESH CHECK active_context [WITHIN scope:...] [WHERE age > <duration>] [RETURN stale_items]
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

    User: "How did the churn_rate metric come to exist and who signed off?"
    CQR: TRACE entity:product:churn_rate DEPTH causal:2

    User: "Mark the burn_rate as unreliable because the upstream pipeline broke"
    CQR: SIGNAL reputation ON entity:finance:burn_rate SCORE 0.3 EVIDENCE "upstream ETL failed overnight"

    User: "What context is stale and needs refreshing?"
    CQR: REFRESH CHECK active_context WHERE age > 24h RETURN stale_items

    ## Quality Metadata
    Every response includes: freshness, confidence, reputation, owner, lineage, certification status.
    Use this metadata to assess trustworthiness before making decisions based on the data.
    """
  end
end
