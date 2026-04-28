# CQR MCP Server — Open Release Project Plan

**Product:** `cqr_mcp` — An Elixir/OTP MCP server exposing governed context resolution to any MCP-compatible AI agent  
**License:** MIT  
**Developer:** Michael Lewis Cram (solo, with Claude Code)  
**Hardware:** M5 Pro MacBook, 24GB unified memory, Starlink  
**Start date:** Week of April 14, 2026  

---

## Architecture Decision: Embedded Grafeo

Grafeo is a pure-Rust embeddable graph database (Apache 2.0, v0.5.34) that supports LPG + RDF, GQL + Cypher + Gremlin + SPARQL + SQL/PGQ query languages, HNSW vector search with quantization, BM25 full-text search, and ACID transactions with MVCC snapshot isolation. It runs embedded as a library or standalone as a server.

**This project embeds Grafeo directly into the BEAM via a Rustler NIF.** No separate database container. No Docker Compose orchestration. No network latency between engine and storage. The database starts with the OTP application and lives inside the supervision tree.

This decision is driven by three constraints:

1. **Developer experience.** `mix deps.get && mix run` must be the entire setup. A separate container means Docker knowledge, port conflicts, startup ordering, and a "why isn't it connecting" debug session that kills the 10-minute promise.
2. **Deployment model.** The patent describes a self-contained appliance on commodity hardware. Embedded Grafeo makes this literal — one OS process, one binary, full stack.
3. **Performance.** The POC validated sub-millisecond scope traversal. Embedding eliminates the ~1-3ms network round-trip per query that a containerized database adds. For a protocol where every response requires scope resolution before content retrieval, this compounds.

**Integration path:** Grafeo exposes a C FFI. Rustler is the standard Rust-to-Elixir NIF bridge (used by Explorer/Polars, ExLA, and other production Elixir libraries). The NIF surface is minimal — four functions: `new/1`, `execute/2`, `close/1`, `health_check/0`. Everything else stays in Elixir. Precompiled binaries via `rustler_precompiled` eliminate the need for users to install a Rust toolchain.

---

## What Exists Today

Before planning what to build, here's an honest accounting of what's already working and what isn't.

**Working and validated:**

- NimbleParsec parser for RESOLVE and DISCOVER primitives (~20 parser tests passing)
- Cqr.Engine with Task.async_stream fan-out across adapters
- Adapter behaviour contract: `resolve/3`, `discover/3`, `normalize/2`, `health_check/0`
- PostgreSQL/pgvector adapter (relational + vector similarity)
- Neo4j adapter (Cypher graph traversal)
- Grafeo validation: 19/20 tests passed, scope-aware governance filtering confirmed, GQL + Cypher multi-paradigm query composition working, vector storage as node properties confirmed
- Teipsum Agent (GenServer) with multi-step reasoning loop (DISCOVER → rank → RESOLVE → synthesize)
- 55 ExUnit tests across parser, integration, engine, and agent modules
- Validation suite infrastructure: 100-intent corpus, runner GenServer, Phoenix LiveView dashboard at /validation
- Best validation results: 97%/96% syntactic/semantic accuracy on qwen2.5:14b
- Phoenix LiveView interface (POC quality)
- GPG-signed patent evidence chain

**Working but needs rework for open release:**

- Parser covers 7 of 10 primitives (RESOLVE, DISCOVER, TRACE, REFRESH, SIGNAL, CERTIFY, AWARENESS). COMPARE, HYPOTHESIZE, ANCHOR are specified in the patent but not yet implemented in the parser.
- Adapter implementations are coupled to the POC's data model and schema. Need to be generalized for arbitrary organizational data.
- Scope hierarchy is hardcoded in test fixtures. Needs to be dynamic and configurable.
- Quality metadata envelope is partially implemented — freshness and reputation are there, confidence and lineage are stubs.
- Error semantics are basic Elixir exceptions, not the informative error envelopes specified in the patent.
- No MCP transport layer exists yet. The protocol is defined in the patent but not implemented.

**Not yet built:**

- MCP server (JSON-RPC 2.0 transport, tool registration, resource exposure)
- Rustler NIF wrapping Grafeo's embedded engine
- Grafeo adapter (replacing Postgres + Neo4j with single embedded backend)
- README, documentation, architecture diagrams
- GitHub repository structure, CI, release pipeline
- Sample organizational dataset for demo/quickstart
- LLM system prompt for CQR generation (exists as internal notes but not packaged)

---

## What We're Building

A standalone Elixir/OTP application that:

