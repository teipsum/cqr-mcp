# UNICA MVP2 — Developer Tools for CQR Evaluation

**Product:** Developer tooling for platform engineers evaluating CQR for their agent stack
**Interface:** Phoenix LiveView (extending existing application)
**LLM Support:** Anthropic Claude API + Ollama (locally hosted models)
**Developer:** Michael Lewis Cram (solo, with Claude Code)
**Dependency:** Builds on MCP Server open release (cqr_mcp, ~5.5 week build)
**Estimated scope:** ~3 weeks of development after MCP server completion

---

## Context and Positioning

MVP1 delivered the validation suite — a batch-oriented system for measuring CQR generation accuracy across 100 intents. The MCP server open release delivers the protocol engine and MCP connectivity. MVP2 adds the interactive developer tooling that turns CQR from "a protocol you read about" into "a protocol you evaluate in a single session."

The primary persona is a **platform/infrastructure engineer** deciding whether CQR fits into their organization's agent stack. Their evaluation arc has five phases:

1. **"Show me it works"** — see CQR generate, parse, execute, and return governed context
2. **"Let me connect my data"** — model their organization and point CQR at their own backends
3. **"Can my LLM generate CQR?"** — test generation accuracy with their model of choice
4. **"What does governance actually look like?"** — see scope enforcement, quality metadata, and certification workflows in action
5. **"How do I integrate this?"** — understand the MCP interface, adapter contract, and agent generation contract

Each phase maps to a tool. MVP2 ships all five, prioritized in the order listed above. Every tool ships with a LiveView interface AND an API endpoint.

---

## LLM Provider Architecture

MVP2 supports two LLM providers through a unified provider abstraction:

### Provider Behaviour

```elixir
defmodule Cqr.LLM.Provider do
  @callback generate(intent :: String.t(), opts :: keyword()) ::
    {:ok, %{raw_response: String.t(), model: String.t(), latency_ms: integer()}} |
    {:error, term()}

  @callback list_models() :: {:ok, [String.t()]} | {:error, term()}
  @callback health_check() :: :ok | {:error, term()}
end
```

### Anthropic Claude Provider

```elixir
defmodule Cqr.LLM.Anthropic do
  @behaviour Cqr.LLM.Provider

  # Configuration via environment:
  #   ANTHROPIC_API_KEY=sk-ant-...
  #   ANTHROPIC_MODEL=claude-sonnet-4-20250514 (default)
  #
  # Uses the Messages API (/v1/messages)
  # System prompt: CQR agent generation contract
  # User message: natural language intent
  # Returns: raw assistant response containing CQR expression
end
```

### Ollama Provider

```elixir
defmodule Cqr.LLM.Ollama do
  @behaviour Cqr.LLM.Provider

  # Configuration via environment:
  #   OLLAMA_HOST=http://localhost:11434 (default)
  #   OLLAMA_MODEL=qwen2.5:14b (default)
  #
  # Uses the Ollama /api/generate endpoint
  # System prompt: CQR agent generation contract
  # User message: natural language intent
  # Lists available models via /api/tags
end
```

### Provider Selection

The LiveView UI shows a model selector dropdown populated by calling `list_models()` on all configured providers. Models are displayed as `provider/model_name` (e.g., `anthropic/claude-sonnet-4-20250514`, `ollama/qwen2.5:14b`). The provider is inferred from the selection. Both providers can be active simultaneously for side-by-side comparison.

Configuration is validated at application startup. If `ANTHROPIC_API_KEY` is not set, the Anthropic provider is unavailable but the application still starts with Ollama only (and vice versa). If neither is configured, the application starts but LLM-dependent features show a configuration prompt.

---

## Tool 1: Interactive Playground

**Route:** `/playground`
**Priority:** 1 (highest — first thing demoed, first thing a design partner uses)
**Estimated effort:** 3-4 days

### Purpose

Single-intent, interactive CQR exploration. The developer types a natural language intent and watches the full pipeline execute in real time: LLM generation → parse → scope resolution → adapter execution → quality-annotated result.

### Interface Layout

The playground uses a top-to-bottom pipeline visualization. Each stage of the pipeline is a distinct panel that populates as execution progresses, giving the developer x-ray vision into what CQR is doing.

