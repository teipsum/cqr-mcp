defmodule CqrMcp.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/teipsum/cqr-mcp"

  def project do
    [
      app: :cqr_mcp,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "CQR MCP",
      source_url: @source_url
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
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Static analysis
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Governed context resolution for AI agents — CQR protocol as an MCP server."
  end

  defp package do
    [
      name: "cqr_mcp",
      licenses: ["BUSL-1.1"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib native/cqr_grafeo/src native/cqr_grafeo/Cargo.toml
           mix.exs README.md LICENSE CONTRIBUTING.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CONTRIBUTING.md",
        "LICENSE",
        "docs/architecture.md",
        "docs/cqr-primer.md",
        "docs/cqr-protocol-specification.md",
        "docs/mcp-integration.md"
      ]
    ]
  end
end