1. Starts an embedded Grafeo database (in-memory or persistent) and seeds it with a sample organizational dataset on first boot
2. Exposes three MCP tools (`cqr_resolve`, `cqr_discover`, `cqr_certify`) and MCP resources (scope hierarchy, strategic vectors, governance policies)
3. Accepts connections from any MCP client (Claude Desktop, Cursor, VS Code, custom agents)
4. Enforces scope-first governance on every query
5. Returns quality-annotated context with mandatory metadata envelope
6. Runs as a single OS process with zero external dependencies

**What we are NOT building in this release:**

- Multi-agent runtime (agent taxonomy, co-sponsorship, permission intersection)
- Human-agent coupling management
- Lease-based resource governance
- Context contamination prevention
- Agent Monitor, Agent Portfolio, Agent Studio
- Multi-tenant isolation (single-tenant only for open release)
- COMPARE, HYPOTHESIZE, ANCHOR primitives (V2)

---

## Development Philosophy for Claude Code Sessions

These are hard-won patterns from the POC build. Follow them.

- **1-2 step prompt chunks.** Don't ask Claude Code to build an entire module in one shot. Ask it to build the struct, then the parser, then the tests, then the integration. Commit after each.
- **Bootstrap every session** by having Claude Code read `PROJECT_KNOWLEDGE.md` and the relevant spec doc. It forgets everything between sessions.
- **Commit after every milestone.** Signed commits (`git commit -S`). This is patent evidence, not just version control.
- **Run `mix test --trace` after every prompt.** Catch regressions immediately, not three sessions later.
- **If Claude Code stalls** (tokens flat for 5+ minutes), kill and restart with the next prompt. Don't waste time debugging the tool.
- **Every capability ships with tests AND documentation.** No deferred work. If it's not tested and documented, it doesn't exist.

---

## Phase 0: Project Scaffolding + Grafeo NIF (Days 1-3)

**Goal:** Clean Elixir project with embedded Grafeo compiling and responding to queries. This phase is longer than a typical scaffolding phase because the Rustler NIF is the highest-risk item in the entire project — get it working first.

### Tasks

1. **Create new mix project** — `cqr_mcp`. Not a fork of the POC. Start clean, pull in the modules that have earned their place.
   - `mix new cqr_mcp --sup`
   - OTP application with supervision tree
   - Directory structure:
     ```
     lib/
       cqr/
         parser.ex             # NimbleParsec grammar
         parser/
           resolve.ex           # RESOLVE-specific combinators
           discover.ex
           certify.ex
         engine.ex              # Context Assembly Engine
         scope.ex               # Scope hierarchy + resolution
         quality.ex             # Quality metadata envelope
         error.ex               # Informative error semantics
       cqr_mcp/
         server.ex              # MCP JSON-RPC transport
         tools.ex               # Tool definitions (resolve, discover, certify)
         resources.ex           # Resource definitions (scopes, policies)
         handler.ex             # Request routing + response formatting
       adapter/
         behaviour.ex           # Adapter behaviour contract
         grafeo.ex              # Grafeo adapter (calls NIF)
       grafeo/
         native.ex              # Rustler NIF module — Elixir interface to embedded Grafeo
       repo/
         semantic.ex            # Semantic Definition Repository (queries via Grafeo adapter)
         scope_tree.ex          # Scope hierarchy management (ETS cache + Grafeo backing)
         seed.ex                # Sample data seeder
     native/
       cqr_grafeo/
         Cargo.toml             # Rust crate: depends on grafeo (embedded profile) + rustler
         src/
           lib.rs               # NIF functions: new, execute, close, health_check
     ```

2. **Rustler NIF — `native/cqr_grafeo/`:**

   This is the critical path item. The Rust crate wraps Grafeo's embedded API and exposes four functions to Elixir:

   ```rust
   // Cargo.toml
   [dependencies]
   grafeo = { version = "0.5", default-features = false, features = ["gql", "ai"] }
   rustler = "0.34"
   ```

   ```rust
   // src/lib.rs — the entire Rust surface area
   use grafeo::GrafeoDB;
   use rustler::{Env, Term, NifResult};

   // ResourceArc wrapping the database handle
   // new(path) -> opens/creates persistent DB, new(:memory) -> in-memory
   // execute(db, query_string) -> returns rows as list of maps
   // close(db) -> closes database
   // health_check(db) -> returns {:ok, version} or {:error, reason}
   ```

   The Elixir module `Cqr.Grafeo.Native` wraps these NIFs with Elixir-friendly interfaces:
   ```elixir
   defmodule Cqr.Grafeo.Native do
     use Rustler, otp_app: :cqr_mcp, crate: "cqr_grafeo"

     def new(_path), do: :erlang.nif_error(:nif_not_loaded)
     def execute(_db, _query), do: :erlang.nif_error(:nif_not_loaded)
     def close(_db), do: :erlang.nif_error(:nif_not_loaded)
     def health_check(_db), do: :erlang.nif_error(:nif_not_loaded)
   end
   ```