**Panel 1 — Intent Input:**
- Text input for natural language (e.g., "What is our current annual recurring revenue?")
- Model selector dropdown (populated from configured providers)
- Scope selector (dropdown populated from semantic definition repository)
- "Execute" button
- Optional: raw CQR input toggle — bypass LLM generation and type CQR directly for testing the engine without the generation step

**Panel 2 — LLM Generation:**
- Raw LLM response (full text, scrollable)
- Extracted CQR expression with syntax highlighting
- Generation latency (ms)
- Token count (if available from provider)
- Model identifier

**Panel 3 — Parse Result:**
- If successful: AST visualization as an indented tree structure showing the primitive, entity reference, scope, and all clause parameters
- If failed: the informative error envelope — what went wrong, where in the expression, what the parser expected, and similar valid expressions as suggestions
- Parse latency (μs — this should be sub-millisecond)

**Panel 4 — Scope Resolution:**
- The scope chain traversed: starting scope → parent scopes → fallback chain
- For each scope in the chain: was the entity found? What was the visibility rule? Was access granted or denied?
- Visual highlight of the scope that provided the authoritative result
- Scope resolution latency (μs)

**Panel 5 — Execution Result:**
- The full CQR response envelope:
  - `status` — resolved, not_found, stale, below_reputation
  - `entity` — the resolved entity with value
  - `source_scope` — which scope provided the result
  - `source_adapter` — which adapter provided the result
  - `quality metadata` — freshness, confidence, reputation, owner, lineage, certification status
  - `cost` — adapters queried, operations consumed, execution time per adapter
- If multiple adapters returned results: conflict display showing each adapter's result with source attribution
- Total pipeline latency breakdown: generation + parse + scope + execution + annotation

**Panel 6 — History Sidebar:**
- Scrollable list of previous intents in the current session
- Click to reload any previous result
- "Save as test intent" button → adds to the custom test corpus (feeds into Generation Lab)

### API Endpoint

```
POST /api/playground/execute
Content-Type: application/json

{
  "intent": "What is our current annual recurring revenue?",
  "provider": "anthropic",
  "model": "claude-sonnet-4-20250514",
  "scope": "scope:finance",
  "mode": "full"  // "full" | "generate_only" | "parse_only"
}

Response: full pipeline result with all panel data
```

### Implementation Notes

- The LiveView uses `send_update/3` to populate each panel as execution progresses, creating a visual pipeline animation
- Each pipeline stage is a separate function call, enabling the mode toggle (generate_only skips execution, parse_only skips LLM and execution)
- The raw CQR input toggle bypasses Panel 2 and feeds directly into Panel 3
- Session history is held in LiveView assigns (not persisted to DB unless "save as test intent" is clicked)
- Syntax highlighting for CQR expressions uses a custom Makeup lexer or a simple regex-based highlighter — CQR's grammar is simple enough that keyword-based highlighting (uppercase keywords in one color, entity: prefixes in another, scope: in another) is sufficient

---

## Tool 2: Schema Builder

**Route:** `/schema`
**Priority:** 2 (critical for design partner pilots — without it, every pilot requires hand-coded seed data)
**Estimated effort:** 5-6 days

### Purpose

A form-based interface for defining the semantic definition repository: entities, scopes, relationships, and adapter mappings. Enables a platform engineer to model their organizational structure and start evaluating CQR against their own semantic context in a single session.

### Interface Layout

Three-tab layout: Scopes, Entities, Relationships. Plus a read-only Schema Preview panel that shows the generated active schema format in real time.

**Tab 1 — Scopes:**
- Visual tree representation of the scope hierarchy
- Each scope node shows: name, parent, visibility rules, default freshness requirement, default reputation threshold
- Add scope: form with name, parent (dropdown from existing scopes), visibility (public/restricted), defaults
- Edit scope: inline edit on click
- Delete scope: with dependency check (warns if entities are assigned to this scope)
- Drag-and-drop reordering within the tree (reparenting)

**Tab 2 — Entities:**
- Table view: namespace, name, type (metric/dimension/document/concept), description, assigned scope(s), adapter mapping(s), certification status, owner
- Add entity: form with all fields. Scope assignment is a multi-select from the scope tree. Adapter mapping specifies which adapter(s) hold data for this entity.
- Bulk import: paste CSV or JSON array of entity definitions for rapid setup
- Filter/search by namespace, scope, type, certification status
- Entity count and coverage metrics (how many entities per scope, how many unmapped)

