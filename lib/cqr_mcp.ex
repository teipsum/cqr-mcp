defmodule CqrMcp do
  @moduledoc """
  CQR MCP Server -- Governed context resolution for AI agents.

  An Elixir/OTP application that embeds Grafeo (graph database) via
  Rustler NIF and exposes CQR primitives as MCP tools. Zero external
  dependencies. Single OS process.

  ## Entry Points

    * `Cqr.Engine.execute/2` -- the governance invariance boundary
    * `Cqr.Grafeo.Server.query/1` -- direct Grafeo queries
    * MCP tools: `cqr_resolve`, `cqr_discover`, `cqr_certify`

  ## Embedded Mode

  When a host application depends on `cqr_mcp` as a library,
  it can enable embedded mode so CQR does not start its own Grafeo server
  (avoiding database-lock conflicts):

      config :cqr_mcp, :embedded, true

  In embedded mode the host is responsible for starting `Cqr.Grafeo.Server`
  in its own supervision tree. All other CQR library infrastructure starts
  normally and `Cqr.Engine.execute/2` works as usual.
  """
end