3. **Grafeo GenServer** — `Cqr.Grafeo.Server`:
   - A GenServer that owns the Grafeo database handle (ResourceArc)
   - Starts in the supervision tree, opens the database on init
   - Provides `query/1` as the public API — serializes access to the NIF
   - On first start with empty database, runs the seeder
   - Configurable: `:memory` for tests, file path for persistence

4. **Smoke test:** Before anything else, prove the NIF works:
   ```elixir
   test "grafeo embedded smoke test" do
     {:ok, db} = Cqr.Grafeo.Native.new(:memory)
     :ok = Cqr.Grafeo.Native.execute(db, "INSERT (:Test {name: 'hello'})")
     {:ok, rows} = Cqr.Grafeo.Native.execute(db, "MATCH (t:Test) RETURN t.name")
     assert rows == [%{"t.name" => "hello"}]
   end
   ```

5. **mix.exs dependencies** — Pin versions now:
   - `rustler` ~> 0.34 — Rust NIF bridge
   - `rustler_precompiled` ~> 0.8 — precompiled binary support
   - `nimble_parsec` ~> 1.4 — parser combinators
   - `jason` ~> 1.4 — JSON encoding/decoding
   - `plug` ~> 1.16 + `bandit` ~> 1.6 — HTTP server for MCP SSE transport
   - `ex_doc` ~> 0.34 — documentation

6. **PROJECT_KNOWLEDGE.md** — The document Claude Code reads at the start of every session. Architecture decisions, naming conventions, module responsibilities, what's in scope and what's not. Include the embedded Grafeo decision and the NIF boundary.

7. **GitHub repo setup:**
   - MIT LICENSE
   - .gitignore (Elixir standard + _build, deps, .env, native/cqr_grafeo/target/)
   - GitHub Actions CI: install Rust toolchain, `mix test`, `mix format --check-formatted`
   - Branch protection on `main`

### Exit criteria
- `mix test` passes with at least the Grafeo smoke test
- Grafeo embedded starts in-memory, accepts GQL/Cypher queries, returns results via NIF
- No external processes, no Docker, no network — just `mix test`
- First signed commit on `main`

### Risk mitigation
The NIF is the highest-risk item. If Rustler + Grafeo doesn't compile cleanly on ARM macOS within day 1, evaluate fallback options immediately:
- **Fallback A:** Use Grafeo's C FFI directly with `:erlang.load_nif/2` (bypasses Rustler, more manual)
- **Fallback B:** Wrap Grafeo as an Elixir Port — compile the Grafeo CLI binary, communicate over stdin/stdout (adds IPC overhead but eliminates NIF risk entirely)
- **Fallback C:** Start with an in-process Elixir graph (ETS-backed, no Rust) for the open release, add Grafeo NIF in V1.1. This sacrifices the multi-paradigm query composition but preserves the zero-dependency developer experience.

Do NOT spend more than 1.5 days on NIF issues before switching to a fallback. The protocol and governance semantics are the product, not the storage engine.

---

## Phase 1: Parser & Core Types (Days 4-8)

**Goal:** The CQR parser handles RESOLVE, DISCOVER, and CERTIFY with full clause support, producing clean AST structs. This is a port and refinement from the POC, not a rewrite.

### Tasks

1. **Define AST structs:**
   ```elixir
   %Cqr.Resolve{entity: _, scope: _, freshness: _, reputation: _, include: _, fallback: _}
   %Cqr.Discover{related_to: _, within: _, depth: _, annotate: _, limit: _}
   %Cqr.Certify{definition: _, proposed_by: _, reviewed_by: _, approved_by: _, scope: _, supersedes: _}
   ```

2. **Port the NimbleParsec grammar** from the POC. The POC parser handles RESOLVE and DISCOVER. Extend to CERTIFY. Key requirements:
   - Order-insensitive optional clauses (this was working in the POC)
   - Informative parse errors with position and expected tokens
   - Unicode arrow (→) and ASCII arrow (->) both accepted in FALLBACK

3. **Core types module** — `Cqr.Types`:
   - Entity: `{namespace, name}` tuple with validation
   - Scope: list of segments with hierarchy helpers (`parent/1`, `ancestors/1`, `child?/2`)
   - Duration: `{integer, unit}` with conversion helpers
   - Score: float 0.0-1.0 with validation
   - Quality metadata struct: `%{freshness: _, confidence: _, reputation: _, provenance: _, lineage: _, owner: _}`

