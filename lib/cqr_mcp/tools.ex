defmodule CqrMcp.Tools do
  @moduledoc """
  MCP tool definitions: cqr_resolve, cqr_discover, cqr_certify.

  Each tool definition includes name, description, and JSON Schema for inputs.
  Tool execution delegates to `Cqr.Engine.execute/2`.
  """

  @doc "Return the list of available MCP tools."
  def list do
    [
      resolve_tool(),
      discover_tool(),
      certify_tool(),
      assert_tool(),
      assert_batch_tool(),
      trace_tool(),
      signal_tool(),
      refresh_tool(),
      hypothesize_tool()
    ]
  end

  @doc "Execute a tool call by name with the given arguments and agent context."
  def call("cqr_resolve", args, context) do
    expression = build_resolve_expression(args)
    execute_and_format(expression, context)
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

  def call("cqr_hypothesize", args, context) do
    case build_hypothesize_expression(args) do
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
              "Entity reference in format entity:namespace:name (e.g., entity:finance:arr)"
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
              "Entity reference (entity:namespace:name) or a free-text search term. " <>
                "Pass the search term as a plain string without quotes; the server will quote it."
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
            "description" => "Semantic address for the new context: entity:namespace:name"
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
              "Comma-separated source entity references (entity:ns:name,entity:ns:name). " <>
                "The cognitive lineage this assertion was derived from. Mandatory."
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
                "Each relationship uses the shorthand REL:entity:ns:name:strength, e.g. " <>
                "'CORRELATES_WITH:entity:product:nps:0.7,DEPENDS_ON:entity:finance:arr:0.5'. " <>
                "Valid relationship types: CORRELATES_WITH, CONTRIBUTES_TO, DEPENDS_ON, " <>
                "CAUSES, PART_OF."
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
            "description" => "Entity to trace (entity:namespace:name)"
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
            "description" => "Entity to signal (entity:namespace:name)"
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
            "description" => "Entity being hypothesized about (entity:namespace:name)"
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
            "description" => "Entity to certify (entity:namespace:name)"
          },
          "status" => %{
            "type" => "string",
            "enum" => ["proposed", "under_review", "certified", "superseded"],
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

    Enum.join(parts, " ")
  end

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
    case String.split(entry, ":") do
      [rel, "entity", ns, name, strength_str] ->
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
           "message" => "Invalid relationship '#{entry}': expected REL:entity:ns:name:strength"
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
