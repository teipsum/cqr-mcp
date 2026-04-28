# PROJECT_KNOWLEDGE.md

> **Read this file at the start of every Claude Code session.** It contains everything you need to understand the project, the architecture, and the current state. If you need deeper detail on a specific area, the referenced spec documents in `/docs` have the full specifications.

---

## 1. What Is CQR

CQR (**Cognitive Query Resolution**) is a declarative query language designed for machine cognition as the primary consumer. It enables AI agents to interact with organizational context across heterogeneous storage backends through cognitive operation primitives rather than data manipulation primitives.

**The core insight:** Existing query languages (SQL, GraphQL, SPARQL, Cypher) are designed for human developers. When AI agents use them, they do so through pre-coded tool calls. CQR flips this — the agent generates the query expression from natural language intent, and the language's primitives correspond to reasoning patterns (resolve a concept, orient in a neighborhood, assert a finding, trace causality, hypothesize impact, ground reasoning, govern definitions) rather than data operations (select, join, filter).

**Naming history.** CQR was previously named **SEQUR** (Semantic Query Resolution). The USPTO provisional patent application was filed under the SEQUR name; all protocol semantics and claims in the patent apply to CQR. The rename reflects the protocol's evolution from seven primitives to twelve and its broader scope as a cognitive operations protocol rather than a purely semantic query language. "C-Q-R" is pronounced "seeker."

**Twelve primitives in six categories:**

| Category | Primitives |
|---|---|
| Context Resolution | RESOLVE, DISCOVER |
| Context Creation | ASSERT |
| Reasoning | TRACE, HYPOTHESIZE, COMPARE, ANCHOR |
| Governance | SIGNAL, CERTIFY |
| Evolution | UPDATE |
| Maintenance & Perception | REFRESH, AWARENESS |

The canonical specification with full grammar, semantics, and examples for all twelve primitives lives in `docs/cqr-protocol-specification.md`. This document focuses on the V1 MCP implementation.

**Protocol positioning:** MCP = agent-to-tool, A2A = agent-to-agent, CQR = agent-to-governed-context. CQR is the governance layer above MCP and A2A in the agent protocol stack.

**Patent:** A provisional patent application covering 61 claims across 4 independent claims has been prepared (filed under the SEQUR name). Claims cover the query language, agent generation contract, adapter architecture, multi-agent runtime, human-agent coupling, personal cognitive metadata, resource governance, activity visibility, and context contamination prevention. The ASSERT primitive is documented as a continuation in `specs/Assert primitive specification.md` with a GPG-signed timestamp. Priority date must be locked before July 2026.

---

## 2. What This Repo Is

`cqr_mcp` is a standalone Elixir/OTP application that:

1. Embeds Grafeo (pure-Rust graph database) via Rustler NIF — no external database required
2. Implements the CQR parser, context assembly engine, and scope resolution
3. Exposes CQR primitives as MCP tools — currently thirteen: `cqr_resolve`, `cqr_discover`, `cqr_assert`, `cqr_assert_batch`, `cqr_certify`, `cqr_signal`, `cqr_update`, `cqr_trace`, `cqr_refresh`, `cqr_compare`, `cqr_hypothesize`, `cqr_anchor`, `cqr_awareness`
4. Exposes organizational context as MCP resources (scopes, entities, policies, system prompt)
5. Accepts connections from any MCP client (Claude Desktop, Cursor, VS Code, custom agents)
6. Enforces scope-first governance on every query
7. Returns quality-annotated context with mandatory metadata envelope
8. Runs as a single OS process on commodity hardware with zero external dependencies
9. Supports both in-memory (default) and persistent (`--persist`) storage modes

**License:** Business Source License 1.1 with an April 8, 2030 change date to MIT License. See `LICENSE` at the repo root for the full text and restrictions on third-party commercial hosting.

**Patent filing:** Non-provisional patent filed April 9, 2026 (Application 64/034,544), covering the CQR query language, agent generation contract, adapter architecture, and governance invariance boundary.

**What is NOT in this repo:** Multi-agent runtime (agent taxonomy, co-sponsorship, permission intersection), human-agent coupling management, lease-based resource governance, context contamination prevention. All twelve CQR primitives (including COMPARE, HYPOTHESIZE, ANCHOR, AWARENESS, and UPDATE) ship in this repository.

