# Contributing

Thank you for your interest in CQR MCP Server. This document describes how to set up a development environment, run the tests, add a new adapter, and submit changes.

## Development Environment

### Prerequisites

- **Elixir** 1.17 or later (this project targets 1.19)
- **Erlang/OTP** 27 or later
- **Rust** toolchain (stable) — only required if you are modifying the Grafeo NIF itself or if your platform has no published precompiled binary

Precompiled NIF binaries are published for common platforms
(`aarch64-apple-darwin`, `x86_64-apple-darwin`, `x86_64-unknown-linux-gnu`,
`aarch64-unknown-linux-gnu`). On supported platforms, `mix deps.get`
downloads the matching binary from the project's GitHub release and no
Rust toolchain is needed.

### Setup

```bash
git clone https://github.com/teipsum/cqr-mcp.git
cd cqr-mcp
mix deps.get
mix compile
```

### Building the NIF from source

If you are editing the Rust crate in `native/cqr_grafeo/`, or if you are on
a platform without a published precompiled binary, force a local source
build by setting `CQR_BUILD_NIF`:

```bash
CQR_BUILD_NIF=true mix deps.get
CQR_BUILD_NIF=true mix compile
CQR_BUILD_NIF=true mix test
```

This makes `rustler_precompiled` delegate to `rustler`, which invokes
`cargo` under `native/cqr_grafeo/`.

### Running the server

```bash
mix run --no-halt
```

The server starts, seeds the sample dataset on first boot (idempotent), and listens on stdio for MCP connections. See [`docs/mcp-integration.md`](docs/mcp-integration.md) for connecting a client.

## Running Tests

The test suite runs in-process against embedded Grafeo. No Docker, no external database, no fixtures to spin up.

```bash
mix test --trace
```

`--trace` surfaces individual test names and is the recommended mode during development. The full suite (561 tests as of the UPDATE primitive shipping) should run in under ten seconds on a modern laptop.

Every capability must ship with tests AND documentation. If it is not tested and documented, it does not exist.

## Code Style

- Run `mix format` before committing. CI enforces formatting.
- Run `mix credo --strict` and resolve warnings.
- Do not commit deferred tests (`@tag :skip`) without an explanation in the test body and an issue link.
- Prefer adding to existing modules over creating new ones when the scope is small.
- Match the surrounding file's style — `|>` pipe chains for sequential transforms, `with` for short-circuiting, explicit tagged tuples for adapter contracts.

## Adding a New Adapter

CQR's adapter contract is deliberately small so that new storage backends (PostgreSQL/pgvector, Neo4j, Elasticsearch, Snowflake, internal warehouses) can be added without modifying engine code.

1. Create a new module under `lib/adapter/` that implements `Cqr.Adapter.Behaviour`. The contract is documented in [`docs/architecture.md`](docs/architecture.md#4-adapter-behaviour-contract).
2. Implement `capabilities/0` to declare which primitives the adapter supports. The engine's planner uses this to route expressions correctly.
3. Add adapter-level tests under `test/adapter/` exercising `resolve/3`, `discover/3`, and any optional callbacks your adapter implements.
4. Add an integration test under `test/integration/` that runs the adapter through `Cqr.Engine.execute/2` to validate the full pipeline.
5. Register the adapter in application config. No engine changes should be required.

If your adapter needs a real external service for testing, gate those tests behind a tag (`@moduletag :external`) and document the setup requirements in the test file header. The default `mix test` run must not depend on external services.

## Commit Conventions

- Commits must be **GPG-signed** (`git commit -S`). This is patent evidence as well as standard open-source hygiene.
- Commit messages follow the Conventional Commits pattern: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`.
- Keep commits focused. One logical change per commit. If a refactor enables a feature, land the refactor first, then the feature.

## Pull Requests

- Target the `main` branch unless instructed otherwise.
- Include a summary of the change, the motivation, and any follow-up work that is deliberately out of scope.
- If your change touches the CQR grammar or primitive semantics, update [`docs/cqr-protocol-specification.md`](docs/cqr-protocol-specification.md) in the same PR.
- If your change touches the adapter contract, update [`docs/architecture.md`](docs/architecture.md) in the same PR.
- CI must pass before review. Formatting, Credo, and the full test suite run on every PR.

## License and Contributor License Agreement

CQR MCP Server is licensed under the **Business Source License 1.1** with an automatic conversion to **MIT License** on April 8, 2030. See [`LICENSE`](LICENSE) for full terms.

By submitting a contribution, you agree that your contribution is licensed under the same terms. For substantive contributions, a Contributor License Agreement (CLA) may be requested; contact `licensing@teipsum.com` if you are unsure whether a CLA is required for your contribution.

## Getting Help

- Open an issue for bugs, feature requests, or design discussions.
- For security-sensitive reports, email `security@teipsum.com` rather than filing a public issue.
- For commercial licensing inquiries or alternative licensing arrangements, contact `licensing@teipsum.com`.
