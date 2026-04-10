defmodule Cqr.Grafeo.Native do
  @moduledoc """
  Rustler NIF module — Elixir interface to the embedded Grafeo database.

  This is the lowest-level interface to Grafeo. Application code should use
  `Cqr.Grafeo.Server` instead, which provides serialized access and
  lifecycle management.

  ## NIF Functions

    * `new/1` — open/create a Grafeo database (`:memory` or file path)
    * `execute/2` — execute a GQL/Cypher query, returns JSON string
    * `close/1` — close the database handle
    * `health_check/1` — report operational status and version
  """

  use Rustler,
    otp_app: :cqr_mcp,
    crate: "cqr_grafeo"

  @doc "Open an in-memory (`:memory`) or persistent (path string) Grafeo database."
  def new(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Execute a GQL/Cypher query. Returns `{:ok, json_string}` or `{:error, reason}`."
  def execute(_db, _query), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Close the database handle."
  def close(_db), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Health check. Returns `{:ok, version_string}` or raises."
  def health_check(_db), do: :erlang.nif_error(:nif_not_loaded)
end
