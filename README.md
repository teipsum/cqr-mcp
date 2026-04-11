# CQR MCP Server

**Governed context resolution for AI agents.**

An Elixir/OTP MCP server that gives AI agents scoped, quality-annotated, auditable access to organizational knowledge. Single process. No Docker. No external database. Connects to Claude Desktop, Cursor, or any MCP-compatible client in under ten minutes.

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
mix run --no-halt
```

On first boot the embedded Grafeo database is created in-memory, a sample organizational dataset (6 scopes, 27 entities, 17 typed relationships) is seeded, and the server begins listening on stdio for MCP connections.

### Persistent storage

By default the server runs in-memory with sample data — every restart is a fresh database.
To persist data across restarts:

    mix run --no-halt -- --persist

Data is stored at `~/.cqr/grafeo.db`. Persistent mode starts with an empty database —
populate it with `cqr_assert` or adapter imports. To use a custom path:

    mix run --no-halt -- --persist /path/to/db

To reset the database and re-seed with sample data:

    mix run --no-halt -- --persist --reset

### Connect from Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "cqr": {
      "command": "/path/to/elixir",
      "args": ["--sname", "cqr", "-S", "mix", "run", "--no-halt"],
      "cwd": "/path/to/cqr-mcp",
      "env": {
        "CQR_AGENT_ID": "twin:your_name",
        "CQR_AGENT_SCOPE": "scope:company"
      }
    }
  }
}
```

Restart Claude Desktop. The tools `cqr_resolve`, `cqr_discover`, `cqr_certify`, and `cqr_assert` appear in the tool picker.

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

**Scope boundary enforcement.** If an agent at `scope:company:product` tries to resolve an entity in `scope:company:hr`, CQR does not return an access-denied error. It returns a structured `scope_access` error with suggested visible scopes — errors are data the agent can reason over, not exceptions.

## CQR Primitives

CQR defines eleven cognitive operation primitives across five categories. This MCP server implements **four V1 primitives** as MCP tools. The remaining seven primitives are specified in the protocol but ship in V2.

### V1 — Implemented

| MCP Tool | Primitive | Description |
|----------|-----------|-------------|
| `cqr_resolve` | **RESOLVE** | Canonical entity retrieval with quality metadata and optional freshness/reputation constraints. Walks a scope fallback chain when the primary scope has no authoritative answer. |
| `cqr_discover` | **DISCOVER** | Neighborhood scan composing graph traversal, BM25 full-text, and HNSW vector similarity. Direction control (`outbound`, `inbound`, `both`) and depth limits. |
| `cqr_certify` | **CERTIFY** | Governance lifecycle for entity definitions: `proposed → under_review → certified → superseded`. Every transition creates an audit record with authority, evidence, and timestamp. |
| `cqr_assert` | **ASSERT** | Agent writes uncertified context with mandatory `INTENT` and `DERIVED_FROM` fields. Creates a governance paper trail for agent-generated findings, derived metrics, and working hypotheses. |

### MCP Resources

| URI | Description |
|-----|-------------|
| `cqr://session` | Agent identity, active scope, visible scopes (bidirectional), connected adapters, protocol version, uptime |
| `cqr://scopes` | Organizational scope hierarchy |
| `cqr://entities` | Entity definitions with metadata |
| `cqr://policies` | Governance rules per scope |
| `cqr://system_prompt` | Agent generation contract — the grammar reference, active schema, and few-shot examples that teach an LLM to generate CQR expressions |

### V2 — Specified, Not Yet Shipped

| Primitive | Category | Purpose |
|-----------|----------|---------|
| **TRACE** | Reasoning | Temporal and causal reasoning — how did this entity evolve? |
| **HYPOTHESIZE** | Reasoning | Impact projection — what if this changed? |
| **COMPARE** | Reasoning | Multi-entity side-by-side analysis |
| **ANCHOR** | Reasoning | Composite confidence scoring for a set of resolved entities |
| **SIGNAL** | Governance | Distributed quality feedback — agents flag stale or suspect data |
| **REFRESH** | Maintenance | Freshness enforcement and peripheral-context re-read |
| **AWARENESS** | Perception | Ambient awareness of other agents operating in scope |

The full protocol specification is in [`docs/cqr-protocol-specification.md`](docs/cqr-protocol-specification.md).

## Architecture

Single OS process. Elixir/OTP application with Grafeo (pure-Rust graph DB) embedded via Rustler NIF. No separate database container, no network hop between engine and storage.