**Tab 3 — Relationships:**
- Table view: source entity → relationship type → target entity, strength (0.0–1.0), scope, directionality
- Relationship types from the CQR spec: CORRELATES_WITH, CAUSES, CONTRIBUTES_TO, DEPENDS_ON, PART_OF
- Add relationship: dropdowns for source/target entity (searchable), relationship type, strength slider, scope assignment
- Visual: optional simple graph preview showing entity nodes and relationship edges for the currently filtered view (use a lightweight JS graph library via LiveView hook — not a full graph editor, just a readable visualization)

**Schema Preview Panel (always visible):**
- Live-updating read-only display of the active schema format (Component 2 of the agent generation contract)
- Shows exactly what the LLM will see: entities one-per-line with namespace/name/type/description, relationships in UPPERCASE, scope hierarchy as indented tree
- "Copy to clipboard" button
- Character count with warning if approaching system prompt context limits
- Format toggle: active schema format (default) vs. JSON export vs. Cypher seed statements

### Persistence

Schema changes are written to embedded Grafeo in real time. The schema builder operates on the live semantic definition repository — changes are immediately reflected in playground and validation results. An "export schema" function saves the current schema as a JSON file for version control and sharing. An "import schema" function loads a JSON schema file, enabling design partners to share organizational models.

### Seed Data Templates

MVP2 ships with 2-3 pre-built schema templates that a developer can load as starting points:

- **SaaS company** (the demo default): finance, product, engineering, HR, customer success scopes with metrics like ARR, churn, NPS, headcount
- **Financial services**: trading, risk, compliance, operations scopes with regulatory entities
- **Healthcare**: clinical, administrative, research scopes with HIPAA-relevant entity classifications

Templates are JSON files loaded via the import function. They provide enough structure to demonstrate CQR's governance capabilities without requiring the developer to model an organization from scratch.

### API Endpoints

```
GET    /api/schema/scopes          — list all scopes
POST   /api/schema/scopes          — create scope
PUT    /api/schema/scopes/:id      — update scope
DELETE /api/schema/scopes/:id      — delete scope

GET    /api/schema/entities        — list all entities (filterable)
POST   /api/schema/entities        — create entity
POST   /api/schema/entities/bulk   — bulk import
PUT    /api/schema/entities/:id    — update entity
DELETE /api/schema/entities/:id    — delete entity

GET    /api/schema/relationships   — list all relationships
POST   /api/schema/relationships   — create relationship
DELETE /api/schema/relationships/:id — delete relationship

GET    /api/schema/export          — full schema as JSON
POST   /api/schema/import          — import schema from JSON
GET    /api/schema/active          — active schema format (what the LLM sees)
```

---

## Tool 3: Governance Explorer

**Route:** `/governance`
**Priority:** 3 (the enterprise sales tool — makes scope enforcement and quality metadata visible)
**Estimated effort:** 4-5 days

### Purpose

Visual demonstration of CQR's governance capabilities: scope enforcement, quality metadata, CERTIFY workflow, SIGNAL reputation, and the governance audit trail. This is what you show the CISO, the CDO, and the compliance officer sitting next to the platform engineer.

### Interface Layout

Four sub-views accessible via tabs or sidebar navigation.

**View 1 — Scope Enforcement Demo:**
- Agent identity selector: "You are an agent operating in scope:X" (dropdown from scope tree)
- Entity query input: select or type an entity reference
- Result display: what the agent sees (entities visible within its scope) vs. what exists globally (entities in all scopes)
- Side-by-side comparison: "Agent in scope:finance sees..." vs. "Agent in scope:hr sees..." for the same entity query
- The visual punch: when an entity is in scope:hr and the agent is in scope:finance, the result shows `not_found` — genuine invisibility, not an access denied error. The entity does not exist from the requesting agent's perspective. This is the Claim 51 genuine invisibility property made visible.

**View 2 — Quality Metadata Inspector:**
- Select any resolved entity
- Display the full quality metadata envelope with visual indicators:
  - Freshness: time since last update with color coding (green < threshold, amber approaching, red stale)
  - Reputation: score with history graph showing how SIGNAL assessments have changed it over time
  - Confidence: composite score with breakdown by source
  - Lineage: version history with who proposed, reviewed, certified each version
  - Owner: responsible party
  - Certification status: proposed → under_review → certified → superseded with timestamps
