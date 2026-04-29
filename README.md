# CQR MCP Server

**Governed context resolution for AI agents.**

An Elixir/OTP MCP server that gives AI agents scoped, quality-annotated, auditable access to organizational knowledge. Single process. No Docker. No external database. Connects to Claude Desktop, Cursor, or any MCP-compatible client in under ten minutes.

All twelve CQR cognitive primitives ship as MCP tools today, plus batch-resolve and batch-assert throughput tools. Both stdio and SSE transports are live. Precompiled NIFs cover Apple Silicon and Linux (x86_64 and ARM64), so end users do not need a Rust toolchain.

---

## The Problem

Enterprise AI agents can already call tools (MCP) and talk to each other (A2A). What they cannot do is answer a harder question: **what is this agent authorized to know, how fresh is that knowledge, who owns it, and how confident should the agent be in it?**

Conventional RAG pipelines retrieve by vector similarity first and apply access control afterward as a filter. That ordering is backwards for governed environments — it leaks information through error messages, produces unpredictable result sets, and has no native way to express freshness, provenance, or certification status. Every enterprise that deploys agents at scale eventually hits this wall. CQR is the layer that gets hit instead.

## What CQR Does

CQR (Contextual Query Resolution, pronounced "seeker") is a query protocol for agent-to-governed-context resolution. It sits above MCP and A2A in the agent infrastructure stack:

| Layer | Protocol | Function |
|-------|----------|----------|
| Agent-to-tool | **MCP** | Connect agents to tools and data sources |
| Agent-to-agent | **A2A** | Communication and coordination between agents |
| **Agent-to-governed-context** | **CQR** | Scoped, quality-annotated knowledge retrieval |

CQR is not competing with MCP. This project *is* an MCP server — it exposes CQR primitives as MCP tools so any MCP-compatible agent can call them. What CQR adds is the governance layer MCP was never designed to provide: scope-first access control, mandatory quality metadata, provenance tracking, and a declarative query language designed for machine cognition rather than human developers.

## Quickstart

Ten minutes, zero external dependencies.

```bash
git clone https://github.com/teipsum/cqr-mcp.git
cd cqr-mcp
mix deps.get
mix compile
./bin/cqr --persist
```

The first `mix compile` downloads the precompiled Grafeo NIF and compiles all Elixir modules. Run it once before connecting an MCP client — the NIF download and initial compile can take 20-30 seconds, which exceeds the startup timeout of most MCP clients including Claude Desktop.

On first boot the embedded Grafeo database is created, the scope hierarchy is bootstrapped, and the server begins listening on stdio for MCP connections and on `http://localhost:4000` for SSE/HTTP clients.

### First-Time Setup

On first boot the database is empty except for the universal protocols (`entity:agent:default`, `entity:governance:relationship_guide`, `entity:governance:assertion_protocol`) and a guided installer entity (`entity:install:setup`).

To configure CQR for your organization, connect a Claude Desktop (or other MCP client) to the running server and start a new conversation with this single prompt:

> CQR resolve entity:install:setup

The installer will ask you four questions about your organization, the agent roles you want to set up, and the queries each agent should answer. It then asserts the org structure, agent identities, and structural reference nodes for each role directly into the graph. The conversation takes about five minutes.

When setup completes, the installer hands you activation prompts for each agent. Open a new conversation per agent and paste its activation prompt to start working with it.

You can re-run `cqr_resolve entity:install:setup` at any time to add more agents — it detects completed setup and offers to add a single agent without re-running the full conversation.

### Precompiled NIFs