---

## 3. Architecture

### 3.1 Embedded Grafeo

Grafeo is embedded directly into the BEAM via a Rustler NIF. No Docker. No separate process. The database starts with the OTP application and lives inside the supervision tree.

- **Grafeo capabilities:** LPG + RDF, GQL + Cypher + Gremlin + SPARQL + SQL/PGQ, HNSW vector search, BM25 full-text search, ACID transactions with MVCC
- **NIF surface:** `new/1`, `execute/2`, `close/1`, `health_check/0` — everything else stays in Elixir
- **Precompiled binaries** via `rustler_precompiled` — no Rust toolchain required for users
- **Performance:** Sub-millisecond scope traversal validated in POC

### 3.2 Module Structure

```
lib/
  cqr/
    parser.ex                 # NimbleParsec top-level grammar
    parser/
      resolve.ex              # RESOLVE-specific combinators
      discover.ex             # DISCOVER-specific combinators
      certify.ex              # CERTIFY-specific combinators
    engine.ex                 # Context Assembly Engine — THE governance invariance boundary
    scope.ex                  # Scope hierarchy + resolution
    quality.ex                # Quality metadata envelope
    cost.ex                   # Cost accounting per query
    error.ex                  # Informative error semantics
  cqr_mcp/
    server.ex                 # MCP JSON-RPC transport (stdio + SSE)
    tools.ex                  # Tool definitions (resolve, discover, certify)
    resources.ex              # Resource definitions (scopes, entities, policies, system prompt)
    handler.ex                # Request routing + response formatting
  adapter/
    behaviour.ex              # Adapter behaviour contract
    grafeo.ex                 # Grafeo adapter (calls NIF)
  grafeo/
    native.ex                 # Rustler NIF module
  repo/
    semantic.ex               # Semantic Definition Repository (queries via Grafeo)
    scope_tree.ex             # Scope hierarchy management (ETS cache + Grafeo backing)
    seed.ex                   # Sample data seeder
native/
  cqr_grafeo/
    Cargo.toml                # Rust crate: grafeo (embedded) + rustler
    src/lib.rs                # NIF functions
```

### 3.3 Data Flow

```
Natural language intent
  → LLM generates CQR expression (via agent generation contract)
  → Cqr.Parser parses to AST
  → Cqr.Engine.execute/2 (THE governance invariance boundary)
    → Validate scope access (Cqr.Scope)
    → Plan adapter fan-out (Cqr.Engine.Planner)
    → Execute concurrently across adapters (Task.async_stream)
    → Normalize results (adapter.normalize/2)
    → Merge with conflict preservation
    → Annotate quality metadata (Cqr.Quality)
    → Compute cost (Cqr.Cost)
  → Return %Cqr.Result{} with quality envelope
  → MCP server formats as JSON-RPC response
```

**Governance invariance:** `Cqr.Engine.execute/2` is the single entry point. Everything above it (MCP server, REST API, LiveView UI, direct call) goes through the same governance enforcement. Scope resolution, quality metadata, conflict preservation, and cost accounting happen at the engine level. No delivery interface can bypass them.

### 3.4 Adapter Behaviour Contract

Every storage backend adapter implements:

```elixir
@callback resolve(expression, scope_context, opts) :: {:ok, results} | {:error, reason}
@callback discover(expression, scope_context, opts) :: {:ok, results} | {:error, reason}
@callback normalize(raw_results, metadata) :: %Cqr.Result{}
@callback health_check() :: :ok | {:error, reason}
```

Adapters self-declare capabilities (which primitives they support). The engine routes only applicable expressions to each adapter. V1 has one adapter (Grafeo). The architecture supports multiple concurrent adapters — adding PostgreSQL or Neo4j is a configuration change, not a code change.

---

## 4. CQR Primitives (V1 MCP Scope)

The full protocol defines 12 primitives. All twelve ship in this repo's MCP server: RESOLVE, DISCOVER, ASSERT, CERTIFY, SIGNAL, UPDATE, TRACE, REFRESH, COMPARE, HYPOTHESIZE, ANCHOR, AWARENESS. See `docs/cqr-protocol-specification.md` for the canonical grammar and semantics.

