defmodule Cqr.Grafeo.Native do
  @moduledoc """
  Rustler NIF module — Elixir interface to the embedded Grafeo database.

  This is the lowest-level interface to Grafeo. Application code should use
  `Cqr.Grafeo.Server` instead, which provides serialized access and
  lifecycle management.

  ## NIF Functions

    * `new/1` — open/create a Grafeo database (`:memory` or file path)
    * `execute/2` — execute a GQL/Cypher query, returns JSON string
    * `checkpoint/1` — flush WAL + snapshot to disk without closing
    * `close/1` — close the database handle
    * `health_check/1` — report operational status and version

  ## Precompiled binaries

  By default this module is backed by precompiled NIF binaries downloaded
  from the project's GitHub releases, so end users do not need a Rust
  toolchain. Contributors modifying the Rust crate can force a source
  build by setting `CQR_BUILD_NIF=true` before `mix deps.get` / `mix compile`.
  """

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :cqr_mcp,
    crate: "cqr_grafeo",
    base_url: "https://github.com/teipsum/cqr-mcp/releases/download/v#{version}",
    force_build: System.get_env("CQR_BUILD_NIF") in ["1", "true"],
    version: version,
    nif_versions: ["2.16"],
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-gnu
    )

  @doc "Open an in-memory (`:memory`) or persistent (path string) Grafeo database."
  def new(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Execute a GQL/Cypher query. Returns `{:ok, json_string}` or `{:error, reason}`."
  def execute(_db, _query), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Flush WAL and snapshot to disk without closing the database.

  For persistent SingleFile storage, this writes the current state to the
  `.grafeo` file so a hard kill does not discard in-memory writes since
  the last checkpoint. No-op for in-memory databases.
  """
  def checkpoint(_db), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Close the database handle."
  def close(_db), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Health check. Returns `{:ok, version_string}` or raises."
  def health_check(_db), do: :erlang.nif_error(:nif_not_loaded)
end