The Grafeo NIF is shipped as a precompiled binary via [`rustler_precompiled`](https://hex.pm/packages/rustler_precompiled). Apple Silicon (`aarch64-apple-darwin`), Linux x86_64, and Linux ARM64 users get a ready-to-run binary on `mix deps.get` — no Rust toolchain required. Other targets fall back to building from source; install Rust via [rustup](https://rustup.rs/) and set `CQR_BUILD_NIF=true` if you need to rebuild from source on a supported target.

### Storage modes

The server has two modes:

    ./bin/cqr            # in-memory mode, sample dataset seeded fresh on each boot
    ./bin/cqr --persist  # persistent mode, ~/.cqr/grafeo.grafeo, survives restarts

In-memory mode is the fastest path to seeing the protocol work — every restart is a clean database with the sample organizational dataset (6 scopes, 27 entities, typed relationships) seeded for you. Persistent mode is for real organizational data; it starts with an empty database (scope hierarchy bootstrapped, no sample entities) so you can populate it via `cqr_assert`, adapter imports, or `mix cqr.populate`.

To use a custom database path:

    ./bin/cqr --persist /path/to/db.grafeo

To wipe a persistent database and re-seed the sample dataset:

    ./bin/cqr --persist --reset

The `.grafeo` extension is load-bearing — Grafeo dispatches on it to select the SingleFile storage backend. Anything else silently falls through to a different backend and fails to persist.

### Populating the knowledge graph

For benchmarking, cognitive testing, or seeding a persistent database with a larger corpus than the minimal sample dataset, the repo ships a Mix task:

    mix cqr.populate

This runs ~178 `ASSERT` calls through `Cqr.Engine.execute/2` (the same governance pipeline MCP clients hit), so every entity is parsed, scope-validated, and embedding-indexed. The task defaults to `~/.cqr/grafeo.grafeo`; pass an explicit path to populate a different database file. The MCP server must be stopped first — only one process can hold the Grafeo file lock.

### The `bin/cqr` startup script

The repo ships a launcher at `bin/cqr` that handles graceful restart, environment defaults, and stdio-safe pre-compilation. Call it directly from the repo root or symlink it onto your `PATH`. The SIGTERM-first / short-wait / SIGKILL pattern in the script matters for persistent mode: the Grafeo on-disk format is only guaranteed consistent after a clean close, and a plain `pkill -9` skips the checkpoint path. The `--sname cqr` flag gives the BEAM a stable node name so `pkill` can find it reliably across restarts and so only one instance runs at a time. Pre-compilation is silenced because MCP speaks JSON-RPC over stdio — compiler chatter would corrupt the protocol stream.

### Connect from Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "cqr": {
      "command": "/absolute/path/to/cqr-mcp/bin/cqr",
      "args": ["--persist"],
      "env": {
        "CQR_AGENT_ID": "twin:your_name",
        "CQR_AGENT_SCOPE": "scope:company"
      }
    }
  }
}
```

Restart Claude Desktop. Fourteen tools appear in the tool picker: `cqr_resolve`, `cqr_resolve_batch`, `cqr_discover`, `cqr_assert`, `cqr_assert_batch`, `cqr_certify`, `cqr_signal`, `cqr_trace`, `cqr_refresh`, `cqr_compare`, `cqr_hypothesize`, `cqr_anchor`, `cqr_awareness`, and `cqr_update`.

### Connect over SSE

For browser-based MCP clients, remote agents, or anything that cannot speak stdio, the server also exposes an HTTP/SSE transport on `http://localhost:4000`:

- `GET /sse` — long-lived Server-Sent Events stream. The initial event points clients at the JSON-RPC endpoint and the connection is held open with 15-second keep-alive comments.
- `POST /message` — JSON-RPC 2.0 request/response. Shares the same handler pipeline as stdio, so tools and resources behave identically across transports.

Override the port with the `CQR_MCP_PORT` environment variable, or set `:cqr_mcp, :sse_port` in config. Default is `4000`.

### Example queries

**Point lookup with quality metadata.** Ask the agent: *"What's our churn rate?"* The agent calls `cqr_resolve`:

```json
{ "entity": "entity:product:churn_rate" }
```

