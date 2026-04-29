defmodule CqrMcp.Tools do
  @moduledoc """
  MCP tool definitions for the CQR planner.

  Provides the tools surfaced to MCP clients: cqr_resolve, cqr_resolve_batch,
  cqr_discover, cqr_certify, cqr_assert, cqr_assert_batch, cqr_trace,
  cqr_signal, cqr_refresh, cqr_awareness, cqr_hypothesize, cqr_compare,
  cqr_anchor, and cqr_update.

  Each tool definition includes name, description, and JSON Schema for inputs.
  Tool execution delegates to `Cqr.Engine.execute/2`.
  """

  @doc "Return the list of available MCP tools."
  def list do
    [
      resolve_tool(),
      resolve_batch_tool(),
      discover_tool(),
      certify_tool(),
      assert_tool(),
      assert_batch_tool(),
      trace_tool(),
      signal_tool(),
      refresh_tool(),
      awareness_tool(),
      hypothesize_tool(),
      compare_tool(),
      anchor_tool(),
      update_tool()
    ]
  end

  @doc "Execute a tool call by name with the given arguments and agent context."
  def call("cqr_resolve", args, context) do
    expression = build_resolve_expression(args)
    execute_and_format(expression, context)
  end

  def call("cqr_resolve_batch", %{"entities" => entities} = args, context)
      when is_list(entities) do
    case build_resolve_batch_expression(args) do
      {:ok, expression} -> execute_and_format(expression, context)
      {:error, error} -> {:error, error}
    end
  end

  def call("cqr_resolve_batch", _args, _context) do
    {:error,
     %{
       "code" => -32_602,
       "message" => "Missing or invalid required field: entities (must be an array)"
     }}
  end

  def call("cqr_discover", args, context) do
    expression = build_discover_expression(args)
    execute_and_format(expression, context)
  end

  def call("cqr_certify", args, context) do
    expression = build_certify_expression(args)
    execute_and_format(expression, context)
  end

  def call("cqr_assert", args, context) do
    case build_assert_expression(args) do
      {:ok, expression, relationships} ->
        enriched_context = Map.put(context, :relationships, relationships)
        execute_and_format(expression, enriched_context)

      {:error, error} ->
        {:error, error}
    end
  end

  def call("cqr_assert_batch", %{"entities" => entities}, context) when is_list(entities) do
    if entities == [] do
      {:error, %{"code" => -32_602, "message" => "entities must be a non-empty array"}}
    else
      results = Enum.map(entities, &execute_single_assert(&1, context))
      {:ok, summarize_batch(results)}
    end
  end

  def call("cqr_assert_batch", _args, _context) do
    {:error, %{"code" => -32_602, "message" => "Missing or invalid required field: entities"}}
  end

  def call("cqr_trace", args, context) do
    expression = build_trace_expression(args)
    execute_and_format(expression, context)
  end

  def call("cqr_signal", args, context) do
    case build_signal_expression(args) do
      {:ok, expression} -> execute_and_format(expression, context)
      {:error, error} -> {:error, error}
    end
  end

  def call("cqr_refresh", args, context) do
    expression = build_refresh_expression(args)
    execute_and_format(expression, context)
  end

  def call("cqr_awareness", args, context) do
    expression = build_awareness_expression(args)
    execute_and_format(expression, context)
  end

  def call("cqr_hypothesize", args, context) do
    case build_hypothesize_expression(args) do
      {:ok, expression} -> execute_and_format(expression, context)
      {:error, error} -> {:error, error}
    end
  end

  def call("cqr_compare", args, context) do
    case build_compare_expression(args) do
      {:ok, expression} -> execute_and_format(expression, context)
      {:error, error} -> {:error, error}
    end
  end

  def call("cqr_anchor", args, context) do
    case build_anchor_expression(args) do
      {:ok, expression} -> execute_and_format(expression, context)
      {:error, error} -> {:error, error}
    end
  end

  def call("cqr_update", args, context) do
    case build_update_expression(args) do
      {:ok, expression} -> execute_and_format(expression, context)
      {:error, error} -> {:error, error}
    end
  end

  def call(name, _args, _context) do
    {:error, %{"code" => -32_601, "message" => "Unknown tool: #{name}"}}
  end

  # --- Tool definitions ---

  defp resolve_tool do
    %{
      "name" => "cqr_resolve",
      "description" =>
        "Resolve a canonical entity by semantic address from governed organizational context. " <>
          "Returns the entity's current value with quality metadata (freshness, reputation, owner, lineage).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "entity" => %{
            "type" => "string",
            "description" =>
              "Entity reference. Addresses are hierarchical with unlimited depth: " <>
                "entity:namespace:name (e.g., entity:finance:arr), or deeper paths like " <>
                "entity:product:churn:rolling_30d (3 segments), " <>
                "entity:product:retention:cohort:q4 (4 segments), " <>
                "entity:product:retention:cohort:q4:weekly (5 segments). " <>
                "Each interior segment names a container that is auto-created on first " <>
                "ASSERT and CONTAINS its descendants. Containment-aware visibility " <>
                "applies the agent's scope at every level of the path -- a denial at " <>
                "any ancestor returns entity_not_found, never scope_access."
          },
          "scope" => %{
            "type" => "string",
            "description" =>
              "Scope constraint in format scope:seg1:seg2 (e.g., scope:company:finance)"
          },
          "freshness" => %{
            "type" => "string",
            "description" => "Maximum age requirement (e.g., 24h, 7d, 30m)"
          },
          "reputation" => %{
            "type" => "number",
            "description" => "Minimum reputation threshold (0.0 to 1.0)"
          }
        },
        "required" => ["entity"]
      }
    }
  end

  defp resolve_batch_tool do
    %{
      "name" => "cqr_resolve_batch",
      "description" =>
        "Resolve many entities in a single MCP call. Accepts an array of hierarchical " <>
          "entity addresses (recommended ceiling 50) and returns one row per entity " <>
          "with the same payload shape as cqr_resolve plus a per-row status field. " <>
          "Designed for the orient phase of an agent's cold start, where 5-50 entities " <>
          "must be pulled at once: this collapses N MCP round-trips into 1, removing " <>
          "the per-call serialization, scope-narrowing, and adapter dispatch overhead. " <>
          "Privacy contract: an entity that is blocked by ancestor scope returns " <>
          "status:not_found, byte-identical to a row for an entity that does not " <>
          "exist. The agent cannot use this tool to probe for the existence of " <>
          "entities outside its visible scopes.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "entities" => %{
            "type" => "array",
            "description" =>
              "Array of hierarchical entity addresses to resolve. Each entry uses the " <>
                "same form accepted by cqr_resolve (entity:namespace:name, with " <>
                "namespace optionally containing additional segments). Empty array " <>
                "is allowed and returns an empty result list. Recommended ceiling 50.",
            "items" => %{"type" => "string"}
          },
          "scope" => %{
            "type" => "string",
            "description" =>
              "Optional scope constraint applied to every entity in the batch. Same " <>
                "format as cqr_resolve: scope:seg1:seg2 (e.g., scope:company:finance)."
          },
          "freshness" => %{
            "type" => "string",
            "description" =>
              "Optional maximum age requirement applied to every entity (e.g., 24h, 7d, 30m)."
          },
          "reputation" => %{
            "type" => "number",
            "description" =>
              "Optional minimum reputation threshold (0.0 to 1.0) applied to every entity."
          }
        },
        "required" => ["entities"]
      }
    }
  end

  defp discover_tool do
    %{
      "name" => "cqr_discover",
      "description" =>
        "Discover concepts related to an entity or topic within governed organizational context. " <>
          "Returns a neighborhood map with relationship types and quality annotations.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "topic" => %{
            "type" => "string",
            "description" =>
              "Entity reference, hierarchical prefix, or free-text search term. " <>
                "Three modes: " <>
                "(1) anchor mode -- a full address like entity:product:churn_rate or " <>
                "entity:product:retention:cohort:q4 returns the neighborhood reachable " <>
                "via typed relationships (CORRELATES_WITH, DEPENDS_ON, CONTRIBUTES_TO, " <>
                "etc.); " <>
                "(2) prefix mode -- a hierarchical address ending in :* like " <>
                "entity:product:retention:* enumerates every descendant via CONTAINS " <>
                "edges, depth-first. Branch-level scope pruning hides whole subtrees " <>
                "the agent cannot see, so a blocked subtree is indistinguishable from " <>
                "a missing one; " <>
                "(3) free-text mode -- a plain search term (no entity: prefix) is passed " <>
                "as a quoted string to BM25 + HNSW; the server quotes it for you, do " <>
                "not pre-quote."
          },
          "scope" => %{
            "type" => "string",
            "description" =>
              "Scope constraint (comma-separated for multiple, e.g., scope:product,scope:finance)"
          },
          "depth" => %{
            "type" => "integer",
            "description" => "Traversal depth (default: 2)",
            "default" => 2
          },
          "direction" => %{
            "type" => "string",
            "enum" => ["outbound", "inbound", "both"],
            "description" =>
              "Which edge direction(s) to traverse from the topic entity. " <>
                "'outbound' returns entities the topic points TO; " <>
                "'inbound' returns entities that point AT the topic; " <>
                "'both' (default) returns the union with each result tagged " <>
                "by direction. Edges are stored once, directionally; the " <>
                "relationship type always reads in its original direction.",
            "default" => "both"
          },
          "max_results" => %{
            "type" => "integer",
            "description" =>
              "Maximum number of results to return. Applies to all three " <>
                "DISCOVER modes (anchor, prefix, free-text). Default 10.",
            "default" => 10
          },
          "near" => %{
            "type" => "string",
            "description" =>
              "Optional entity address (e.g., entity:engineering:proposals:resolve_batch). " <>
                "When provided in free-text search mode, results are biased toward " <>
                "entities both semantically related to the topic AND structurally " <>
                "adjacent to this anchor in the relationship graph (BFS distance " <>
                "through CORRELATES_WITH, DEPENDS_ON, CONTRIBUTES_TO, CAUSES, " <>
                "PART_OF, and CONTAINS edges, capped at depth 4). Result rows " <>
                "gain a near_distance field. Has no effect in anchor mode or " <>
                "prefix mode."
          }
        },
        "required" => ["topic"]
      }
    }
  end

  defp assert_tool do
    %{
      "name" => "cqr_assert",
      "description" =>
        "Assert governed but uncertified context into the organizational knowledge graph. " <>
          "The asserted entity is immediately visible to cqr_resolve and cqr_discover, but " <>
          "carries lower trust than certified entities (reputation 0.5, certified false, " <>
          "with a mandatory INTENT and DERIVED_FROM paper trail). Use this to record " <>
          "agent-generated findings, derived metrics, observations, and working hypotheses.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "entity" => %{
            "type" => "string",
            "description" =>
              "Semantic address for the new context. Hierarchical with unlimited depth: " <>
                "entity:namespace:name or deeper, e.g. entity:product:churn:rolling_30d, " <>
                "entity:product:retention:cohort:q4 (4 segments), " <>
                "entity:product:retention:cohort:q4:weekly (5 segments). Interior " <>
                "segments are auto-created as container entities and CONTAINS edges " <>
                "are written from each parent to its child. Containers inherit the " <>
                "scope of the asserting agent, so an agent at scope:company:product " <>
                "asserting entity:product:retention:cohort:q4:weekly creates the " <>
                "intermediate retention and cohort containers in scope:company:product."
          },
          "type" => %{
            "type" => "string",
            "description" =>
              "Entity type: metric, definition, policy, derived_metric, observation, or recommendation"
          },
          "description" => %{
            "type" => "string",
            "description" => "Human-readable description of the entity"
          },
          "intent" => %{
            "type" => "string",
            "description" =>
              "Why the agent is asserting this -- the use case, task context, or question being " <>
                "answered. Mandatory for governance auditability."
          },
          "derived_from" => %{
            "type" => "string",
            "description" =>
              "Comma-separated source entity references. Each may be hierarchical at any " <>
                "depth: entity:ns:name or entity:ns:mid:leaf or deeper, e.g. " <>
                "'entity:product:churn_rate,entity:product:retention:cohort:q4'. " <>
                "Mandatory cognitive lineage."
          },
          "scope" => %{
            "type" => "string",
            "description" =>
              "Target scope (scope:seg1:seg2). Defaults to the agent's active scope if omitted."
          },
          "confidence" => %{
            "type" => "number",
            "description" =>
              "Agent's self-assessed confidence in this assertion (0.0 to 1.0). Default 0.5."
          },
          "relationships" => %{
            "type" => "string",
            "description" =>
              "Optional typed relationships to existing entities, as a comma-separated list. " <>
                "Each relationship uses the shorthand REL:<entity_address>:strength. The " <>
                "entity address may be hierarchical at any depth, e.g. " <>
                "'CORRELATES_WITH:entity:product:nps:0.7' (3-segment target) or " <>
                "'DEPENDS_ON:entity:product:retention:cohort:q4:0.6' (5-segment target). " <>
                "Strength is the trailing decimal in [0.0, 1.0]; the parser splits on " <>
                "the final colon so any number of preceding segments are treated as the " <>
                "target address. Valid relationship types: CORRELATES_WITH, CONTRIBUTES_TO, " <>
                "DEPENDS_ON, CAUSES, PART_OF."
          }
        },
        "required" => ["entity", "type", "description", "intent", "derived_from"]
      }
    }
  end

  defp assert_batch_tool do
    %{
      "name" => "cqr_assert_batch",
      "description" =>
        "Assert multiple entities in a single call. Accepts an array of entity objects " <>
          "with the same fields as cqr_assert (entity, type, description, intent, " <>
          "derived_from, optional confidence and scope). Each entity is executed " <>
          "independently: a failure on one does not prevent the others from being " <>
          "asserted. Returns a summary with total, created, skipped (entity already " <>
          "exists), failed counts, and a per-entity result list. Use this when an " <>
          "agent needs to record 10-20 findings at once without paying the per-call " <>
          "LLM token overhead of cqr_assert.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "entities" => %{
            "type" => "array",
            "description" =>
              "Array of entity objects to assert. Each object has the same fields " <>
                "as a cqr_assert call: entity (required), type (required), description " <>
                "(required), intent (required), derived_from (required), scope (optional), " <>
                "confidence (optional), relationships (optional).",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "entity" => %{"type" => "string"},
                "type" => %{"type" => "string"},
                "description" => %{"type" => "string"},
                "intent" => %{"type" => "string"},
                "derived_from" => %{"type" => "string"},
                "scope" => %{"type" => "string"},
                "confidence" => %{"type" => "number"},
                "relationships" => %{"type" => "string"}
              },
              "required" => ["entity", "type", "description", "intent", "derived_from"]
            }
          }
        },
        "required" => ["entities"]
      }
    }
  end

  defp trace_tool do
    %{
      "name" => "cqr_trace",
      "description" =>
        "Trace the provenance history of an entity: how it came to exist, what changed " <>
          "it, who acted on it, and what it was derived from. Returns the assertion record, " <>
          "certification history, signal history, and the derived-from chain.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "entity" => %{
            "type" => "string",
            "description" =>
              "Entity to trace. Hierarchical addresses are supported at any depth, e.g. " <>
                "entity:finance:arr (3 segments) or " <>
                "entity:product:retention:cohort:q4 (5 segments). The provenance walk " <>
                "starts from the leaf and follows DERIVED_FROM regardless of depth."
          },
          "depth" => %{
            "type" => "integer",
            "description" =>
              "Causal chain depth: how many hops to follow through DERIVED_FROM. Default 1.",
            "default" => 1
          },
          "time_window" => %{
            "type" => "string",
            "description" =>
              "Time window to filter events (e.g., '24h', '7d', '30m'). Default: all history."
          }
        },
        "required" => ["entity"]
      }
    }
  end

  defp signal_tool do
    %{
      "name" => "cqr_signal",
      "description" =>
        "Write a quality or reputation assessment on an entity. Updates the entity's " <>
          "reputation score and records a SignalRecord for audit traceability. Use this " <>
          "when an agent observes that an entity's data quality has changed: a pipeline " <>
          "refreshed (score up), a source went stale (score down), or a validation check " <>
          "failed (score down).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "entity" => %{
            "type" => "string",
            "description" =>
              "Entity to signal. Hierarchical addresses at any depth, e.g. " <>
                "entity:product:nps or entity:product:retention:cohort:q4. " <>
                "Containment-aware visibility applies: if any ancestor in the " <>
                "address is outside the agent's visible scopes the call returns " <>
                "entity_not_found, never scope_access."
          },
          "score" => %{
            "type" => "number",
            "description" => "New reputation score (0.0 = unreliable, 1.0 = fully trustworthy)"
          },
          "evidence" => %{
            "type" => "string",
            "description" => "Rationale for the reputation change"
          }
        },
        "required" => ["entity", "score", "evidence"]
      }
    }
  end

  defp refresh_tool do
    %{
      "name" => "cqr_refresh",
      "description" =>
        "Check for stale context. Scans all entities visible to the agent and returns " <>
          "those whose freshness exceeds the threshold. Use this as a periodic health " <>
          "check to identify context that needs attention. Returns stale items sorted by " <>
          "staleness (most stale first).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "threshold" => %{
            "type" => "string",
            "description" => "Staleness threshold (e.g., '24h', '7d', '30m'). Default: '24h'.",
            "default" => "24h"
          },
          "scope" => %{
            "type" => "string",
            "description" =>
              "Scope to check (e.g., scope:company:product). Default: agent's full scope."
          }
        },
        "required" => []
      }
    }
  end

  defp awareness_tool do
    %{
      "name" => "cqr_awareness",
      "description" =>
        "Perceive ambient agent activity in the visible scopes. Returns one row per " <>
          "agent that has recently asserted, certified, or signaled in the scopes the " <>
          "calling agent can see, with the entities they touched and the intents they " <>
          "declared. Use this before starting work to coordinate without explicit " <>
          "messaging: avoid duplicating an in-flight investigation, see who owns " <>
          "nearby entities, surface fresh intents for the area. Ranked by recent " <>
          "activity volume.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "scope" => %{
            "type" => "string",
            "description" =>
              "Scope to scan (e.g., scope:company:product). Default: agent's full " <>
                "visible scope set."
          },
          "time_window" => %{
            "type" => "string",
            "description" =>
              "Recency window for audit events (e.g., '24h', '7d', '30m'). " <>
                "Default: full history."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of agents to return. Default 20.",
            "default" => 20
          }
        },
        "required" => []
      }
    }
  end

  defp hypothesize_tool do
    %{
      "name" => "cqr_hypothesize",
      "description" =>
        "Project the downstream effects of an assumed change to an entity. " <>
          "Walks the relationship and DERIVED_FROM graph outward from the target, " <>
          "computing a blast radius of entities that would be affected and a " <>
          "confidence score that decays with each hop. Use this to answer " <>
          "what-if questions: 'if this metric became unreliable, what else " <>
          "would I stop trusting?' Returns the hypothetical change, the affected " <>
          "entities tagged with depth, relationship, hop_confidence and " <>
          "projected_reputation, and a summary count.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "entity" => %{
            "type" => "string",
            "description" =>
              "Entity being hypothesized about. Hierarchical addresses at any depth, " <>
                "e.g. entity:product:churn_rate or " <>
                "entity:product:retention:cohort:q4."
          },
          "reputation" => %{
            "type" => "number",
            "description" =>
              "Hypothetical new reputation value in [0.0, 1.0]. The delta from " <>
                "the entity's current reputation propagates outward, scaled by " <>
                "edge strength and the per-hop decay."
          },
          "depth" => %{
            "type" => "integer",
            "description" => "Maximum hop distance to walk. Default 2.",
            "default" => 2
          },
          "decay" => %{
            "type" => "number",
            "description" =>
              "Confidence decay multiplier applied per hop, in [0.0, 1.0]. Default 0.7. " <>
                "Lower values mean confidence falls off faster as the projection " <>
                "moves away from the source of the hypothesis."
          }
        },
        "required" => ["entity", "reputation"]
      }
    }
  end

  defp compare_tool do
    %{
      "name" => "cqr_compare",
      "description" =>
        "Compare two or more entities side-by-side. Returns shared relationships, " <>
          "differing properties (type, description, owner), and quality metadata " <>
          "differences (reputation, certification status, freshness). Use this when " <>
          "an agent needs to choose between alternatives or audit divergence between " <>
          "candidate definitions in the same domain.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "entities" => %{
            "type" => "string",
            "description" =>
              "Comma-separated entity references to compare. Each may be hierarchical at " <>
                "any depth, e.g. " <>
                "'entity:finance:arr,entity:product:retention:cohort:q4'. At least two " <>
                "required."
          },
          "include" => %{
            "type" => "string",
            "description" =>
              "Optional comma-separated facets to include: relationships, properties, " <>
                "quality. Defaults to all three."
          }
        },
        "required" => ["entities"]
      }
    }
  end

  defp anchor_tool do
    %{
      "name" => "cqr_anchor",
      "description" =>
        "Evaluate the composite confidence of a chain of entities used together as a " <>
          "reasoning step. Returns the weakest-link confidence floor, average reputation, " <>
          "lists of missing, uncertified, stale, and below-reputation links, and " <>
          "actionable recommendations (certify X, refresh Y, raise reputation on Z) so " <>
          "an agent can decide whether to trust the chain enough to act on it.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "entities" => %{
            "type" => "string",
            "description" =>
              "Comma-separated list of entity references forming the reasoning chain. " <>
                "Each may be hierarchical at any depth, e.g. " <>
                "'entity:finance:arr,entity:product:retention:cohort:q4'. At least one " <>
                "entity is required; most useful with two or more."
          },
          "rationale" => %{
            "type" => "string",
            "description" =>
              "Optional free-text description of the decision this chain underwrites. " <>
                "Surfaced back in the result for audit traceability."
          },
          "freshness" => %{
            "type" => "string",
            "description" =>
              "Optional staleness threshold (e.g. '24h', '7d'). Entities older than this " <>
                "are flagged stale."
          },
          "reputation" => %{
            "type" => "number",
            "description" =>
              "Optional minimum reputation threshold (0.0 to 1.0). Entities below it are " <>
                "flagged and surfaced in recommendations."
          }
        },
        "required" => ["entities"]
      }
    }
  end

  defp update_tool do
    %{
      "name" => "cqr_update",
      "description" =>
        "Evolve the content of an existing entity while preserving its prior " <>
          "state as a VersionRecord. Governance decides whether the change " <>
          "applies immediately, transitions the entity to contested for " <>
          "pending review, or is blocked. Use CHANGE_TYPE correction or " <>
          "refresh for factual/freshness fixes, scope_change to re-scope, " <>
          "redefinition to change the entity's meaning, or reclassification " <>
          "to change its type. On a certified entity, redefinition and " <>
          "reclassification are deferred to governance (entity becomes " <>
          "contested; a pending UpdateRecord is written).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "entity" => %{
            "type" => "string",
            "description" =>
              "Entity to update. Hierarchical addresses at any depth, e.g. " <>
                "entity:product:churn_rate or " <>
                "entity:product:retention:cohort:q4. The address is preserved across " <>
                "the update -- UPDATE evolves content, not identity, regardless of depth."
          },
          "change_type" => %{
            "type" => "string",
            "enum" => [
              "correction",
              "refresh",
              "redefinition",
              "scope_change",
              "reclassification"
            ],
            "description" => "Semantic category of the change"
          },
          "description" => %{
            "type" => "string",
            "description" => "New description text (optional)"
          },
          "type" => %{
            "type" => "string",
            "description" => "New entity type identifier (optional)"
          },
          "evidence" => %{
            "type" => "string",
            "description" => "Rationale for the change (optional)"
          },
          "confidence" => %{
            "type" => "number",
            "description" => "New confidence score in [0.0, 1.0] (optional)"
          }
        },
        "required" => ["entity", "change_type"]
      }
    }
  end

  defp certify_tool do
    %{
      "name" => "cqr_certify",
      "description" =>
        "Propose, review, or approve a governance definition in the organizational context. " <>
          "Manages the certification lifecycle: proposed -> under_review -> certified.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "entity" => %{
            "type" => "string",
            "description" =>
              "Entity to certify. Hierarchical addresses at any depth, e.g. " <>
                "entity:finance:arr or " <>
                "entity:product:retention:cohort:q4. Containment-aware visibility " <>
                "applies: a CERTIFY against an address whose ancestor is outside the " <>
                "agent's visible scopes returns entity_not_found, never scope_access."
          },
          "status" => %{
            "type" => "string",
            "enum" => ["proposed", "under_review", "certified", "contested", "superseded"],
            "description" => "Target certification status"
          },
          "authority" => %{
            "type" => "string",
            "description" => "Certification authority identifier"
          },
          "evidence" => %{
            "type" => "string",
            "description" => "Supporting evidence for the certification action"
          }
        },
        "required" => ["entity", "status"]
      }
    }
  end

  # --- Batch execution ---

  defp execute_single_assert(entity_args, context) when is_map(entity_args) do
    entity_ref = entity_args["entity"] || "<unknown>"

    case build_assert_expression(entity_args) do
      {:ok, expression, relationships} ->
        enriched = Map.put(context, :relationships, relationships)

        case Cqr.Engine.execute(expression, enriched) do
          {:ok, result} ->
            %{"entity" => entity_ref, "status" => "created", "data" => format_result(result)}

          {:error, %Cqr.Error{code: :entity_exists} = err} ->
            %{"entity" => entity_ref, "status" => "skipped", "error" => err.message}

          {:error, %Cqr.Error{} = err} ->
            %{
              "entity" => entity_ref,
              "status" => "failed",
              "code" => error_code_to_int(err.code),
              "error" => err.message
            }
        end

      {:error, err} ->
        %{
          "entity" => entity_ref,
          "status" => "failed",
          "code" => err["code"],
          "error" => err["message"]
        }
    end
  end

  defp execute_single_assert(_other, _context) do
    %{
      "entity" => "<invalid>",
      "status" => "failed",
      "code" => -32_602,
      "error" => "entity entry must be a JSON object"
    }
  end

  defp summarize_batch(results) do
    counts =
      Enum.reduce(results, %{"created" => 0, "skipped" => 0, "failed" => 0}, fn r, acc ->
        Map.update(acc, r["status"], 1, &(&1 + 1))
      end)

    Map.merge(counts, %{"total" => length(results), "results" => results})
  end

  # --- Expression builders ---

  defp build_resolve_expression(args) do
    parts = ["RESOLVE #{args["entity"]}"]

    parts =
      if args["scope"],
        do: parts ++ ["FROM #{args["scope"]}"],
        else: parts

    parts =
      if args["freshness"],
        do: parts ++ ["WITH freshness < #{args["freshness"]}"],
        else: parts

    parts =
      if args["reputation"],
        do: parts ++ ["WITH reputation > #{args["reputation"]}"],
        else: parts

    Enum.join(parts, " ")
  end

  defp build_resolve_batch_expression(args) do
    with {:ok, entity_refs} <- parse_resolve_batch_entities(args["entities"]),
         {:ok, scope} <- parse_optional_scope(args["scope"]),
         {:ok, freshness} <- parse_optional_freshness(args["freshness"]),
         {:ok, reputation} <- parse_optional_reputation(args["reputation"]) do
      {:ok,
       %Cqr.ResolveBatch{
         entities: entity_refs,
         scope: scope,
         freshness: freshness,
         reputation: reputation
       }}
    end
  end

  defp parse_resolve_batch_entities(entities) when is_list(entities) do
    Enum.reduce_while(entities, {:ok, []}, fn raw, {:ok, acc} ->
      case parse_resolve_batch_address(raw) do
        {:ok, ref} -> {:cont, {:ok, [ref | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = err -> err
    end
  end

  defp parse_resolve_batch_address(raw) when is_binary(raw) do
    stripped =
      case raw do
        "entity:" <> rest -> rest
        other -> other
      end

    case String.split(stripped, ":") do
      segments when length(segments) >= 2 ->
        {ns_segments, [name]} = Enum.split(segments, -1)
        ns = Enum.join(ns_segments, ":")

        if ns == "" or name == "" do
          {:error,
           %{
             "code" => -32_602,
             "message" => "Invalid entity address: #{inspect(raw)}"
           }}
        else
          {:ok, {ns, name}}
        end

      _ ->
        {:error,
         %{
           "code" => -32_602,
           "message" => "Invalid entity address: #{inspect(raw)}"
         }}
    end
  end

  defp parse_resolve_batch_address(raw) do
    {:error,
     %{
       "code" => -32_602,
       "message" => "Invalid entity address: #{inspect(raw)}"
     }}
  end

  defp parse_optional_scope(nil), do: {:ok, nil}

  defp parse_optional_scope(raw) when is_binary(raw) do
    segments =
      case raw do
        "scope:" <> rest -> String.split(rest, ":")
        other -> String.split(other, ":")
      end

    case Enum.reject(segments, &(&1 == "")) do
      [] ->
        {:error, %{"code" => -32_602, "message" => "Invalid scope: #{inspect(raw)}"}}

      cleaned ->
        {:ok, cleaned}
    end
  end

  defp parse_optional_scope(other),
    do: {:error, %{"code" => -32_602, "message" => "Invalid scope: #{inspect(other)}"}}

  defp parse_optional_freshness(nil), do: {:ok, nil}

  defp parse_optional_freshness(raw) when is_binary(raw) do
    case Regex.run(~r/^(\d+)([smhd])$/, raw) do
      [_, n_str, unit_str] ->
        unit =
          case unit_str do
            "s" -> :s
            "m" -> :m
            "h" -> :h
            "d" -> :d
          end

        {:ok, {String.to_integer(n_str), unit}}

      _ ->
        {:error,
         %{
           "code" => -32_602,
           "message" => "Invalid freshness: #{inspect(raw)} (expected forms like 24h, 7d, 30m)"
         }}
    end
  end

  defp parse_optional_freshness(other),
    do: {:error, %{"code" => -32_602, "message" => "Invalid freshness: #{inspect(other)}"}}

  defp parse_optional_reputation(nil), do: {:ok, nil}
  defp parse_optional_reputation(value) when is_number(value), do: {:ok, value / 1}

  defp parse_optional_reputation(other),
    do: {:error, %{"code" => -32_602, "message" => "Invalid reputation: #{inspect(other)}"}}

  defp build_discover_expression(args) do
    topic = args["topic"]

    topic_part =
      if String.starts_with?(topic, "entity:") do
        topic
      else
        # Strip any quotes the client may have added around the search term so
        # we never end up with doubled quotes like ""finance"".
        unquoted = topic |> String.trim() |> String.trim(~s("))
        ~s("#{unquoted}")
      end

    parts = ["DISCOVER concepts RELATED TO #{topic_part}"]

    parts =
      if args["scope"] do
        scopes =
          args["scope"]
          |> String.split(",")
          |> Enum.map_join(", ", &String.trim/1)

        parts ++ ["WITHIN #{scopes}"]
      else
        parts
      end

    parts =
      if args["depth"],
        do: parts ++ ["DEPTH #{args["depth"]}"],
        else: parts

    parts =
      if args["direction"] in ["outbound", "inbound", "both"],
        do: parts ++ ["DIRECTION #{args["direction"]}"],
        else: parts

    parts =
      case args["max_results"] do
        n when is_integer(n) and n > 0 -> parts ++ ["LIMIT #{n}"]
        _ -> parts
      end

    parts =
      case normalize_near(args["near"]) do
        nil -> parts
        addr -> parts ++ ["NEAR #{addr}"]
      end

    Enum.join(parts, " ")
  end

  # Normalize a user-supplied near argument to the `entity:ns:name` form the
  # parser expects. Accepts either form (with or without the `entity:` prefix)
  # and returns nil for malformed input. Near is purely a ranking hint, so
  # silent degradation is preferred over rejecting the whole tool call.
  defp normalize_near(nil), do: nil
  defp normalize_near(""), do: nil

  defp normalize_near(addr) when is_binary(addr) do
    normalized =
      if String.starts_with?(addr, "entity:"), do: addr, else: "entity:" <> addr

    rest = String.replace_prefix(normalized, "entity:", "")
    segments = String.split(rest, ":")

    if length(segments) >= 2 and Enum.all?(segments, &valid_near_segment?/1) do
      normalized
    else
      nil
    end
  end

  defp normalize_near(_), do: nil

  defp valid_near_segment?(seg),
    do: seg != "" and Regex.match?(~r/^[a-z_][a-z0-9_]*$/, seg)

  defp build_assert_expression(args) do
    with {:ok, entity} <- require_string(args, "entity"),
         {:ok, type} <- require_string(args, "type"),
         {:ok, description} <- require_string(args, "description"),
         {:ok, intent} <- require_string(args, "intent"),
         {:ok, derived_from_raw} <- require_string(args, "derived_from"),
         {:ok, derived_from_refs} <- parse_derived_from(derived_from_raw),
         {:ok, relationships} <- parse_relationships(args["relationships"]) do
      parts = [
        "ASSERT #{entity}",
        "TYPE #{type}",
        "DESCRIPTION \"#{sanitize_quoted(description)}\"",
        "INTENT \"#{sanitize_quoted(intent)}\"",
        "DERIVED_FROM #{Enum.join(derived_from_refs, ", ")}"
      ]

      parts =
        if args["scope"],
          do: parts ++ ["IN #{args["scope"]}"],
          else: parts

      parts =
        case args["confidence"] do
          nil ->
            parts

          score when is_number(score) ->
            parts ++ ["CONFIDENCE #{:erlang.float_to_binary(score * 1.0, decimals: 2)}"]

          _ ->
            parts
        end

      expression = Enum.join(parts, " ")
      {:ok, expression, relationships}
    end
  end

  defp require_string(args, key) do
    case args[key] do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error,
         %{
           "code" => -32_602,
           "message" => "Missing or invalid required field: #{key}"
         }}
    end
  end

  # Strip any surrounding double-quotes the client may have added (same
  # idempotency pattern used by build_discover_expression) and replace
  # internal double-quotes with single quotes, since the CQR grammar's
  # string_literal has no escape support.
  defp sanitize_quoted(value) do
    value
    |> String.trim()
    |> String.trim(~s("))
    |> String.replace(~s("), "'")
  end

  defp parse_derived_from(raw) do
    refs =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      refs == [] ->
        {:error, %{"code" => -32_602, "message" => "derived_from must list at least one entity"}}

      Enum.all?(refs, &String.starts_with?(&1, "entity:")) ->
        {:ok, refs}

      true ->
        bad = Enum.reject(refs, &String.starts_with?(&1, "entity:"))

        {:error,
         %{
           "code" => -32_602,
           "message" =>
             "derived_from entries must be in entity:namespace:name form. Invalid: " <>
               Enum.join(bad, ", ")
         }}
    end
  end

  # Parse the `relationships` shorthand string into a list of
  # `%{type: rel_type, target: {ns, name}, strength: float}` maps.
  # Format: "REL:entity:ns:name:strength,REL:entity:ns:name:strength"
  defp parse_relationships(nil), do: {:ok, []}
  defp parse_relationships(""), do: {:ok, []}

  @valid_relationship_types ~w(CORRELATES_WITH CONTRIBUTES_TO DEPENDS_ON CAUSES PART_OF)

  defp parse_relationships(raw) when is_binary(raw) do
    result =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        case parse_one_relationship(entry) do
          {:ok, rel} -> {:cont, {:ok, [rel | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = err -> err
    end
  end

  defp parse_one_relationship(entry) do
    # Format: REL:entity:seg1:seg2(:segN)*:strength
    # Hierarchical targets are supported: the final segment is the strength,
    # the second segment is the literal "entity", and everything between is
    # the entity path (last path segment is the leaf name; preceding segments
    # form the namespace path joined by ":").
    case String.split(entry, ":") do
      [rel, "entity" | rest] when length(rest) >= 2 ->
        {path_segments, [strength_str]} = Enum.split(rest, -1)
        {ns_segments, [name]} = Enum.split(path_segments, -1)
        ns = Enum.join(ns_segments, ":")

        with true <- rel in @valid_relationship_types,
             {strength, ""} <- Float.parse(strength_str),
             true <- strength >= 0.0 and strength <= 1.0 do
          {:ok, %{type: rel, target: {ns, name}, strength: strength}}
        else
          false ->
            {:error,
             %{
               "code" => -32_602,
               "message" =>
                 "Invalid relationship '#{entry}': type must be one of " <>
                   Enum.join(@valid_relationship_types, ", ") <>
                   " and strength must be between 0.0 and 1.0"
             }}

          _ ->
            {:error,
             %{
               "code" => -32_602,
               "message" => "Invalid relationship '#{entry}': strength must be a decimal"
             }}
        end

      _ ->
        {:error,
         %{
           "code" => -32_602,
           "message" =>
             "Invalid relationship '#{entry}': expected REL:entity:ns:name(:segN)*:strength"
         }}
    end
  end

  defp build_trace_expression(args) do
    parts = ["TRACE #{args["entity"]}"]

    parts =
      case args["time_window"] do
        nil -> parts
        "" -> parts
        window when is_binary(window) -> parts ++ ["OVER last #{window}"]
      end

    parts =
      case args["depth"] do
        nil -> parts
        d when is_integer(d) and d > 0 -> parts ++ ["DEPTH causal:#{d}"]
        _ -> parts
      end

    Enum.join(parts, " ")
  end

  defp build_signal_expression(args) do
    with {:ok, entity} <- require_string(args, "entity"),
         {:ok, evidence} <- require_string(args, "evidence"),
         {:ok, score} <- require_score(args) do
      parts = [
        "SIGNAL reputation",
        "ON #{entity}",
        "SCORE #{:erlang.float_to_binary(score * 1.0, decimals: 2)}",
        ~s(EVIDENCE "#{sanitize_quoted(evidence)}")
      ]

      {:ok, Enum.join(parts, " ")}
    end
  end

  defp require_score(args), do: require_score(args, "score")

  defp require_score(args, key) do
    case args[key] do
      score when is_number(score) and score >= 0.0 and score <= 1.0 ->
        {:ok, score * 1.0}

      _ ->
        {:error, %{"code" => -32_602, "message" => "#{key} must be a number in [0.0, 1.0]"}}
    end
  end

  defp build_refresh_expression(args) do
    threshold = args["threshold"] || "24h"

    parts = ["REFRESH CHECK active_context"]

    parts =
      case args["scope"] do
        scope when is_binary(scope) and scope != "" -> parts ++ ["WITHIN #{scope}"]
        _ -> parts
      end

    parts = parts ++ ["WHERE age > #{threshold}", "RETURN stale_items"]

    Enum.join(parts, " ")
  end

  defp build_awareness_expression(args) do
    ["AWARENESS active_agents"]
    |> append_awareness_scope(args["scope"])
    |> append_awareness_window(args["time_window"])
    |> append_awareness_limit(args["limit"])
    |> Enum.join(" ")
  end

  defp append_awareness_scope(parts, scope) when is_binary(scope) and scope != "",
    do: parts ++ ["WITHIN #{scope}"]

  defp append_awareness_scope(parts, _), do: parts

  defp append_awareness_window(parts, window) when is_binary(window) and window != "",
    do: parts ++ ["OVER last #{window}"]

  defp append_awareness_window(parts, _), do: parts

  defp append_awareness_limit(parts, n) when is_integer(n) and n > 0,
    do: parts ++ ["LIMIT #{n}"]

  defp append_awareness_limit(parts, _), do: parts

  defp build_hypothesize_expression(args) do
    with {:ok, entity} <- require_string(args, "entity"),
         {:ok, reputation} <- require_score(args, "reputation") do
      parts = [
        "HYPOTHESIZE #{entity}",
        "CHANGE reputation TO #{:erlang.float_to_binary(reputation, decimals: 2)}"
      ]

      parts =
        case args["depth"] do
          d when is_integer(d) and d > 0 -> parts ++ ["DEPTH #{d}"]
          _ -> parts
        end

      parts =
        case args["decay"] do
          d when is_number(d) and d >= 0.0 and d <= 1.0 ->
            parts ++ ["DECAY #{:erlang.float_to_binary(d * 1.0, decimals: 2)}"]

          _ ->
            parts
        end

      {:ok, Enum.join(parts, " ")}
    end
  end

  defp build_compare_expression(args) do
    with {:ok, entities_raw} <- require_string(args, "entities"),
         {:ok, entity_refs} <- parse_entity_list(entities_raw),
         {:ok, include_clause} <- parse_include(args["include"]) do
      parts = ["COMPARE #{Enum.join(entity_refs, ", ")}"]
      parts = if include_clause, do: parts ++ [include_clause], else: parts
      {:ok, Enum.join(parts, " ")}
    end
  end

  defp parse_entity_list(raw) do
    refs =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      length(refs) < 2 ->
        {:error, %{"code" => -32_602, "message" => "entities must list at least two references"}}

      Enum.all?(refs, &String.starts_with?(&1, "entity:")) ->
        {:ok, refs}

      true ->
        bad = Enum.reject(refs, &String.starts_with?(&1, "entity:"))

        {:error,
         %{
           "code" => -32_602,
           "message" =>
             "entities entries must be in entity:namespace:name form. Invalid: " <>
               Enum.join(bad, ", ")
         }}
    end
  end

  @valid_compare_facets ~w(relationships properties quality)

  defp parse_include(nil), do: {:ok, nil}
  defp parse_include(""), do: {:ok, nil}

  defp parse_include(raw) when is_binary(raw) do
    facets =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Enum.reject(facets, &(&1 in @valid_compare_facets)) do
      [] when facets != [] ->
        {:ok, "INCLUDE " <> Enum.join(facets, ", ")}

      [] ->
        {:ok, nil}

      bad ->
        {:error,
         %{
           "code" => -32_602,
           "message" =>
             "include must list facets from " <>
               Enum.join(@valid_compare_facets, ", ") <>
               ". Invalid: " <> Enum.join(bad, ", ")
         }}
    end
  end

  defp build_anchor_expression(args) do
    with {:ok, raw} <- require_string(args, "entities"),
         {:ok, refs} <- parse_anchor_entities(raw) do
      parts = ["ANCHOR #{Enum.join(refs, ", ")}"]

      parts =
        case args["rationale"] do
          rationale when is_binary(rationale) and rationale != "" ->
            parts ++ [~s(FOR "#{sanitize_quoted(rationale)}")]

          _ ->
            parts
        end

      parts =
        case args["freshness"] do
          window when is_binary(window) and window != "" ->
            parts ++ ["WITH freshness < #{window}"]

          _ ->
            parts
        end

      parts =
        case args["reputation"] do
          score when is_number(score) ->
            parts ++
              ["WITH reputation > #{:erlang.float_to_binary(score * 1.0, decimals: 2)}"]

          _ ->
            parts
        end

      {:ok, Enum.join(parts, " ")}
    end
  end

  defp parse_anchor_entities(raw) do
    refs =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      refs == [] ->
        {:error, %{"code" => -32_602, "message" => "entities must list at least one entity"}}

      Enum.all?(refs, &String.starts_with?(&1, "entity:")) ->
        {:ok, refs}

      true ->
        bad = Enum.reject(refs, &String.starts_with?(&1, "entity:"))

        {:error,
         %{
           "code" => -32_602,
           "message" =>
             "entities must be in entity:namespace:name form. Invalid: " <>
               Enum.join(bad, ", ")
         }}
    end
  end

  defp build_certify_expression(args) do
    parts = ["CERTIFY #{args["entity"]} STATUS #{args["status"]}"]

    parts =
      if args["authority"],
        do: parts ++ ["AUTHORITY #{quote_opaque(args["authority"])}"],
        else: parts

    parts =
      if args["evidence"],
        do: parts ++ ["EVIDENCE #{quote_opaque(args["evidence"])}"],
        else: parts

    Enum.join(parts, " ")
  end

  defp build_update_expression(args) do
    with {:ok, entity} <- require_string(args, "entity"),
         {:ok, change_type} <- require_string(args, "change_type") do
      clauses =
        [
          "UPDATE #{entity}",
          "CHANGE_TYPE #{change_type}",
          optional_string_clause("DESCRIPTION", args["description"], quoted: true),
          optional_string_clause("TYPE", args["type"], quoted: false),
          optional_string_clause("EVIDENCE", args["evidence"], quoted: true),
          optional_confidence_clause(args["confidence"])
        ]
        |> Enum.reject(&is_nil/1)

      {:ok, Enum.join(clauses, " ")}
    end
  end

  defp optional_string_clause(_keyword, nil, _opts), do: nil
  defp optional_string_clause(_keyword, "", _opts), do: nil

  defp optional_string_clause(keyword, value, quoted: true) when is_binary(value),
    do: ~s(#{keyword} "#{sanitize_quoted(value)}")

  defp optional_string_clause(keyword, value, quoted: false) when is_binary(value),
    do: "#{keyword} #{value}"

  defp optional_string_clause(_keyword, _value, _opts), do: nil

  defp optional_confidence_clause(score) when is_number(score),
    do: "CONFIDENCE #{:erlang.float_to_binary(score * 1.0, decimals: 2)}"

  defp optional_confidence_clause(_), do: nil

  # Quote a free-form value as a CQR string literal. Strips any surrounding
  # quotes the client may have added (idempotent under double-quoting), and
  # replaces internal `"` with `'` since the grammar's string_literal does
  # not support escape sequences.
  defp quote_opaque(value) when is_binary(value) do
    cleaned =
      value
      |> String.trim()
      |> String.trim(~s("))
      |> String.replace(~s("), "'")

    ~s("#{cleaned}")
  end

  # --- Result formatting ---

  defp execute_and_format(expression, context) do
    case Cqr.Engine.execute(expression, context) do
      {:ok, result} ->
        {:ok, format_result(result)}

      {:error, %Cqr.Error{} = error} ->
        {:error,
         %{
           "code" => error_code_to_int(error.code),
           "message" => error.message,
           "data" => %{
             "suggestions" => error.suggestions,
             "similar_entities" => error.similar_entities,
             "retry_guidance" => error.retry_guidance
           }
         }}
    end
  end

  defp format_result(%Cqr.Result{} = result) do
    %{
      "data" => Enum.map(result.data, &format_data_item/1),
      "quality" => %{
        "freshness" => format_value(result.quality.freshness),
        "confidence" => format_value(result.quality.confidence),
        "reputation" => format_value(result.quality.reputation),
        "owner" => format_value(result.quality.owner),
        "provenance" => format_value(result.quality.provenance),
        "lineage" => result.quality.lineage,
        "certified_by" => result.quality.certified_by,
        "certified_at" => format_value(result.quality.certified_at)
      },
      "cost" => %{
        "adapters_queried" => result.cost.adapters_queried,
        "operations" => result.cost.operations,
        "execution_ms" => result.cost.execution_ms
      },
      "sources" => result.sources,
      "conflicts" => Enum.map(result.conflicts, &format_data_item/1)
    }
  end

  defp format_data_item(item) when is_map(item) do
    Map.new(item, fn {k, v} -> {to_string(k), format_value(v)} end)
  end

  defp format_data_item(other), do: other

  defp format_value(:unknown), do: nil
  defp format_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  # Nested Cqr.Result (e.g. per-row payload of cqr_resolve_batch). Recursively
  # flatten through format_result so the outer envelope is wire-encodable.
  defp format_value(%Cqr.Result{} = r), do: format_result(r)
  defp format_value({a, b}) when is_binary(a) and is_binary(b), do: "#{a}:#{b}"
  defp format_value(list) when is_list(list), do: Enum.map(list, &format_value/1)
  # Recursively normalize nested maps (e.g. conflicts.conflicting_values carry
  # inner rows whose `entity` field is still a `{ns, name}` tuple). Without
  # this clause Jason.encode! in the handler raises Protocol.UndefinedError
  # on the tuple and the response never makes it back to the client, which
  # looks like a stdio hang to the caller.
  defp format_value(%{} = map) when not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), format_value(v)} end)
  end

  defp format_value(atom) when is_atom(atom) and atom != nil, do: to_string(atom)
  defp format_value(v), do: v

  defp error_code_to_int(:parse_error), do: -32_700
  defp error_code_to_int(:entity_not_found), do: -32_001
  defp error_code_to_int(:scope_access), do: -32_002
  defp error_code_to_int(:invalid_transition), do: -32_003
  defp error_code_to_int(:no_adapter), do: -32_004
  defp error_code_to_int(_), do: -32_000
end