### RESOLVE — Canonical Retrieval
Retrieve a canonical entity by semantic address from the nearest matching scope, with quality metadata.

```
RESOLVE entity:finance:arr
  FROM scope:finance
  WITH freshness < 24h
  WITH reputation > 0.7
  FALLBACK scope:product → scope:global
  INCLUDE lineage, confidence, owner
```

All clauses after the entity are optional. Clauses may appear in any order.

### DISCOVER — Neighborhood Scan
Returns a navigable map of concepts related to an anchor entity, combining graph traversal and vector similarity.

```
DISCOVER concepts
  RELATED TO entity:product:churn_rate
  WITHIN scope:product, scope:customer_success
  DEPTH 3
  DIRECTION both
  ANNOTATE freshness, reputation, owner
```

`DIRECTION` controls which side of the edge graph is traversed. Edges are stored once, directionally — there are no reverse-edge duplicates. `outbound` returns entities the anchor points to; `inbound` returns entities that point at the anchor; `both` (default) returns the union with each result tagged by direction. The relationship type always reads in its original stored direction (e.g., `CONTRIBUTES_TO` always means source contributes to target). DISCOVER is the general exploration primitive — directed reasoning is handled by TRACE (inbound/causal) and HYPOTHESIZE (outbound/impact), which share the same traversal engine.

### CERTIFY — Governance Workflow
Manages definition lifecycle through proposal, review, and certification phases.

```
CERTIFY entity:finance:arr
  STATUS certified
  AUTHORITY "agent:twin:michael"
  EVIDENCE "Validated against Q4 actuals"
```

Statuses: `proposed → under_review → certified → superseded`. The full lifecycle is supported and persists — once certified, the status is visible on subsequent RESOLVE calls in the quality envelope (`certified_by`, `certified_at`).

`AUTHORITY` accepts either a bare identifier (`cfo`) or a quoted free-form string (`"agent:twin:michael"`, `"finance_team:q4_2026"`). The quoted form allows colons and other punctuation in opaque authority IDs. `EVIDENCE` is always a quoted string.

### ASSERT — Agent-Written Context with Provenance
Writes uncertified context into the graph with mandatory `INTENT` and `DERIVED_FROM` fields. The asserted entity is immediately visible to RESOLVE and DISCOVER, but carries lower trust (reputation 0.5, `certified: false`) and an audit trail linking it back to the source entities and the asserting agent's intent.

```
ASSERT entity:product:churn_velocity
  TYPE derived_metric
  DESCRIPTION "Rate of change in churn over 30d rolling window"
  INTENT "Answer CEO question on whether churn is accelerating"
  DERIVED_FROM entity:product:churn_rate, entity:product:nps
  IN scope:company:product
  CONFIDENCE 0.7
```

Valid `TYPE` values: `metric`, `definition`, `policy`, `derived_metric`, `observation`, `recommendation`. Optional inline relationships attach at write time via the `REL:entity:ns:name:strength` shorthand in the MCP tool arg; valid types are `CORRELATES_WITH`, `CONTRIBUTES_TO`, `DEPENDS_ON`, `CAUSES`, `PART_OF`.

### TRACE — Provenance History
Walks the provenance chain of an entity: assertion record, certification history, signal history, and the `DERIVED_FROM` lineage out to a configurable causal depth. An optional time window filters events.

```
TRACE entity:product:churn_velocity OVER last 30d DEPTH causal:2
```

TRACE is the reverse lens of DISCOVER. Where DISCOVER asks "what is this related to?", TRACE asks "how did this come to be, and what changed it?".

### SIGNAL — Reputation Update with Evidence
Writes a reputation assessment. Creates an immutable `SignalRecord` audit node and updates the entity's current reputation score. Certification status is **preserved** — a certified entity with a dropped reputation is expressible and correct ("certified but currently degraded").

```
SIGNAL reputation ON entity:product:churn_velocity SCORE 0.35
  EVIDENCE "Upstream churn_rate pipeline is 6 days stale"
```

SignalRecords are surfaced through TRACE as part of the entity's provenance chain.

### REFRESH — Staleness Scan
`CHECK` mode scans every entity visible to the agent and returns those whose freshness exceeds a threshold, sorted most-stale-first.