CQR resolves the canonical entity within the agent's scope and returns the value with a mandatory quality envelope — freshness, reputation, owner, certification status, provenance.

**Neighborhood exploration.** Ask: *"What's related to churn?"* The agent calls `cqr_discover`:

```json
{ "topic": "entity:product:churn_rate", "depth": 2 }
```

DISCOVER composes graph traversal, BM25 full-text search, and HNSW vector similarity against the embedded database — governance-first, so scope constraints apply before the search runs. The result is a neighborhood map of typed relationships with reputation scores.

**Multi-entity comparison.** Ask: *"How do these two metrics differ?"* The agent calls `cqr_compare` with a list of entities. The tool returns shared relationships, divergent properties, and quality differentials side-by-side.

**Scope boundary enforcement.** If an agent at `scope:company:product` tries to resolve an entity in `scope:company:hr`, CQR does not return an access-denied error. It returns a structured `scope_access` error with suggested visible scopes — errors are data the agent can reason over, not exceptions.

## CQR Primitives

CQR defines twelve cognitive operation primitives across six categories. All twelve ship as MCP tools in this server, alongside `cqr_resolve_batch` and `cqr_assert_batch` throughput tools for high-volume reads and writes.

| MCP Tool | Primitive | Category | Description |
|----------|-----------|----------|-------------|
| `cqr_resolve` | **RESOLVE** | Retrieval | Canonical entity retrieval with quality metadata and optional freshness/reputation constraints. Walks a scope fallback chain when the primary scope has no authoritative answer. |
| `cqr_resolve_batch` | **RESOLVE** (batch) | Retrieval | Resolve multiple entities in one call. Per-entity status in the response; preserves the `cqr_resolve` privacy contract per row. For orient-phase context loading. |
| `cqr_discover` | **DISCOVER** | Retrieval | Neighborhood scan composing graph traversal, BM25 full-text, and HNSW vector similarity. Direction control (`outbound`, `inbound`, `both`) and depth limits. |
| `cqr_assert` | **ASSERT** | Governance | Agent writes uncertified context with mandatory `INTENT` and `DERIVED_FROM` fields. Creates a governance paper trail for agent-generated findings, derived metrics, and working hypotheses. |
| `cqr_certify` | **CERTIFY** | Governance | Lifecycle for entity definitions: `proposed → under_review → certified → (contested → under_review) → superseded → proposed`. Every transition creates an audit record; `contested` and `superseded` are non-terminal and can re-enter the lifecycle. |
| `cqr_signal` | **SIGNAL** | Governance | Writes a reputation assessment with evidence and creates an immutable `SignalRecord` audit node. Preserves certification status so "certified but currently degraded" is expressible. Surfaced through TRACE. |
| `cqr_update` | **UPDATE** | Evolution | Governed knowledge evolution with mandatory change type classification, version history via VersionRecord nodes, and governance matrix enforcement. Preserves semantic address stability while content evolves. |
| `cqr_trace` | **TRACE** | Provenance | Walks the provenance chain of an entity: assertion record, full certification history, signal history, version history, and the `DERIVED_FROM` lineage out to a configurable causal depth. An optional time window filters events. |
| `cqr_refresh` | **REFRESH** | Provenance | `CHECK` mode scans every entity visible to the agent and returns those exceeding a freshness threshold, sorted most-stale-first. A lightweight periodic health check for agent context. |
| `cqr_compare` | **COMPARE** | Reasoning | Side-by-side analysis of multiple entities, surfacing shared relationships, divergent properties, and quality differentials within the agent's visible scope. |
| `cqr_hypothesize` | **HYPOTHESIZE** | Reasoning | Projects the outbound effects of an assumed change through the relationship graph with confidence scoring. Bounded by causal depth; the relationship graph is not modified. |
| `cqr_anchor` | **ANCHOR** | Reasoning | Composite confidence scoring across a set of resolved entities treated as a reasoning chain. Returns a weakest-link floor and actionable recommendations for the entities dragging the chain down. |
| `cqr_awareness` | **AWARENESS** | Perception | Ambient perception of other agents operating in the visible scope set, their declared intent, and the resources they hold. Enables coordination without explicit messaging. |