4. **Quality metadata envelope** — `Cqr.Quality`:
   - Every CQR response wraps results in a quality envelope
   - This is non-optional. The envelope is always present, even if some fields are `:unknown`
   - Struct: `%Cqr.Quality{freshness: DateTime, confidence: float, reputation: float, provenance: String, lineage: [String], owner: String}`

5. **Informative error module** — `Cqr.Error`:
   - Parse errors: position, expected tokens, partial parse result
   - Resolution errors: entity not found, scope not accessible, adapter timeout
   - Every error includes: `similar_entities`, `partial_results`, `retry_guidance`
   - Errors are structs, not exceptions. They're data for agents to reason over.

6. **Test suite:** One test file per module. Aim for 80+ parser tests covering:
   - All valid RESOLVE variants (minimal, full, fallback chains, multiple WITH clauses)
   - All valid DISCOVER variants
   - All valid CERTIFY variants
   - Clause ordering permutations (the order-insensitive property)
   - Parse failure cases with informative error messages
   - Edge cases from the POC validation failures (double-entity anchors, search terms instead of entity references)

### Exit criteria
- `Cqr.Parser.parse/1` handles all three primitives
- Error messages include position and expected tokens
- 80+ tests passing
- `mix docs` generates clean documentation for all public functions

---

## Phase 2: Scope Engine & Semantic Repository (Days 9-13)

**Goal:** Scope hierarchy is dynamic, queryable, and enforced. The Semantic Definition Repository holds entities, scopes, and relationships in the embedded Grafeo instance.

### Tasks

1. **Scope hierarchy engine** — `Cqr.Scope`:
   - Load scope tree from embedded Grafeo on application start
   - `visible_scopes/1` — given an agent's scope, return all accessible scopes (self + ancestors + descendants; siblings remain isolated)
   - `authoritative_scope/2` — given an entity and a requesting scope, return the nearest scope that contains the entity
   - `fallback_chain/2` — given an explicit fallback list, validate each scope exists and return the resolution order
   - Cache scope tree in ETS for sub-millisecond lookups (already validated as working in POC)
   - Subscribe to Grafeo changes (via CERTIFY operations) to invalidate cache when scope hierarchy is modified

2. **Semantic Definition Repository** — `Cqr.Repo.Semantic`:
   - Entity registration: namespace, name, type, description, adapter mappings, scope assignments, owner, certification status
   - Relationship metadata: typed relationships (CORRELATES_WITH, CAUSES, CONTRIBUTES_TO, DEPENDS_ON, PART_OF) with directionality and strength scores
   - Backed by embedded Grafeo — entities are nodes, relationships are edges, scopes are hierarchical nodes
   - Query methods: `get_entity/2`, `entities_in_scope/1`, `related_entities/3`, `entity_exists?/1`
   - All queries go through `Cqr.Grafeo.Server.query/1` — single serialized access point to the NIF

3. **Grafeo adapter** — `Cqr.Adapter.Grafeo`:
   - Implement the adapter behaviour: `resolve/3`, `discover/3`, `normalize/2`, `health_check/0`
   - `resolve/3`: Cypher/GQL query to find entity by namespace:name within accessible scopes, return with quality metadata from node properties. The scope constraint is part of the query, not a post-filter.
   - `discover/3`: Graph traversal from anchor entity through typed relationships, with depth limit, within accessible scopes. Combine with vector similarity if embeddings are present on entity nodes.
   - `normalize/2`: Transform Grafeo query results into `%Cqr.Result{}` with quality envelope
   - `health_check/0`: Call `Cqr.Grafeo.Native.health_check/1`, return version and status
   - Handle the Grafeo v0.5 cosine similarity gap: compute similarity in Elixir if Grafeo's inline computation isn't available (already validated in POC)

4. **Sample dataset seeder** — `Cqr.Repo.Seed`:
   - A realistic but minimal organizational dataset, seeded on first boot when Grafeo is empty:
     - Scope tree: `scope:company` → `scope:company:engineering`, `scope:company:finance`, `scope:company:product` → team-level scopes
     - ~30 entities across finance (ARR, MRR, churn_rate, burn_rate), engineering (deploy_frequency, mttr, incident_rate), product (NPS, DAU, feature_adoption), HR (headcount, attrition_rate, eNPS)
     - Typed relationships between entities (churn_rate CORRELATES_WITH NPS, attrition_rate CAUSES operating_expenses increase, etc.)
     - Quality metadata on each entity (freshness timestamps, reputation scores, owners)
     - Vector embeddings on entity descriptions (pre-computed and stored as node properties)
   - Seeder is idempotent — checks for existing data before inserting
   - Seeder runs as part of `Cqr.Grafeo.Server.init/1` when the database is empty