```
REFRESH CHECK active_context WITHIN scope:company:product
  WHERE age > 24h RETURN stale_items
```

Intended as a lightweight periodic health check from agent loops or a pre-flight before high-stakes questions.

---

## 5. Formal Grammar (PEG)

```
expression <- resolve / discover / certify

resolve <- 'RESOLVE' sp entity (sp from_clause)? (sp with_clause)*
           (sp include_clause)? (sp fallback_clause)?
from_clause <- 'FROM' sp scope
with_clause <- 'WITH' sp (freshness_constraint / reputation_constraint)
freshness_constraint <- 'freshness' sp '<' sp duration
reputation_constraint <- 'reputation' sp '>' sp score
include_clause <- 'INCLUDE' sp annotation_list
fallback_clause <- 'FALLBACK' sp scope (sp arrow sp scope)*

discover <- 'DISCOVER' sp 'concepts' sp related_clause
           (sp within_clause)? (sp depth_clause)?
           (sp direction_clause)?
           (sp annotate_clause)? (sp limit_clause)?
related_clause <- 'RELATED' sp 'TO' sp (entity / string_literal)
within_clause <- 'WITHIN' sp scope (',' sp scope)*
depth_clause <- 'DEPTH' sp integer
direction_clause <- 'DIRECTION' sp ('outbound' / 'inbound' / 'both')
annotate_clause <- 'ANNOTATE' sp annotation_list
limit_clause <- 'LIMIT' sp integer

certify <- 'CERTIFY' sp entity sp status_clause
           (sp authority_clause)? (sp supersedes_clause)?
           (sp certify_evidence)?
status_clause <- 'STATUS' sp certify_status
certify_status <- 'proposed' / 'under_review' / 'certified' / 'superseded'
authority_clause <- 'AUTHORITY' sp (string_literal / identifier)
supersedes_clause <- 'SUPERSEDES' sp entity
certify_evidence <- 'EVIDENCE' sp string_literal

# Terminals
entity <- 'entity:' identifier ':' identifier
scope <- 'scope:' identifier (':' identifier)*
agent_ref <- 'agent:' identifier (':' identifier)*
duration <- integer ('m' / 'h' / 'd' / 'w')
score <- [0-9] '.' [0-9]+
integer <- [0-9]+
identifier <- [a-z_] [a-z0-9_]*
string_literal <- '"' [^"]* '"'
annotation_list <- annotation (',' sp annotation)*
annotation <- 'freshness' / 'confidence' / 'reputation' / 'owner' / 'lineage'
sp <- ' '+
```

The parser must accept optional clauses in any order within each primitive. This accommodates the variable ordering tendencies of LLM autoregressive generation.

---

## 6. Quality Metadata Envelope

Every CQR response includes a mandatory quality metadata envelope:

```elixir
%Cqr.Quality{
  freshness: ~U[2026-04-01 14:30:00Z],    # when the value was last updated
  confidence: 0.92,                         # 0.0-1.0, composite confidence score
  reputation: 0.87,                         # 0.0-1.0, from distributed reputation network
  owner: "finance_team",                    # responsible party
  lineage: [...],                           # version history
  certified_by: "cfo" | nil,               # certification authority
  certified_at: ~U[...] | nil              # certification timestamp
}
```

This is a protocol requirement, not an optional feature. An agent always knows how much to trust what it received.

---

## 7. Scope-First Semantics

Scope is not a filter applied after retrieval. It is a fundamental part of query execution that determines what is visible, what is authoritative, and what fallback chain is followed.

- Every expression operates within a scope hierarchy
- The scope resolution engine determines entity visibility before any data retrieval
- Visibility is bidirectional along the hierarchy: an agent sees its own scope, all ancestors (for fallback resolution), and all descendants (parent scopes own their children — essential for company-wide admin agents). Siblings remain isolated.
- Scope traversal follows: agent's active scope → ancestors (fallback chain) and descendants (owned sub-scopes)
- If an entity is not in the agent's accessible scope, it does not exist from that agent's perspective (genuine invisibility, not access denied)
- Scope resolution is cached in ETS for sub-millisecond lookup

---

## 8. MCP Server Interface

### Tools