### `cqr_assert_batch` — throughput optimization

Beyond the twelve primitives, the server exposes `cqr_assert_batch` for high-volume writes. It accepts an array of entity objects with the same fields as `cqr_assert` and runs each through the full governance pipeline independently — a failure on one does not block the others. The response is a summary (`total`, `created`, `skipped`, `failed`) plus a per-entity result list. Use it when an agent needs to record 10–20 findings at once without paying the per-call LLM token overhead of repeated `cqr_assert` invocations. Governance is identical to single-shot assert; only the wire-level batching differs.

### MCP Resources

| URI | Description |
|-----|-------------|
| `cqr://session` | Agent identity, active scope, visible scopes (bidirectional), connected adapters, protocol version, uptime |
| `cqr://scopes` | Organizational scope hierarchy |
| `cqr://entities` | Entity definitions with metadata |
| `cqr://policies` | Governance rules per scope |
| `cqr://system_prompt` | Agent generation contract — the grammar reference, active schema, and few-shot examples that teach an LLM to generate CQR expressions |

The full protocol specification is in [`docs/cqr-protocol-specification.md`](docs/cqr-protocol-specification.md).

## Architecture

Single OS process. Elixir/OTP application with Grafeo (pure-Rust graph DB) embedded via Rustler NIF. No separate database container, no network hop between engine and storage.

- **Grafeo integration** — Rustler NIF with a narrow surface (`new/1`, `execute/2`, `close/1`, `health_check/0`). All queries go through a GenServer (`Cqr.Grafeo.Server`) that serializes access to the NIF. LPG + RDF, Cypher + GQL, HNSW vector search, BM25 full-text, ACID MVCC — all in a single embedded database.
- **OTP supervision tree** — Application supervisor owns the Grafeo server, the scope tree (ETS-cached for sub-millisecond lookups), the stdio MCP transport, and the Bandit-hosted SSE transport. Fault-tolerant, hot-upgradeable, distributed-ready.
- **Adapter behaviour contract** — The engine is backend-agnostic. `Cqr.Adapter.Behaviour` defines a callback per primitive (`resolve/3`, `discover/3`, `assert/3`, `certify/3`, `trace/3`, `signal/3`, `refresh_check/3`, `compare/3`, `hypothesize/3`, `anchor/3`, `awareness/3`, `update/3`) plus `normalize/2`, `health_check/0`, and `capabilities/0`. Write, evolution, and reasoning callbacks are optional — read-only or partial backends declare their capabilities accordingly.
- **Planner-driven adapter resolution** — `Cqr.Engine.Planner` inspects each registered adapter's `capabilities/0` at request time and routes every primitive (V1 retrieval/governance, V2 reasoning, perception) through the same dispatch path. There is no hardcoded Grafeo branch in the engine — Grafeo is simply the reference adapter the planner happens to find first. PostgreSQL/pgvector, Neo4j, Elasticsearch, and warehouse backends slot in as configuration changes, not code changes.
- **Multi-paradigm query composition** — A single DISCOVER invocation composes Cypher scope traversal, BM25 full-text search, HNSW vector similarity ranking, and application-layer post-scoring against one embedded database.
- **Governance-first ordering** — Scope traversal constrains the candidate set *before* similarity search and ranking run. This inverts RAG's similarity-first pipeline: predictable result-set sizes, real access control (not post-hoc filtering), and compute efficiency on large corpora.

Deeper detail in [`docs/architecture.md`](docs/architecture.md).

## Hierarchical Entity Addressing

Entity addresses are hierarchical with unlimited depth. Every primitive that accepts an entity reference accepts a path of arbitrary length:

