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
      # NIF bridge — Rust-to-Elixir.
      # `rustler_precompiled` downloads prebuilt NIF binaries from GitHub
      # releases so end users do not need a Rust toolchain. `rustler` is
      # kept as an optional dep so contributors can rebuild from source
      # with `CQR_BUILD_NIF=true mix compile`.
      {:rustler_precompiled, "~> 0.8"},
      {:rustler, "~> 0.34", optional: true},
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