Seven MCP tools are exposed. Full parameter documentation is in `docs/mcp-integration.md`; the summary:

```
cqr_resolve:
  input: {entity, scope?, freshness?, reputation?}
  output: governed context with quality metadata envelope

cqr_discover:
  input: {topic, scope?, depth?, direction?}
  output: neighborhood map with relationship types, direction tags,
          and quality annotations
  direction: outbound | inbound | both (default: both)

cqr_assert:
  input: {entity, type, description, intent, derived_from,
          scope?, confidence?, relationships?}
  output: written entity with assertion record and derived_from links
  required: entity, type, description, intent, derived_from

cqr_certify:
  input: {entity, status, authority?, evidence?}
  output: certification status with provenance chain
  authority: bare identifier OR quoted free-form string with colons

cqr_trace:
  input: {entity, depth?, time_window?}
  output: assertion + certification + signal history plus derived_from chain

cqr_signal:
  input: {entity, score, evidence}
  output: reputation update with SignalRecord; certification preserved

cqr_refresh:
  input: {threshold?, scope?}
  output: stale_items sorted most-stale-first within the agent's scope
```

### Resources

```
cqr://session         — Current agent identity, scope, permissions,
                        visible_scopes (full bidirectional set), connected
                        adapters, server_version, protocol (CQR/1.0),
                        uptime_seconds, connection {transport, connected_at,
                        session_id (UUIDv4)}
cqr://scopes          — Organizational scope hierarchy
cqr://entities        — Entity definitions with metadata
cqr://policies        — Governance rules per scope
cqr://system_prompt   — CQR agent generation contract
```

### Transports

- **stdio** (primary): for Claude Desktop, Claude Code, Cursor
- **SSE** (secondary): for remote/HTTP connections via Plug/Bandit

### Agent Context

The MCP server reads two environment variables to populate the agent context for every request:

- `CQR_AGENT_ID` — agent identifier (default: `anonymous`)
- `CQR_AGENT_SCOPE` — agent's active scope, in `scope:seg1:seg2` form (default: `scope:company`)

These are surfaced verbatim through the `cqr://session` resource and used by the engine to compute `visible_scopes` (bidirectional: self + ancestors + descendants).

---

## 9. Agent Generation Contract

Three-component system provided in the LLM's system prompt:

1. **Grammar Reference:** Condensed PEG specification, one primitive per section
2. **Active Schema:** Entities, scopes, relationships formatted for LLM consumption (one entity per line, UPPERCASE relationships, indented scope tree)
3. **Few-Shot Examples:** Natural-language-to-CQR translation pairs, 2+ per primitive (simple and complex)

The active schema format uses specific formatting conventions empirically validated to improve LLM generation accuracy: one entity per line with namespace/name/type/description, relationship types in UPPERCASE, clear section delimiters, scope hierarchy as indented tree. These conventions outperform JSON, YAML, and free-text representations.

Validated accuracy: 94-97% syntactic, 93-96% semantic across models from 8B to 14B parameters on local hardware.

---

## 10. Sample Organizational Dataset

The seeder populates Grafeo with a sample SaaS company:

**Scopes:**
```
scope:company (root)
├── scope:company:finance
├── scope:company:product
├── scope:company:engineering
├── scope:company:hr
└── scope:company:customer_success
```

**Sample entities:**
- entity:finance:arr (metric, scope:finance)
- entity:finance:burn_rate (metric, scope:finance)
- entity:product:churn_rate (metric, scope:product)
- entity:product:nps (metric, scope:product, scope:customer_success)
- entity:hr:headcount (metric, scope:hr)
- entity:hr:enps (metric, scope:hr)
- entity:engineering:deployment_frequency (metric, scope:engineering)

**Sample relationships:**
- entity:hr:enps CAUSES entity:hr:attrition (strength: 0.8)
- entity:hr:attrition CONTRIBUTES_TO entity:finance:operating_expenses (strength: 0.6)
- entity:product:churn_rate CORRELATES_WITH entity:product:nps (strength: 0.7)
- entity:product:nps DEPENDS_ON entity:product:feature_adoption (strength: 0.5)

Each entity has quality metadata (freshness timestamps, reputation scores, owners) and vector embeddings on descriptions (pre-computed, stored as node properties).