- "What if?" panel: adjust freshness threshold or reputation minimum and see whether the entity would still be returned (demonstrates WITH freshness < and WITH reputation > clause behavior)

**View 3 — CERTIFY Workflow:**
- Interactive walkthrough of the full certification lifecycle:
  1. Propose a definition (fill form: entity, value, evidence, scope)
  2. See the proposal appear in the governance audit trail
  3. Review the proposal (add review notes, score)
  4. Approve/reject (with authority assignment)
  5. See the entity's certification status change in real time
  6. See how the certified definition now appears in RESOLVE results with the full provenance chain
- This is a guided demo — the developer can walk through each step manually, or click "auto-run" to see the full lifecycle execute in sequence with delays between steps

**View 4 — Audit Trail:**
- Time-ordered log of all governance operations
- Each entry: timestamp, agent identity, primitive invoked, scope context, governance decision applied, quality metadata of results
- Filterable by: time range, primitive type, scope, agent identity
- Export as JSON or CSV (for compliance review scenarios)
- Real-time updates via PubSub — operations from the Playground or Generation Lab appear here immediately

### API Endpoints

```
GET  /api/governance/scope-demo    — scope visibility comparison for two agent contexts
GET  /api/governance/quality/:entity — full quality metadata for an entity
POST /api/governance/certify       — execute a CERTIFY operation
GET  /api/governance/audit         — filtered audit trail
GET  /api/governance/audit/export  — audit trail export (JSON/CSV)
```

---

## Tool 4: Generation Lab

**Route:** `/lab`
**Priority:** 4 (extends MVP1 validation suite for interactive model evaluation)
**Estimated effort:** 3-4 days

### Purpose

Interactive model comparison and custom intent testing. Answers the platform engineer's question: "Will CQR work with *my* model, *my* data, and *my* kinds of queries?"

### Interface Layout

**Panel 1 — Side-by-Side Comparison:**
- Two model selectors (left and right), each with provider/model dropdown
- Shared intent input field
- "Generate" button sends the same intent to both models simultaneously
- Left/right display: each model's raw response, extracted CQR, parse result, syntactic/semantic scores
- Diff highlighting: show where the two CQR expressions differ (keywords, entities, scopes, parameters)
- Latency comparison bar

**Panel 2 — Custom Intent Builder:**
- Form to create a new test intent:
  - Natural language intent (required)
  - Gold standard CQR expression (optional — if provided, enables automated scoring; if omitted, manual review only)
  - Tier assignment: simple / intermediate / complex / multi-step
  - Domain tags: finance, hr, product, custom
  - Notes field
- "Test now" button: immediately runs the intent against the currently selected model(s) and shows results inline
- "Save to corpus" button: adds the intent to the custom test corpus for future batch runs

**Panel 3 — Custom Corpus Manager:**
- Table of all custom test intents (separate from the MVP1 standard 100-intent corpus)
- Corpus stats: total intents, by tier, by domain, with/without gold standards
- "Run corpus" button: batch-execute the custom corpus against one or two models, producing accuracy metrics
- Results link to the existing MVP1 validation dashboard (reusing the run summary, tier breakdown, and failure analysis views)

