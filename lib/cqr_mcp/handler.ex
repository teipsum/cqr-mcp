defmodule CqrMcp.Handler do
  @moduledoc """
  MCP JSON-RPC 2.0 request handler.

  Routes MCP protocol messages to the appropriate handler and formats
  JSON-RPC responses. Implements the MCP lifecycle:
  initialize → initialized → tool/resource calls.
  """

  @mcp_version "2024-11-05"
  @server_name "cqr_mcp"
  @server_version "0.1.0"

  @doc """
  Handle a parsed JSON-RPC request map. Returns a response map or nil for notifications.
  """
  def handle_request(%{"method" => method} = request) do
    id = request["id"]
    params = request["params"] || %{}

    case handle_method(method, params) do
      {:result, result} when id != nil ->
        %{"jsonrpc" => "2.0", "id" => id, "result" => result}

      {:error, error} when id != nil ->
        %{"jsonrpc" => "2.0", "id" => id, "error" => error}

      _ when id == nil ->
        # Notifications don't get responses
        nil
    end
  end

  def handle_request(_), do: nil

  # --- MCP lifecycle ---

  defp handle_method("initialize", _params) do
    {:result,
     %{
       "protocolVersion" => @mcp_version,
       "capabilities" => %{
         "tools" => %{"listChanged" => false},
         "resources" => %{"subscribe" => false, "listChanged" => false}
       },
       "serverInfo" => %{
         "name" => @server_name,
         "version" => @server_version
       }
     }}
  end

  defp handle_method("notifications/initialized", _params), do: :notification

  # --- Tools ---

  defp handle_method("tools/list", _params) do
    {:result, %{"tools" => CqrMcp.Tools.list()}}
  end

  defp handle_method("tools/call", %{"name" => name, "arguments" => args}) do
    context = agent_context()

    case CqrMcp.Tools.call(name, args, context) do
      {:ok, result} ->
        {:result,
         %{
           "content" => [
             %{
               "type" => "text",
               "text" => Jason.encode!(result, pretty: true)
             }
           ]
         }}

      {:error, error} ->
        {:result,
         %{
           "content" => [
             %{
               "type" => "text",
               "text" => Jason.encode!(error, pretty: true)
             }
           ],
           "isError" => true
         }}
    end
  end

  defp handle_method("tools/call", _params) do
    {:error, %{"code" => -32602, "message" => "Missing required params: name, arguments"}}
  end

  # --- Resources ---

  defp handle_method("resources/list", _params) do
    {:result, %{"resources" => CqrMcp.Resources.list()}}
  end

  defp handle_method("resources/read", %{"uri" => uri}) do
    case CqrMcp.Resources.read(uri) do
      {:ok, content} ->
        {:result,
         %{
           "contents" => [
             %{
               "uri" => uri,
               "mimeType" => "application/json",
               "text" => Jason.encode!(content, pretty: true)
             }
           ]
         }}

      {:error, reason} ->
        {:error, %{"code" => -32002, "message" => "Resource not found: #{reason}"}}
    end
  end

  defp handle_method("resources/read", _params) do
    {:error, %{"code" => -32602, "message" => "Missing required param: uri"}}
  end

  # --- Ping ---

  defp handle_method("ping", _params), do: {:result, %{}}

  # --- Unknown ---

  defp handle_method(method, _params) do
    {:error, %{"code" => -32601, "message" => "Method not found: #{method}"}}
  end

  # --- Agent context ---

  defp agent_context do
    scope =
      case System.get_env("CQR_AGENT_SCOPE") do
        nil ->
          ["company"]

        scope_str ->
          scope_str
          |> String.trim_leading("scope:")
          |> String.split(":")
      end

    %{scope: scope, agent_id: System.get_env("CQR_AGENT_ID", "anonymous")}
  end
end