5. **Integration tests:**
   - Resolve entity within scope → returns with quality envelope
   - Resolve entity outside scope → returns scope access error with similar entities suggestion
   - Resolve with fallback chain → walks chain until entity found
   - Discover related to entity → returns neighborhood with relationship types
   - Discover with depth limit → respects depth
   - Scope hierarchy enforcement → child scope cannot see sibling scope entities
   - All integration tests run against the embedded Grafeo instance — no external services needed

### Exit criteria
- Application starts with embedded Grafeo, seeds sample data on first boot
- Scope resolution returns correct results with governance enforcement
- All integration tests pass — `mix test` with zero external dependencies
- Sub-millisecond scope lookups confirmed (ETS cache)

---

## Phase 3: Context Assembly Engine (Days 14-18)

**Goal:** The engine parses CQR expressions, plans execution, fans out to adapters, merges results with conflict preservation, and returns quality-annotated responses.

### Tasks

1. **Engine core** — `Cqr.Engine`:
   - `execute/2` — takes a CQR expression string and an agent context (scope, identity), returns `{:ok, %Cqr.Result{}}` or `{:error, %Cqr.Error{}}`
   - Pipeline: parse → validate scope access → plan adapter fan-out → execute concurrently → normalize → merge → annotate quality → return
   - `execute/2` is the single entry point. Everything above it (MCP server, REST API, direct call) goes through here. This is the governance invariance boundary.

2. **Query planner** — `Cqr.Engine.Planner`:
   - Given a parsed AST and scope context, determine which adapters to query
   - For RESOLVE: look up entity → adapter mapping in semantic repository, filter to accessible scopes
   - For DISCOVER: determine which adapters support graph traversal vs. vector similarity, plan parallel execution
   - For CERTIFY: route to the governance write path (adapter + audit trail)
   - In V1 there is only one adapter (Grafeo), but the planner must support multiple adapters architecturally — this is the fan-out point that makes adding PostgreSQL or Neo4j adapters later a configuration change, not a code change

3. **Result merging with conflict preservation:**
   - When multiple adapters return results for the same entity, DO NOT pick one. Return all with source attribution.
   - `%Cqr.Result{data: [...], sources: [...], conflicts: [...], quality: %Cqr.Quality{}, cost: %Cqr.Cost{}}`
   - Conflicts are explicitly surfaced so the consuming agent can reason over disagreements
   - In V1 with a single adapter, conflicts can still arise from scope fallback chains (entity exists in multiple scopes with different values)

4. **Cost accounting** — `Cqr.Cost`:
   - Track per-query: adapters queried, context operations consumed, execution time per adapter
   - Return cost in every response: `%Cqr.Cost{adapters_queried: 1, operations: 3, execution_ms: 47}`
   - This is the foundation for the organizational budget model (not implemented in open release, but the data is captured)

5. **CERTIFY execution path:**
   - Three-phase workflow: PROPOSED → REVIEWED → APPROVED
   - `cqr_certify` writes a governance record into embedded Grafeo with proposer, reviewer, approver, timestamp, and scope
   - Open release supports the full workflow but with simplified authorization (any authenticated agent can propose; approval requires explicit `authority:` designation in the seed data)
   - Each CERTIFY operation is also an event that can trigger scope tree cache invalidation

