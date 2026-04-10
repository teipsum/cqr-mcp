defmodule CqrMcp do
  @moduledoc """
  CQR MCP Server — Governed context resolution for AI agents.

  An Elixir/OTP application that embeds Grafeo (graph database) via
  Rustler NIF and exposes CQR primitives as MCP tools. Zero external
  dependencies. Single OS process.

  ## Entry Points

    * `Cqr.Engine.execute/2` — the governance invariance boundary
    * `Cqr.Grafeo.Server.query/1` — direct Grafeo queries
    * MCP tools: `cqr_resolve`, `cqr_discover`, `cqr_certify`
  """
end