The seeder is idempotent — checks for existing data before inserting. Runs as part of application startup when the database is empty.

---

## 11. What Exists from the POC

**Working and validated (can be ported to this repo):**
- NimbleParsec parser for RESOLVE and DISCOVER (~20 parser tests)
- Cqr.Engine with Task.async_stream fan-out
- Adapter behaviour contract: resolve/3, discover/3, normalize/2, health_check/0
- Teipsum Agent GenServer with multi-step reasoning loop
- 55 ExUnit tests across parser, integration, engine, agent
- Validation suite: 100-intent corpus, runner GenServer, LiveView dashboard at /validation
- Best results: 97%/96% syntactic/semantic accuracy on qwen2.5:14b

**Needs rework for this repo:**
- Parser covers 7/10 primitives (V1 only needs RESOLVE, DISCOVER, CERTIFY)
- Adapters are coupled to POC data model — need generalization
- Scope hierarchy is hardcoded — needs to be dynamic
- Quality metadata is partially implemented — freshness and reputation exist, confidence and lineage are stubs
- Error semantics are basic exceptions, not informative envelopes

**Not yet built:**
- Rustler NIF wrapping Grafeo embedded engine
- Grafeo adapter (replacing Postgres + Neo4j with single embedded backend)
- MCP server (JSON-RPC 2.0, stdio + SSE transports)
- Complete documentation and README
- Precompiled NIF binaries

---

## 12. Development Rules

These are non-negotiable for every Claude Code session:

1. **Read this file first.** Then read the relevant spec doc in `/docs` for the current task.
2. **1-2 step prompt chunks.** Build the struct, then the parser, then the tests, then the integration. Not all at once.
3. **Commit after every milestone.** Signed commits (`git commit -S`). This is patent evidence.
4. **Run `mix test --trace` after every change.** Catch regressions immediately.
5. **Every capability ships with tests AND documentation.** If it's not tested and documented, it doesn't exist.
6. **Zero external dependencies for `mix test`.** All tests run in-process against embedded Grafeo.
7. **The 10-minute promise:** `git clone` → `mix deps.get` → `mix run --no-halt` → connect Claude → query. Under 10 minutes. No Docker. No external database.

---

## 13. Spec Documents Reference

| Document | Contains |
|---|---|
| `README.md` (root) | **Canonical CQR Protocol Specification v1.0.** All twelve primitives in six categories, full grammar, return envelope, error semantics, MCP delivery. The user-facing spec. |
| `docs/MCP-SERVER-PLAN.md` | Full phased build plan (Phases 0-6), risk register, timeline |
| `docs/CQR-TECHNICAL-SPEC.md` | **Historical** — V0.1 March 2026 draft, written before the SEQUR→CQR rename and the ASSERT/HYPOTHESIZE/COMPARE/ANCHOR additions. Superseded by `README.md`. Kept for patent-evidence continuity. |
| `docs/VALIDATION-SUITE.md` | MVP1 validation suite spec, 100-intent corpus design, scoring engine |

When working on a specific phase, read the relevant spec doc for full task details, exit criteria, and implementation notes.

---

## 14. Key Terminology

| Term | Meaning |
|---|---|
| **Cognitive operation primitive** | A CQR keyword (RESOLVE, DISCOVER, etc.) that maps to a reasoning pattern, not a data operation |
| **Agent generation contract** | The three-component system prompt that enables LLMs to generate CQR expressions |
| **Active schema** | The LLM-readable representation of available entities, scopes, and relationships |
| **Scope-first semantics** | Scope determines visibility before any data retrieval occurs |
| **Quality metadata envelope** | Mandatory provenance/freshness/confidence/reputation data on every response |
| **Adapter behaviour** | The Elixir behaviour contract that storage backends implement |
| **Governance invariance** | The principle that governance enforcement happens at the engine level, below all delivery interfaces |
| **Conflict preservation** | When multiple adapters return different data for the same entity, return ALL results with source attribution — don't pick one |
| **Informative error semantics** | Errors tell the agent what went wrong, why, and what to try next |
| **Genuine invisibility** | Out-of-scope entities return not_found, not access_denied — the entity doesn't exist from the agent's perspective |