6. **Tests:**
   - Full parse-to-result integration tests for each primitive
   - Multi-adapter fan-out mechanism (even with single adapter, test the planner's multi-adapter path with a mock second adapter)
   - Conflict preservation when two result paths return different data
   - Cost accounting accuracy
   - CERTIFY workflow: propose → review → approve → verify status change in Grafeo
   - Error paths: invalid entity, inaccessible scope, adapter timeout
   - All tests run in-process — `mix test` with zero external dependencies

### Exit criteria
- `Cqr.Engine.execute/2` handles RESOLVE, DISCOVER, CERTIFY end-to-end
- Quality envelope present on every response
- Cost accounting present on every response
- Conflict preservation demonstrated in tests
- CERTIFY workflow working with audit trail in embedded Grafeo

---

## Phase 4: MCP Server (Days 19-26)

**Goal:** A standards-compliant MCP server that any MCP client can connect to and immediately access governed organizational context.

### Tasks

1. **MCP transport layer** — `CqrMcp.Server`:
   - Implement MCP over stdio transport (Claude Desktop, Claude Code, Cursor all support this) — this is the primary transport for local MCP servers
   - Also implement SSE transport via Plug/Bandit for remote connections
   - JSON-RPC 2.0 message handling: parse request, route to handler, format response
   - MCP lifecycle: `initialize` → `initialized` → tool/resource calls
   - Evaluate existing Elixir MCP libraries first. If one exists and is mature, use it. If not, implement the transport directly — it's a thin layer over JSON-RPC 2.0, well within scope.

2. **Tool definitions** — `CqrMcp.Tools`:
   ```
   cqr_resolve:
     description: "Resolve a canonical entity by semantic address
                   from governed organizational context"
     input_schema:
       entity: string (required) — entity reference (entity:namespace:name)
       scope: string (optional) — scope constraint (scope:seg1:seg2)
       freshness: string (optional) — freshness requirement (e.g., "24h")
       reputation: float (optional) — minimum reputation threshold
     output: governed context with quality metadata envelope

   cqr_discover:
     description: "Discover concepts related to an entity or topic
                   within governed organizational context"
     input_schema:
       topic: string (required) — entity reference or plain search term
       scope: string (optional) — scope constraint (comma-separated for multiple)
       depth: integer (optional, default 2) — traversal depth
       direction: enum [outbound, inbound, both] (optional, default both)
     output: neighborhood map with relationship types, direction tags
             ("outbound" | "inbound"), and quality annotations
     notes: edges are stored once, directionally; the relationship type
            always reads in its original stored direction

   cqr_certify:
     description: "Propose, review, or approve a governance definition
                   in the organizational context"
     input_schema:
       entity: string (required) — entity reference
       status: enum [proposed, under_review, certified, superseded] (required)
       authority: string (optional) — bare identifier (cfo) or quoted
                  free-form string (e.g., "agent:twin:michael") allowing
                  colons in opaque authority IDs
       evidence: string (optional) — supporting evidence
     output: certification status with provenance chain
   ```

   **V2 primitives planned:** ASSERT, TRACE, HYPOTHESIZE, COMPARE, ANCHOR, SIGNAL, REFRESH, AWARENESS. ASSERT is the next primitive scheduled to land — see `specs/Assert primitive specification.md`. The full canonical protocol is in `README.md` at the repository root.

3. **Resource definitions** — `CqrMcp.Resources`:
   ```
   cqr://session       — Current agent identity and connection context.
                          Returns: agent_id (CQR_AGENT_ID env), agent_scope
                          (CQR_AGENT_SCOPE env), visible_scopes (full
                          bidirectional set), permissions, connected_adapters,
                          server_version, protocol ("CQR/1.0"), uptime_seconds,
                          connection { transport, connected_at, session_id (UUIDv4) }
   cqr://scopes        — Organizational scope hierarchy with visibility rules
   cqr://entities      — Entity definitions with namespace, type, scope, certification status
   cqr://policies      — Governance rules, freshness requirements, reputation thresholds per scope
   cqr://system_prompt — CQR agent generation contract for LLM CQR generation
   ```

4. **Agent context extraction:**
   - For V1: accept scope as a configuration parameter (`CQR_AGENT_SCOPE=scope:company:engineering`) or in MCP client metadata
   - Document the identity model clearly so enterprise users understand the extension point

5. **LLM system prompt packaging:**
   - The agent generation contract — the system prompt structure that enables LLMs to generate CQR expressions from natural language
   - Package as both an MCP resource (`cqr://system_prompt`) and a static file in the repo
   - Include: grammar summary, entity schema, few-shot examples, error handling guidance

6. **Tests:**
   - MCP lifecycle tests: initialize → tools/list → tools/call → response
   - Each tool: valid call → correct result with quality envelope
   - Each tool: invalid call → informative error
   - Resource retrieval tests
   - Stdio transport: stdin/stdout message exchange (mock stdio for testing)
   - SSE transport: HTTP connection, event framing, keepalive

### Exit criteria
- Claude Desktop can connect to the MCP server via stdio and call all three tools
- SSE transport works for remote connections
- Resources are browsable (scopes, entities, policies, system prompt)
- Quality metadata present on every tool response
- Both transports working and tested

---

## Phase 5: Demo, Documentation & Packaging (Days 27-33)

**Goal:** A developer can go from `git clone` to a working CQR MCP server connected to Claude in under 10 minutes. No Docker required.

### Tasks

1. **README.md** — The most important file in the repo:
   - One-paragraph description: what CQR is, what problem it solves, what this repo contains
   - Quickstart (the entire thing):
     ```bash
     git clone https://github.com/teipsum/cqr_mcp
     cd cqr_mcp
     mix deps.get
     mix run --no-halt
     # CQR MCP server running on stdio — connect Claude Desktop
     ```
   - Architecture diagram (Mermaid or SVG): Agent → MCP Client → CQR MCP Server → Engine → Embedded Grafeo
   - License (BSL 1.1, converts to MIT)

2. **ARCHITECTURE.md:**
   - Module dependency diagram
   - Data flow: natural language → CQR expression → parse → scope resolution → adapter fan-out → result merge → quality annotation → MCP response
   - The governance invariance principle — why governance enforcement happens at the engine level, below all delivery interfaces
   - The embedded Grafeo decision — why the database runs inside the BEAM, how the NIF boundary works, and what this means for performance and deployment
   - Adapter behaviour contract — how to write a new adapter

3. **ADAPTERS.md:**
   - How the adapter behaviour works
   - Reference Grafeo adapter walkthrough
   - Guide: "Write your own adapter for PostgreSQL/Neo4j/Elasticsearch in 30 minutes"
   - Clarification: the Grafeo adapter uses the embedded NIF. External adapters (Postgres, Neo4j) would use network clients. Both implement the same behaviour contract.

4. **Claude Desktop configuration:**
   ```json
   {
     "mcpServers": {
       "cqr": {
         "command": "mix",
         "args": ["run", "--no-halt"],
         "cwd": "/path/to/cqr_mcp",
         "env": {
           "CQR_AGENT_SCOPE": "scope:company:engineering"
         }
       }
     }
   }
   ```

5. **Demo script / video script:**
   - Connect Claude Desktop to CQR
   - "What's our current ARR?" → RESOLVE with quality metadata
   - "What data do we have related to customer churn?" → DISCOVER with neighborhood map
   - "The NPS data seems outdated" → CERTIFY workflow initiation
   - "I don't trust the finance team's ARR number, fall back to product's version" → RESOLVE with fallback chain and conflict surfacing
   - Show the quality envelope, the scope enforcement, the cost accounting

6. **hex.pm package preparation:**
   - Precompiled NIF binaries for macOS ARM, macOS x86, Linux x86 (via `rustler_precompiled`)
   - Package description, metadata, docs link

7. **Docker image** (optional convenience, not required):
   - Single-container multi-stage build: Rust compile → Elixir release → Alpine runtime
   - Final image includes compiled BEAM release with Grafeo NIF baked in
   - `docker run teipsum/cqr_mcp` — single container, no compose, no orchestration

### Exit criteria
- Clone, `mix deps.get`, `mix run --no-halt`, connect Claude, query — under 10 minutes
- No Docker, no external database, no network configuration required for development
- Documentation is complete and accurate
- Precompiled NIF binaries available for macOS ARM + Linux x86
- Demo script produces the expected results every time

---

## Phase 6: Launch Preparation (Days 34-37)

**Goal:** The repo is public, discoverable, and positioned to generate the right conversations.

### Tasks

1. **GitHub repository polish:**
   - Topics: `mcp`, `ai-agents`, `governance`, `elixir`, `context`, `cqr`, `embedded-database`
   - Social preview image
   - Releases: v0.1.0 with changelog and precompiled NIF binaries as release assets
   - Issue templates: bug report, feature request, adapter contribution
   - Contributing guide (including Rust toolchain setup for NIF development)

2. **Launch content:**
   - Blog post / technical article: "Why AI Agents Need a Query Language for Governed Context" (for LinkedIn, Hacker News, Elixir Forum)
   - Not a product announcement. A problem statement with CQR as the existence proof.
   - Architecture-focused, not sales-focused. Show the gap, show the solution, link to the repo.
   - Mention the embedded Grafeo + Elixir/OTP architecture — the Elixir and Rust communities will find this technically interesting independent of the AI governance angle.

3. **Community seeding:**
   - Elixir Forum post (the Rustler NIF angle will resonate with this community)
   - MCP community channels (Discord, GitHub discussions)
   - LinkedIn post to personal network (former Walmart, EPAM contacts)
   - Consider a Grafeo community post — this would be a novel Elixir integration

4. **Monitoring:**
   - GitHub stars, forks, clones
   - Issues and discussions
   - MCP ecosystem directory listing (if the MCP Registry exists by then)

---

## Timeline Summary

| Phase | Days | Calendar (from April 14) | Deliverable |
|---|---|---|---|
| **0: Scaffolding + NIF** | 1-3 | Apr 14-16 | Project structure, Rustler NIF compiling, embedded Grafeo queried from Elixir |
| **1: Parser & Types** | 4-8 | Apr 17-23 | RESOLVE/DISCOVER/CERTIFY parser, core types, informative errors |
| **2: Scope & Repository** | 9-13 | Apr 24-30 | Scope engine, Grafeo adapter, seed data, ETS cache |
| **3: Engine** | 14-18 | May 1-7 | Context Assembly Engine, conflict preservation, cost accounting |
| **4: MCP Server** | 19-26 | May 8-19 | MCP transport (stdio + SSE), tools, resources, system prompt |
| **5: Docs & Packaging** | 27-33 | May 20-28 | README, architecture docs, precompiled NIFs, demo |
| **6: Launch** | 34-37 | May 29-Jun 2 | Public repo, blog post, community seeding |

**Total: ~5.5 weeks from start to public launch.**

One day longer than the container-based plan. The extra time is in Phase 0 for the NIF work — but it pays for itself by eliminating Docker Compose from every subsequent phase and from the developer experience permanently.

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **Rustler + Grafeo NIF doesn't compile on ARM macOS** | Medium | High | Budget 1.5 days. If it fails: Fallback A (C FFI direct), Fallback B (Elixir Port), Fallback C (ETS-only graph for V1). Decision by end of day 2. |
| **Grafeo embedded API differs from Docker/server API** | Low | Medium | Grafeo's embedded and server modes use the same query engine. Validated in POC that GQL + Cypher work. NIF wraps `db.execute(query)`. |
| **Precompiled NIF binaries fail on some platforms** | Medium | Medium | `rustler_precompiled` handles this. If specific platforms fail, document "install Rust toolchain" as fallback. |
| **NIF crash takes down the BEAM** | Low | High | Grafeo is pure Rust with no unsafe FFI dependencies. Add Rustler `schedule: :dirty_io` for long queries. Monitor in testing. |
| **MCP Elixir library doesn't exist** | Medium | Low | MCP is JSON-RPC 2.0 over stdio/SSE. Implement directly — ~300 lines of transport code. |
| **Parser port takes longer than expected** | Low | Medium | The POC parser works. This is a port, not a rewrite. Budget an extra day. |
| **Claude Code productivity variance** | Medium | Medium | Keep prompts small (1-2 steps). Commit frequently. |
| **Scope of sample dataset creeps** | Medium | Low | Define the 30 entities and relationships in Phase 0. No additions after that. |
| **Demo fails under pressure** | Low | High | Script the demo. Run it 10 times. Embedded Grafeo means no network flakiness. |

---

## What Comes After (V2 — Not In This Release)

These are explicitly out of scope but documented here so the architecture accommodates them:

- **Additional primitives:** TRACE, REFRESH, SIGNAL, AWARENESS, COMPARE, HYPOTHESIZE, ANCHOR
- **Additional adapters:** PostgreSQL/pgvector, Neo4j, Elasticsearch, TimescaleDB (network-client adapters alongside embedded Grafeo)
- **Persistent storage mode** for Grafeo (file-backed instead of in-memory — trivial, just pass a path to `Cqr.Grafeo.Native.new/1`)
- **Multi-tenant scope isolation**
- **Agent identity and authentication** (beyond config-based)
- **Distributed reputation network** (CRDT-based quality scoring)
- **LiveView dashboard** (monitoring, query history, governance audit trail)
- **Validation suite integration** (run the 100-intent corpus against the MCP server)

The architecture should make adding these feel like extending, not rewriting. If Phase 1-3 are done right, adding TRACE is "write the parser combinator + the adapter query + the tests." If they're done wrong, adding TRACE means touching 15 files.

---

## Success Metrics

At launch (day 37), the project is successful if:

1. **A developer can go from zero to governed context in under 10 minutes.** Clone, `mix deps.get`, `mix run --no-halt`, connect Claude, ask a question, get quality-annotated context back. No Docker. No external database. No configuration.
2. **The governance enforcement is real, not decorative.** An agent in `scope:company:engineering` genuinely cannot see `scope:company:finance:latam` entities. This is the whole point.
3. **Quality metadata is present on every single response.** No exceptions. Even errors include quality context.
4. **The code is clean enough that a senior Elixir developer would contribute to it.** This is a protocol reference implementation, not a weekend hack.
5. **The README makes the governed-context category real.** Someone reads it and thinks: "Oh, this is the layer that's been missing."

---

*"The best time to plant a tree was 20 years ago. The second best time is now."*

*The best time to release the governed context protocol was before anyone else thought of it. The second best time is before MCP's Enterprise Readiness Working Group defines it for you.*
