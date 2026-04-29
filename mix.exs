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
      # Semantic embeddings: Bumblebee runs the model in-BEAM, EXLA JIT-compiles
      # the graph to the local accelerator (Metal on Apple Silicon, CPU
      # otherwise). Nx is the underlying tensor library. Pinned to current
      # 0.6 / 0.10 / 0.10 line per the Bumblebee README; bumping these
      # together is the safe path because the three move in lockstep.
      #
      # Apple Silicon + Xcode CLT 26+ build note: XLA 0.9.1's bundled headers
      # specialize std::is_signed, which Apple clang 21 makes a hard error
      # via the new no_specializations attribute. On a fresh install run
      #   CFLAGS="-Wno-error=invalid-specialization" mix deps.compile exla
      # once. The compiled libexla.so is then cached at
      # ~/Library/Caches/xla/exla/... so subsequent rebuilds skip the C++
      # compile entirely.
      {:bumblebee, "~> 0.6.0"},
      {:nx, "~> 0.10"},
      {:exla, "~> 0.10"},
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