```
entity:finance:arr                                 # 3 segments — flat ns:name
entity:product:retention:cohort                    # 4 segments
entity:product:retention:cohort:q4                 # 5 segments
entity:product:retention:cohort:q4:weekly:p95      # 7 segments — no upper bound
```

The leaf segment is the entity name; every preceding segment after `entity:` is part of the namespace path.

**Container auto-creation.** When an agent asserts a deep address, the engine creates each interior segment as a container entity on demand and writes a `CONTAINS` edge from each parent to its child. Asserting `entity:product:retention:cohort:q4:weekly` against an empty graph creates four entities (`retention`, `cohort`, `q4`, `weekly`) plus the four `CONTAINS` edges between them, all in the asserting agent's scope. Subsequent asserts under the same prefix reuse the containers — they are created idempotently.

**Scope governance at containment depth.** Scope is enforced at every level of the path, not just the leaf. When an agent RESOLVEs, SIGNALs, CERTIFies, TRACEs, UPDATEs, or otherwise references a hierarchical address, the engine walks the containment chain from root to leaf and checks scope authorization at every node. **A denial at any level returns `entity_not_found`, never `scope_access`** — the agent cannot infer the existence or shape of subtrees in scopes it cannot see. Containers inherit the scope of the asserting agent on creation, so a `scope:company:product` agent that asserts a deep entity puts every auto-created ancestor in `scope:company:product` as well; a `scope:company:finance` agent can never see any of it.

**DISCOVER prefix mode.** A `DISCOVER` topic ending in `:*` switches to hierarchical prefix enumeration: depth-first traversal following `CONTAINS` edges from the anchor downward, returning every visible descendant. Branch-level scope pruning omits any subtree whose root the agent cannot see, **and does not descend into it** — so a blocked subtree is structurally indistinguishable from a missing one.

```bash
# Anchor mode — typed-relationship neighborhood (default)
cqr_discover { "topic": "entity:product:churn_rate", "depth": 2 }

# Prefix mode — every entity contained under the address
cqr_discover { "topic": "entity:product:retention:*" }

# Free-text mode — BM25 + HNSW within visible scope
cqr_discover { "topic": "churn velocity" }
```

Free-text mode and entity-anchor mode are unchanged — the `:*` suffix is the only switch.

After every ASSERT the engine runs a post-write integrity check: it verifies that every interior container exists, that the `CONTAINS` chain is unbroken from root to leaf, and that the leaf entity is reachable via the chain. A failed integrity check rolls the assertion back rather than leaving the graph in a partial state.

## Governance Model

- **Hierarchical scopes.** Scopes form a tree: `scope:company → scope:company:product → scope:company:product:mobile`. Every entity lives in one or more scopes.
- **Bidirectional visibility.** An agent at a given scope sees itself, all ancestors (fallback chain), and all descendants (owned sub-scopes). Siblings are invisible — `scope:company:finance` cannot see `scope:company:engineering`. Out-of-scope entities return `not_found`, not `access_denied`. Genuine invisibility, not post-hoc filtering.
- **Quality metadata envelope.** Every response includes freshness, confidence, reputation, owner, lineage, certification status, provenance, and execution cost. The envelope is never optional — missing fields are explicit `:unknown`, never silently dropped.
- **Two-tier trust.** Context exists in two trust states: *asserted* (agent-written, uncertified, lineage-tracked) and *certified* (approved through the CERTIFY lifecycle). Both are visible; the trust level is explicit metadata, and agents can reason over it.
- **Governed evolution.** Certified entities are not frozen. UPDATE evolves content while preserving the semantic address, writing a `VersionRecord` audit chain. A governance matrix gates which change types apply immediately, which require a contest (entity transitions to `contested`, change is deferred to a pending `UpdateRecord` for review), and which are blocked outright. Superseded entities can be revived by UPDATE; contested entities reject all updates until the contest resolves.
- **Governance invariance boundary.** `Cqr.Engine.execute/2` is the single entry point for all CQR operations. Scope validation, quality annotation, conflict preservation, and cost accounting happen at the engine level — below any delivery interface. No MCP tool, REST endpoint, or direct call can bypass them.

