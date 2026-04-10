defmodule CqrMcp.Tools do
  @moduledoc """
  MCP tool definitions: cqr_resolve, cqr_discover, cqr_certify.

  Each tool definition includes name, description, and JSON Schema for inputs.
  Tool execution delegates to `Cqr.Engine.execute/2`.
  """

  @doc "Return the list of available MCP tools."
  def list do
    [resolve_tool(), discover_tool(), certify_tool()]
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

  def call(name, _args, _context) do
    {:error, %{"code" => -32601, "message" => "Unknown tool: #{name}"}}
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
          |> Enum.map(&String.trim/1)
          |> Enum.join(", ")

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
  defp format_value(atom) when is_atom(atom) and atom != nil, do: to_string(atom)
  defp format_value(v), do: v

  defp error_code_to_int(:parse_error), do: -32700
  defp error_code_to_int(:entity_not_found), do: -32001
  defp error_code_to_int(:scope_access), do: -32002
  defp error_code_to_int(:invalid_transition), do: -32003
  defp error_code_to_int(:no_adapter), do: -32004
  defp error_code_to_int(_), do: -32000
end
