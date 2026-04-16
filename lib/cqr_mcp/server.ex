defmodule CqrMcp.Server do
  @moduledoc """
  MCP server over stdio transport.

  Reads newline-delimited JSON-RPC 2.0 messages from stdin,
  routes them through `CqrMcp.Handler`, and writes responses to stdout.

  This is the primary transport for Claude Desktop, Claude Code, and Cursor.

  ## Usage

  Start as part of the application (for `mix run --no-halt`):

      # In application.ex children:
      CqrMcp.Server

  Or start standalone:

      CqrMcp.Server.start_link([])
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Start reading from stdin in a separate process
    pid = self()
    spawn_link(fn -> read_loop(pid) end)
    Logger.info("MCP server started on stdio transport")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:mcp_message, line}, state) do
    spawn(fn -> process_message(line) end)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp process_message(line) do
    case Jason.decode(line) do
      {:ok, request} -> dispatch_request(request)
      {:error, _} -> write_response(parse_error())
    end
  end

  defp dispatch_request(request) do
    case CqrMcp.Handler.handle_request(request) do
      nil -> :ok
      response -> write_response(response)
    end
  end

  defp parse_error do
    %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32_700, "message" => "Parse error"}
    }
  end

  # --- Stdio I/O ---

  defp read_loop(server_pid) do
    case IO.read(:stdio, :line) do
      :eof ->
        Logger.info("MCP stdio: EOF received, shutting down")

      {:error, reason} ->
        Logger.error("MCP stdio read error: #{inspect(reason)}")

      line when is_binary(line) ->
        line = String.trim(line)

        if line != "" do
          send(server_pid, {:mcp_message, line})
        end

        read_loop(server_pid)
    end
  end

  defp write_response(response) do
    json = Jason.encode!(response, escape: :unicode_safe)
    IO.write(:stdio, json <> "\n")
  end
end
