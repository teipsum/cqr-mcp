defmodule CqrMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :cqr_mcp,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {CqrMcp.Application, []}
    ]
  end

  defp deps do
    [
      # NIF bridge — Rust-to-Elixir
      {:rustler, "~> 0.34"},
      # Parser combinators
      {:nimble_parsec, "~> 1.4"},
      # JSON encoding/decoding
      {:jason, "~> 1.4"},
      # HTTP server for MCP SSE transport
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.6"},
      # Documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
