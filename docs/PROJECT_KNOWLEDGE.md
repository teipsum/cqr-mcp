# PROJECT_KNOWLEDGE.md

> **Read this file at the start of every Claude Code session.** It contains everything you need to understand the project, the architecture, and the current state. If you need deeper detail on a specific area, the referenced spec documents in `/docs` have the full specifications.

---

## 1. What Is CQR

CQR (Semantic Query Resolution) is a declarative query language designed for machine cognition as the primary consumer. It enables AI agents to interact with organizational context across heterogeneous storage backends through cognitive operation primitives rather than data manipulation primitives.

**The core insight:** Existing query languages (SQL, GraphQL, SPARQL, Cypher) are designed for human developers. When AI agents use them, they do so through pre-coded tool calls. CQR flips this — the agent generates the query expression from natural language intent, and the language's primitives correspond to reasoning patterns (resolve a concept, orient in a neighborhood, trace causality, assess quality, participate in governance) rather than data operations (select, join, filter).

**Protocol positioning:** MCP = agent-to-tool, A2A = agent-to-agent, CQR = agent-to-governed-context. CQR is the governance layer above MCP and A2A in the agent protocol stack.

**Patent:** A provisional patent application covering 61 claims across 4 independent claims has been prepared. Claims cover the query language, agent generation contract, adapter architecture, multi-agent runtime, human-agent coupling, personal cognitive metadata, resource governance, activity visibility, and context contamination prevention. Priority date must be locked before July 2026.

---

## 2. What This Repo Is

`cqr_mcp` is a standalone Elixir/OTP application that:

1. Embeds Grafeo (pure-Rust graph database) via Rustler NIF — no external database required
2. Implements the CQR parser, context assembly engine, and scope resolution
3. Exposes CQR primitives as MCP tools (`cqr_resolve`, `cqr_discover`, `cqr_certify`)
4. Exposes organizational context as MCP resources (scopes, entities, policies, system prompt)
5. Accepts connections from any MCP client (Claude Desktop, Cursor, VS Code, custom agents)
6. Enforces scope-first governance on every query
7. Returns quality-annotated context with mandatory metadata envelope
8. Runs as a single OS process on commodity hardware with zero external dependencies

**License:** MIT (open source)

**What is NOT in this repo:** Multi-agent runtime (agent taxonomy, co-sponsorship, permission intersection), human-agent coupling management, lease-based resource governance, context contamination prevention, COMPARE/HYPOTHESIZE/ANCHOR primitives. These are UNICA commercial platform features (separate repo, proprietary).

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

## 4. CQR Primitives (V1 Scope)

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
  ANNOTATE freshness, reputation, owner
```

### CERTIFY — Governance Workflow
Manages definition lifecycle through proposal, review, and certification phases.

```
CERTIFY entity:finance:arr
  STATUS proposed
  AUTHORITY cfo
  EVIDENCE "Validated against Q4 actuals"
```

Statuses: proposed → under_review → certified → superseded

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
           (sp annotate_clause)? (sp limit_clause)?
related_clause <- 'RELATED' sp 'TO' sp (entity / string_literal)
within_clause <- 'WITHIN' sp scope (',' sp scope)*
depth_clause <- 'DEPTH' sp integer
annotate_clause <- 'ANNOTATE' sp annotation_list
limit_clause <- 'LIMIT' sp integer

certify <- 'CERTIFY' sp entity sp status_clause
           (sp authority_clause)? (sp supersedes_clause)?
           (sp certify_evidence)?
status_clause <- 'STATUS' sp certify_status
certify_status <- 'proposed' / 'under_review' / 'certified' / 'superseded'
authority_clause <- 'AUTHORITY' sp identifier
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
- Scope traversal follows: agent's active scope → parent scopes → fallback chain
- If an entity is not in the agent's accessible scope, it does not exist from that agent's perspective (genuine invisibility, not access denied)
- Scope resolution is cached in ETS for sub-millisecond lookup

---

## 8. MCP Server Interface

### Tools

```
cqr_resolve:
  input: {intent, entity?, scope?, freshness?, reputation?}
  output: governed context with quality metadata envelope

cqr_discover:
  input: {topic, scope?, depth?}
  output: neighborhood map with relationship types and quality annotations

cqr_certify:
  input: {definition, action: propose|review|approve, evidence?, scope?}
  output: certification status with provenance chain
```

### Resources

```
cqr://scopes          — Organizational scope hierarchy
cqr://entities        — Entity definitions with metadata
cqr://policies        — Governance rules per scope
cqr://system_prompt   — CQR agent generation contract
```

### Transports

- **stdio** (primary): for Claude Desktop, Claude Code, Cursor
- **SSE** (secondary): for remote/HTTP connections via Plug/Bandit

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

Detailed specifications are in `/docs`:

| Document | Contains |
|---|---|
| `docs/MCP-SERVER-PLAN.md` | Full phased build plan (Phases 0-6), risk register, timeline |
| `docs/MVP2-DEVELOPER-TOOLS.md` | Developer tooling spec (Playground, Schema Builder, Governance Explorer, Generation Lab, Integration Console) |
| `docs/CQR-TECHNICAL-SPEC.md` | Protocol specification, all 10 primitives, grammar, implementation notes |
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