**Panel 4 — Model Accuracy Dashboard:**
- Per-model accuracy tracking over time (extends MVP1's trend chart to include model identity)
- Model comparison matrix: for each model that has been tested, show syntactic accuracy, semantic accuracy, intent fidelity, average latency
- Sortable and filterable
- Answers: "Which model is best for CQR in my environment?"

### API Endpoints

```
POST /api/lab/compare           — run same intent against two models
POST /api/lab/intents           — create custom test intent
GET  /api/lab/intents           — list custom test intents
POST /api/lab/corpus/run        — batch-execute custom corpus
GET  /api/lab/models/accuracy   — per-model accuracy summary
```

---

## Tool 5: Integration Console

**Route:** `/integrate`
**Priority:** 5 (starts as documentation, evolves into interactive tool)
**Estimated effort:** 2-3 days

### Purpose

Everything a platform engineer needs to integrate CQR into their agent stack, in one place.

### Interface Layout

**Section 1 — MCP Server Status:**
- Server status indicator (running/stopped)
- Transport status: stdio (active/inactive), SSE (listening on port X)
- Connected clients list (if SSE — shows client IPs and connection duration)
- Configuration summary: active scope, loaded schema entity count, adapter count and health

**Section 2 — Tool & Resource Reference:**
- Auto-generated from the MCP tool and resource definitions
- For each tool: name, description, input schema (rendered as a readable form), output schema (rendered as annotated JSON), example request/response pair
- For each resource: URI, description, content preview
- "Try it" button on each tool → opens the Playground with that tool pre-selected

**Section 3 — Agent Generation Contract:**
- The complete system prompt displayed with syntax highlighting
- Three components shown separately: Grammar Reference, Active Schema (live from current schema), Few-Shot Examples
- "Copy system prompt" button (copies the assembled prompt ready for pasting into any agent framework)
- Token count for the assembled prompt (helps the developer assess context window budget)
- Configuration guidance: how to include the system prompt in Claude, GPT-4, Llama, and generic OpenAI-compatible APIs

**Section 4 — Integration Snippets:**
- Pre-built code examples for common integration patterns:
  - **Python MCP client**: connect to CQR MCP server, call cqr_resolve, parse response
  - **TypeScript MCP client**: same pattern for Node.js environments
  - **Claude Desktop config**: the JSON configuration block (already in the MCP server README, but surfaced here for convenience)
  - **Direct HTTP (non-MCP)**: REST API calls for teams not yet on MCP
- Each snippet is copy-pasteable and tested against the running server

**Section 5 — Adapter Development Guide:**
- Rendered version of ADAPTERS.md
- The adapter behaviour contract with callback signatures
- Reference implementation walkthrough (Grafeo adapter, annotated)
- "Generate adapter scaffold" button: enter adapter name → downloads a `.ex` file with the behaviour implemented as stubs with inline documentation

### API Endpoints

```
GET /api/integrate/status        — MCP server and adapter health
GET /api/integrate/tools         — tool definitions with schemas
GET /api/integrate/resources     — resource definitions
GET /api/integrate/prompt        — assembled agent generation contract
GET /api/integrate/prompt/token-count — token count for current prompt
POST /api/integrate/scaffold/:name — generate adapter scaffold
```

---

## Navigation and Information Architecture

MVP2 extends the existing Phoenix application with a top-level navigation structure:

```
/ (home/landing — brief overview of CQR, links to all tools)
├── /playground      — Interactive Playground
├── /schema          — Schema Builder
├── /governance      — Governance Explorer
├── /lab             — Generation Lab
├── /validation      — Validation Dashboard (MVP1, existing)
└── /integrate       — Integration Console
```

The navigation bar shows all six routes. A subtle status indicator on each nav item shows whether prerequisites are met (e.g., Schema Builder shows a warning dot if no entities are defined; Generation Lab shows a warning dot if no LLM provider is configured).

---

## Cross-Cutting Concerns

### Real-Time Updates

All tools receive real-time updates via Phoenix PubSub:
- Playground execution broadcasts to Governance Explorer audit trail
- Schema changes broadcast to Playground (scope selector updates) and Integration Console (active schema updates)
- Generation Lab batch runs broadcast progress to the Lab UI

### Error Handling

Every tool follows the CQR informative error semantics principle: errors tell the developer what went wrong, why, and what to try. No stack traces in the UI. No generic "something went wrong." Specific, actionable error messages with suggested remediation.

- LLM provider errors: "Ollama at localhost:11434 is not responding. Is it running? Start with `ollama serve`"
- Parse errors: "Expected a scope reference (scope:namespace) after FROM, but found 'finance'. Did you mean scope:finance?"
- Scope errors: "Entity entity:hr:headcount is not visible from scope:finance. It exists in scope:hr. The agent would need scope:hr access or a FALLBACK chain."

### Responsive Design

LiveView pages should be functional on desktop browsers. Mobile is not a priority for developer tooling, but the layout should not break on tablet-sized screens (design partner demos may happen on iPads).

### Dark Mode

Support system-preference dark mode via CSS media query. Developer tools used for extended sessions benefit from dark mode. Use CSS custom properties for theming — not hardcoded colors.

---

## Implementation Plan

MVP2 is scoped for approximately 3 weeks of development after the MCP server open release is complete. The implementation is sequenced by priority:

### Week 1: Playground + LLM Providers (Days 1-7)

- Day 1-2: LLM provider abstraction, Anthropic provider, Ollama provider, configuration validation, model listing
- Day 3-4: Interactive Playground LiveView — intent input, model selector, pipeline panels, real-time stage population
- Day 5: CQR syntax highlighting, raw CQR input mode, session history
- Day 6-7: API endpoints for playground, integration tests, documentation

**Exit criteria:** Developer can type an intent, select Claude or an Ollama model, and see the full CQR pipeline execute with quality metadata and scope resolution chain visible. Both providers working. API endpoint functional.

### Week 2: Schema Builder + Governance Explorer (Days 8-14)

- Day 8-9: Schema Builder — scope tree management (CRUD, hierarchy visualization)
- Day 10-11: Schema Builder — entity management (CRUD, bulk import, filtering), relationship management
- Day 12: Schema Builder — active schema preview (live generation), export/import, seed templates
- Day 13-14: Governance Explorer — scope enforcement demo, quality metadata inspector, CERTIFY walkthrough, audit trail

**Exit criteria:** Developer can model their organization (scopes, entities, relationships), see the active schema update in real time, and walk through CQR governance capabilities. Schema changes immediately affect Playground results.

### Week 3: Generation Lab + Integration Console + Polish (Days 15-21)

- Day 15-16: Generation Lab — side-by-side comparison, custom intent builder, save to corpus
- Day 17: Generation Lab — custom corpus runner, per-model accuracy tracking
- Day 18-19: Integration Console — MCP status, tool/resource reference, agent generation contract display, integration snippets
- Day 20: Integration Console — adapter scaffold generator
- Day 21: Cross-tool navigation, dark mode, responsive cleanup, final documentation pass

**Exit criteria:** All five tools functional with LiveView interfaces and API endpoints. Navigation complete. A platform engineer can go from "never seen CQR" to "evaluated it against my model and organizational model" in a single session.

---

## Success Criteria for MVP2

MVP2 is complete when:

- A platform engineer can model their organization in the Schema Builder (or load a template), type natural language intents in the Playground, and see governed results with quality metadata — in under 30 minutes from first visit
- Both Claude (via API) and at least one Ollama model produce valid CQR expressions through the Playground
- The Governance Explorer demonstrates scope enforcement (genuine invisibility), quality metadata, and the CERTIFY workflow clearly enough that a non-technical stakeholder can follow it
- The Generation Lab enables side-by-side model comparison and custom intent testing
- The Integration Console provides everything needed to connect CQR to an external agent (system prompt, code snippets, adapter guide)
- All tools have corresponding API endpoints
- All tools update in real time when related data changes (schema → playground, operations → audit trail)

---

## What MVP2 Does NOT Include

- External adapter implementations (PostgreSQL, Snowflake, Neo4j — adapters beyond embedded Grafeo are a post-MVP2 deliverable, though the adapter scaffold generator prepares for them)
- Multi-tenant isolation (single-tenant for the evaluation experience)
- User authentication or role-based access (the developer tool is a local evaluation environment, not a shared production service)
- Multi-agent runtime visualization (Claims 44-49 are not implemented in the MCP server open release)
- Production deployment tooling (Kubernetes manifests, Terraform, etc.)
- Automated performance benchmarking (latency is shown in the Playground but not systematically benchmarked)

---

## Relationship to MCP Server Open Release

MVP2 depends on the MCP server open release and extends it. The relationship:

- **MCP server** provides: parser, engine, Grafeo adapter, scope resolution, quality metadata, MCP transport, seed data, CLI-oriented experience
- **MVP2** adds: LiveView developer tools, LLM provider abstraction (Claude + Ollama), interactive exploration, schema management, governance visualization, model comparison, integration documentation

MVP2 is part of the UNICA application (not `cqr_mcp`). It imports `cqr_mcp` as a dependency and adds the LiveView layer. This keeps the open-source MCP server clean (MIT, no UI opinions) while the UNICA application (commercial, proprietary) provides the developer experience.

The LiveView tools call the same `Cqr.Engine.execute/2` entry point that the MCP server uses. Governance invariance is maintained — the developer tools cannot bypass scope enforcement or quality metadata annotation. What the Playground shows is exactly what an MCP client would receive.
