defmodule CqrMcp.Application do
  @moduledoc """
  OTP application entry point for the CQR MCP server.

  Boots the supervision tree (embedded Grafeo NIF server, scope tree cache,
  MCP transport server) under a `:one_for_one` strategy and registers a
  session identity in `:persistent_term` so `cqr://session` can serve it
  without a process hop.
  """

  use Application

  @impl true
  def start(_type, _args) do
    register_session()

    {storage, seed, reset} = parse_storage_args(System.argv())

    children = [
      {Cqr.Grafeo.Server, storage: storage, seed: seed, reset: reset},
      Cqr.Repo.ScopeTree,
      CqrMcp.Server
    ]

    opts = [strategy: :one_for_one, name: CqrMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Parse --persist and --reset from the command line.
  #
  # In-memory (default): always seeds, never resets.
  # Persistent (--persist [path]): does not seed unless --reset is passed.
  # Persistent + --reset: deletes DB file, opens fresh, seeds sample data.
  defp parse_storage_args(argv) do
    if "--persist" in argv do
      path =
        argv
        |> Enum.drop_while(&(&1 != "--persist"))
        |> Enum.drop(1)
        |> Enum.at(0)

      path =
        if is_binary(path) and not String.starts_with?(path, "--") do
          path
        else
          default_db_path()
        end

      reset = "--reset" in argv
      {{:path, path}, reset, reset}
    else
      {:memory, true, false}
    end
  end

  defp default_db_path, do: Path.expand("~/.cqr/grafeo.db")

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
