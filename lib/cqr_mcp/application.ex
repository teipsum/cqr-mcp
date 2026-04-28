defmodule CqrMcp.Application do
  @moduledoc """
  OTP application entry point for the CQR MCP server.

  Boots the supervision tree under a `:one_for_one` strategy and registers a
  session identity in `:persistent_term` so `cqr://session` can serve it
  without a process hop.

  ## Modes

    * **Standalone** (default) -- CQR owns the Grafeo database and hosts its
      own MCP SSE transport. This is the normal mode when running `cqr_mcp`
      as a standalone OS process.

    * **Embedded** (`config :cqr_mcp, :embedded, true`) -- the host
      host application owns the Grafeo database and MCP transport.
      CQR starts only library infrastructure (scope-tree cache, MCP tool
      server, SSE registry) and exposes `Cqr.Engine.execute/2` as a pure
      library call.
  """

  use Application

  @impl true
  def start(_type, _args) do
    register_session()

    children =
      if embedded_mode?() do
        library_children()
      else
        standalone_children()
      end

    opts = [strategy: :one_for_one, name: CqrMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  def children_for_mode(:embedded), do: library_children()
  def children_for_mode(:standalone), do: standalone_children()

  defp standalone_children do
    {storage, seed, reset} = parse_storage_args(System.argv())

    [
      {Cqr.Grafeo.Server, storage: storage, seed: seed, reset: reset}
      | library_children()
    ]
  end

  defp library_children do
    [
      Cqr.Repo.ScopeTree,
      CqrMcp.Server,
      {Registry, keys: :duplicate, name: CqrMcp.SSE.Registry},
      {Bandit, plug: CqrMcp.SSE.Router, port: sse_port()}
    ]
  end

  defp embedded_mode? do
    Application.get_env(:cqr_mcp, :embedded, false)
  end

  # Port for the MCP SSE/HTTP transport. Resolution order:
  # 1. `CQR_MCP_PORT` environment variable
  # 2. `config :cqr_mcp, :sse_port`
  # 3. Default 4000
  defp sse_port do
    case System.get_env("CQR_MCP_PORT") do
      nil -> Application.get_env(:cqr_mcp, :sse_port, 4000)
      str -> String.to_integer(str)
    end
  end

  # Parse --persist and --reset from the command line.
  #
  # In-memory (default): always seeds, never resets.
  # Persistent (--persist [path]): does not seed unless --reset is passed.
  # Persistent + --reset: deletes DB file, opens fresh, seeds sample data.
  defp parse_storage_args(argv) do
    # Allow override via Application.get_env for embedding in umbrella apps
    case Application.get_env(:cqr_mcp, :grafeo_path) do
      path when is_binary(path) ->
        reset = "--reset" in argv
        {{:path, path}, Application.get_env(:cqr_mcp, :grafeo_seed, true), reset}

      _ ->
        parse_argv_storage(argv)
    end
  end

  defp parse_argv_storage(argv) do
    if "--persist" in argv do
      path = persist_path(argv)
      reset = "--reset" in argv
      {{:path, path}, reset, reset}
    else
      {:memory, true, false}
    end
  end

  defp persist_path(argv) do
    candidate =
      argv
      |> Enum.drop_while(&(&1 != "--persist"))
      |> Enum.drop(1)
      |> Enum.at(0)

    if is_binary(candidate) and not String.starts_with?(candidate, "--") do
      candidate
    else
      default_db_path()
    end
  end

  # Grafeo auto-detects single-file vs WAL-directory storage from the
  # file extension. `.grafeo` triggers SingleFile; anything else (e.g.
  # `.db`) silently falls through to WAL-directory mode and operates
  # in-memory without writing to disk. Keep the extension load-bearing.
  defp default_db_path, do: Path.expand("~/.cqr/grafeo.grafeo")

  # Generate a session id and capture the boot timestamps once at startup,
  # stash them in :persistent_term so the cqr://session resource can read
  # them with no GenServer hop.
  defp register_session do
    now_unix = System.system_time(:second)
    now_dt = DateTime.from_unix!(now_unix)

    :persistent_term.put({__MODULE__, :session_id}, generate_session_id())
    :persistent_term.put({__MODULE__, :boot_unix}, now_unix)
    :persistent_term.put({__MODULE__, :boot_iso}, DateTime.to_iso8601(now_dt))
  end

  # RFC 4122 UUIDv4: 16 random bytes with version (4) and variant (10) bits set.
  defp generate_session_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