## Configuration

The server reads three environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CQR_AGENT_ID` | `twin:default` | Agent identifier used for provenance and authority fields |
| `CQR_AGENT_SCOPE` | `scope:company` | Agent's active scope in the hierarchy |
| `CQR_MCP_PORT` | `4000` | Port for the SSE/HTTP transport |

The sample dataset lives in `lib/repo/seed.ex`. Replace it with your own scopes, entities, and relationships to point CQR at real organizational knowledge. The seeder is idempotent and runs only when the database is empty.

To add a new adapter, implement `Cqr.Adapter.Behaviour` and register it in application config. See [`docs/architecture.md`](docs/architecture.md) for the contract and [`CONTRIBUTING.md`](CONTRIBUTING.md) for the workflow.

## Roadmap

The twelve-primitive protocol is shipped. What is next:

- **Contest resolution UI** — An operator workflow to review pending `UpdateRecord`s on contested entities, approve or reject the proposed change, and drive the entity back to `under_review` or `certified`. The governance matrix and audit chain are already in place; this is the human-facing review surface.
- **Phoenix LiveView interface** — A first-party operator UI for browsing scopes, inspecting provenance chains, reviewing certification queues, and watching live signal traffic. Consumes the same `Cqr.Engine.execute/2` boundary as MCP clients, so governance behaviour is identical.
- **Cognitive evidence experiments** — Structured benchmarks measuring how scope-bounded retrieval, mandatory quality metadata, and provenance-aware error envelopes change LLM agent behaviour against ungoverned RAG baselines.
- **Enterprise adapters** — Reference adapters for PostgreSQL/pgvector, Neo4j, Elasticsearch, and warehouse backends (Snowflake, BigQuery). The behaviour contract already supports them; these are configuration-driven implementations.
- **Multi-agent runtime** — Agent taxonomy with permission intersection, human-agent coupling management, lease-based resource governance, and context contamination prevention.

## Testing

```bash
mix test
```

The suite runs **561 tests** in-process against an ephemeral Grafeo database — no Docker, no external services. Every primitive has parser tests, engine tests, and an MCP integration test that exercises the full JSON-RPC path. The exhaustive MCP integration suite in `test/cqr_mcp/integration_test.exs` is the fastest way to catch regressions across all thirteen tools after an adapter or planner change.

## Documentation

- [`docs/cqr-primer.md`](docs/cqr-primer.md) — What CQR is and why it exists (read first)
- [`docs/architecture.md`](docs/architecture.md) — How the system is built
- [`docs/mcp-integration.md`](docs/mcp-integration.md) — Connecting Claude Desktop, Cursor, and custom MCP clients
- [`docs/cqr-protocol-specification.md`](docs/cqr-protocol-specification.md) — Full protocol specification v1.0 with all twelve primitives
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — Development setup and contribution workflow

## License

Business Source License 1.1. You may make production use of CQR-MCP for your own internal business purposes. You may **not** use it to provide a commercial platform, application, or service to third parties that embeds, hosts, or utilizes CQR-MCP as a backend component for the purpose of a commercial offering. The change date is **April 8, 2030**, at which point the license automatically converts to **MIT License** with no restrictions. Full terms in [`LICENSE`](LICENSE). For alternative licensing arrangements, contact `licensing@teipsum.com`.

## About

CQR is developed by **TEIPSUM** — *"Uniquely Yourself."* The protocol was previously named SEQUR (Semantic Query Resolution); the USPTO provisional patent application was filed under the SEQUR name and all protocol claims apply to CQR. The rename reflects the protocol's evolution from seven primitives to twelve and its broader scope as a cognitive operations protocol rather than a purely semantic query language.