- **Grafeo integration** — Rustler NIF with a narrow surface (`new/1`, `execute/2`, `close/1`, `health_check/0`). All queries go through a GenServer (`Cqr.Grafeo.Server`) that serializes access to the NIF. LPG + RDF, Cypher + GQL, HNSW vector search, BM25 full-text, ACID MVCC — all in a single embedded database.
- **OTP supervision tree** — Application supervisor owns the Grafeo server, the scope tree (ETS-cached for sub-millisecond lookups), the MCP transport, and the engine. Fault-tolerant, hot-upgradeable, distributed-ready.
- **Multi-paradigm query composition** — A single DISCOVER invocation composes Cypher scope traversal, BM25 full-text search, HNSW vector similarity ranking, and application-layer post-scoring against one embedded database.
- **Governance-first ordering** — Scope traversal constrains the candidate set *before* similarity search and ranking run. This inverts RAG's similarity-first pipeline: predictable result-set sizes, real access control (not post-hoc filtering), and compute efficiency on large corpora.
- **Adapter behaviour contract** — The engine is backend-agnostic. `Cqr.Adapter.Behaviour` defines `resolve/3`, `discover/3`, `assert/3`, `normalize/2`, `health_check/0`, and `capabilities/0`. Grafeo is the reference adapter. PostgreSQL/pgvector, Neo4j, Elasticsearch, and warehouse backends are a configuration change, not a code change.

Deeper detail in [`docs/architecture.md`](docs/architecture.md).

## Governance Model

- **Hierarchical scopes.** Scopes form a tree: `scope:company → scope:company:product → scope:company:product:mobile`. Every entity lives in one or more scopes.
- **Bidirectional visibility.** An agent at a given scope sees itself, all ancestors (fallback chain), and all descendants (owned sub-scopes). Siblings are invisible — `scope:company:finance` cannot see `scope:company:engineering`. Out-of-scope entities return `not_found`, not `access_denied`. Genuine invisibility, not post-hoc filtering.
- **Quality metadata envelope.** Every response includes freshness, confidence, reputation, owner, lineage, certification status, provenance, and execution cost. The envelope is never optional — missing fields are explicit `:unknown`, never silently dropped.
- **Two-tier trust.** Context exists in two trust states: *asserted* (agent-written, uncertified, lineage-tracked) and *certified* (approved through the CERTIFY lifecycle). Both are visible; the trust level is explicit metadata, and agents can reason over it.
- **Governance invariance boundary.** `Cqr.Engine.execute/2` is the single entry point for all CQR operations. Scope validation, quality annotation, conflict preservation, and cost accounting happen at the engine level — below any delivery interface. No MCP tool, REST endpoint, or direct call can bypass them.

## Configuration

The server reads two environment variables to populate the agent context on every request:

| Variable | Default | Description |
|----------|---------|-------------|
| `CQR_AGENT_ID` | `anonymous` | Agent identifier used for provenance and authority fields |
| `CQR_AGENT_SCOPE` | `scope:company` | Agent's active scope in the hierarchy |

The sample dataset lives in `lib/cqr/repo/seed.ex`. Replace it with your own scopes, entities, and relationships to point CQR at real organizational knowledge. The seeder is idempotent and runs only when the database is empty.

To add a new adapter, implement `Cqr.Adapter.Behaviour` and register it in application config. See [`docs/architecture.md`](docs/architecture.md) for the contract and [`CONTRIBUTING.md`](CONTRIBUTING.md) for the workflow.

## Roadmap

**V2 primitives** — TRACE, SIGNAL, REFRESH, AWARENESS, COMPARE, HYPOTHESIZE, ANCHOR. The grammar and semantics are specified today; what remains is the adapter and engine work to ship them.

**Platform extensions** — Multi-agent runtime with agent taxonomy and permission intersection, human-agent coupling management, lease-based resource governance, and context contamination prevention are UNICA commercial platform features that consume this server as a building block.

**Transport** — stdio is primary. SSE transport for remote MCP connections via Plug/Bandit is planned for V1.1.

## Documentation

- [`docs/cqr-primer.md`](docs/cqr-primer.md) — What CQR is and why it exists (read first)
- [`docs/architecture.md`](docs/architecture.md) — How the system is built
- [`docs/mcp-integration.md`](docs/mcp-integration.md) — Connecting Claude Desktop, Cursor, and custom MCP clients
- [`docs/cqr-protocol-specification.md`](docs/cqr-protocol-specification.md) — Full protocol specification v1.0 with all eleven primitives
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — Development setup and contribution workflow

## License

Business Source License 1.1. You may make production use of CQR-MCP for your own internal business purposes. You may **not** use it to provide a commercial platform, application, or service to third parties that embeds, hosts, or utilizes CQR-MCP as a backend component for the purpose of a commercial offering. The change date is **April 8, 2030**, at which point the license automatically converts to **MIT License** with no restrictions. Full terms in [`LICENSE`](LICENSE). For alternative licensing arrangements, contact `licensing@teipsum.com`.

## About

CQR is developed by **TEIPSUM** — *"Uniquely Yourself."* The protocol was previously named SEQUR (Semantic Query Resolution); the USPTO provisional patent application was filed under the SEQUR name and all protocol claims apply to CQR. The rename reflects the protocol's evolution from seven primitives to eleven and its broader scope as a cognitive operations protocol rather than a purely semantic query language.
