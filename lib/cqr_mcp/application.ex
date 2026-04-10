defmodule CqrMcp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    register_session()

    children = [
      {Cqr.Grafeo.Server, storage: :memory},
      Cqr.Repo.ScopeTree,
      CqrMcp.Server
    ]

    opts = [strategy: :one_for_one, name: CqrMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

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
