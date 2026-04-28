# CQR — Cognitive Query Resolution

## Protocol Specification v1.0

**April 2026 · TEIPSUM**

A native context interaction language for governed organizational context.

---

## Patent Notice

CQR was previously named SEQUR (Semantic Query Resolution). The USPTO provisional patent application was filed under the SEQUR name. All protocol semantics, claims, and architectural properties described in the patent apply to CQR. The rename reflects the protocol's evolution from seven primitives to twelve, and its broader scope as a cognitive operations protocol rather than a purely semantic query language. "C-Q-R" is pronounced like "seeker."

---

## Table of Contents

1. Overview
2. Getting Started
3. Design Principles
4. Type System
5. Cognitive Operation Primitives
   - Context Resolution: RESOLVE, DISCOVER
   - Context Creation: ASSERT
   - Reasoning: TRACE, HYPOTHESIZE, COMPARE, ANCHOR
   - Governance: SIGNAL, CERTIFY
   - Evolution: UPDATE
   - Maintenance & Perception: REFRESH, AWARENESS
6. Scope Model
7. Standard Return Envelope
8. MCP Delivery Interface
9. Implementation Reference
10. Protocol Positioning

---

## 1. Overview

CQR (Cognitive Query Resolution) is designed for machine cognition as the primary consumer. AI agents generate CQR expressions to interact with organizational context, and the host platform translates those expressions into operations across heterogeneous storage backends.

This document defines the formal specification: the grammar, type system, primitive semantics, return envelope, error model, and agent generation contract.

---

## 2. Getting Started

### Prerequisites

- Elixir 1.17+ and Erlang/OTP 27+
- Git
- An MCP-compatible client (Claude Desktop, Claude Code, Cursor, or any MCP-capable application)

### Installation

```bash
git clone https://github.com/teipsum/cqr-mcp.git
cd cqr-mcp
mix deps.get
mix run --no-halt
```

The CQR MCP server starts with an embedded Grafeo graph database, seeds a sample organizational dataset on first boot, and begins listening on stdio for MCP connections. No Docker required. No external database. No additional configuration.

### Connecting to Claude Desktop

Add the following to your Claude Desktop configuration file:

- **macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Windows:** `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "CQR": {
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

Replace `/path/to/elixir` with the output of `which elixir` and `/path/to/cqr-mcp` with the absolute path to the cloned repository.

### Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `CQR_AGENT_ID` | `anonymous` | Identity of the connecting agent |
| `CQR_AGENT_SCOPE` | `scope:company` | The agent's position in the organizational scope hierarchy |

### Verifying the Connection

Once connected, the CQR tools (`cqr_resolve`, `cqr_discover`, `cqr_certify`) appear in the MCP client's tool list. The `cqr://session` resource is available in the client's resource browser and displays the current agent identity, visible scopes, and connection metadata.

### Sample Dataset

The server seeds a sample organizational dataset on first boot:

- 6 scopes: company, finance, product, engineering, hr, customer_success
- 27 entities across all domains (ARR, churn_rate, NPS, deployment_frequency, headcount, etc.)
- 17 typed relationships (CORRELATES_WITH, CONTRIBUTES_TO, DEPENDS_ON, etc.)
- Quality metadata on every entity (reputation scores, freshness timestamps, ownership)

This dataset provides a realistic foundation for exploring CQR's capabilities. Replace it with your own organizational data by modifying `lib/cqr/repo/seed.ex`.

---

## 3. Design Principles

- **Agents are the users.** Every syntactic and semantic decision optimizes for reliable LLM generation, not human developer ergonomics. Primitives are unambiguous, keywords are semantically clear, and the grammar avoids constructs that LLMs commonly hallucinate.

- **Cognitive operations, not data operations.** CQR primitives map to reasoning patterns (resolve a canonical concept, orient in a neighborhood, trace a causal chain, assert new context) rather than data manipulation patterns (select, join, filter).

- **Quality metadata is mandatory.** Every CQR response includes provenance, freshness, confidence, and reputation data. An agent always knows how much to trust what it received.

- **Scope is first-class.** Every expression operates within a defined scope hierarchy. Scope is not a filter applied after retrieval — it is a fundamental part of the query semantics that determines what is visible, what is authoritative, and what falls back to broader scopes.

- **Two-tier trust model.** Context exists in two trust states: asserted (written by agents, governed but uncertified) and certified (approved through the CERTIFY governance lifecycle). Both are visible; trust level is explicit metadata.

- **Fail informatively.** When an expression cannot be satisfied, the error response gives the agent enough information to reason about what went wrong and what to try next. Errors are cognitive inputs, not exceptions.

---

## 4. Type System

CQR operates over a small, well-defined set of types. Constraining the type system is deliberate — it reduces the surface area for LLM generation errors and keeps the language semantically focused.

### Core Types

| Type | Syntax | Description |
|------|--------|-------------|
| Entity | `entity:<segment>:<segment>(:<segment>)*` | A named concept in the semantic repository. Addresses are hierarchical with unlimited depth — `entity:finance:arr` (3 segments), `entity:product:retention:cohort:q4` (5 segments), and deeper. The leaf is the entity name; every preceding segment after `entity:` is the namespace path. Interior segments are auto-created as container entities and linked by `CONTAINS` edges; scope is enforced at every level of the path during resolution. |
| Entity Prefix | `entity:<segment>(:<segment>)*:*` | A hierarchical prefix used by DISCOVER's prefix mode (Section 5, DISCOVER). The trailing `:*` is the literal sentinel that switches DISCOVER from neighborhood scan to depth-first `CONTAINS` enumeration. |
| Scope | `scope:<segment>[:<segment>]` | An organizational boundary that defines visibility, authority, and access control. Scopes form a hierarchy. |
| Duration | `<number><unit>` | A time span. Units: m (minutes), h (hours), d (days), w (weeks). |
| Score | `<decimal>` | A 0.0–1.0 value for reputation thresholds and strength scores. |
| Agent Reference | `agent:<identifier>` | A reference to a specific agent or agent role. |
| String Literal | `"<text>"` | A quoted text value for evidence descriptions and search terms. |
| Direction | `outbound \| inbound \| both` | Edge traversal direction for DISCOVER operations. |

---

## 5. Cognitive Operation Primitives

CQR defines 12 cognitive operation primitives organized into 6 categories. Each primitive maps to a reasoning pattern that agents actually perform. Optional clauses may appear in any order within each primitive — a deliberate design decision to accommodate the variable ordering tendencies of LLM generation.

---

### Category 1: Context Resolution

#### RESOLVE — Canonical Retrieval

Retrieve a canonical entity by semantic address from the nearest matching scope, with quality metadata. Unlike search, RESOLVE targets a specific canonical concept and returns the single authoritative instance, analogous to how a human expert resolves the meaning of a term within their organizational context.

**Syntax:**

```
RESOLVE entity:<namespace>:<name>
  [FROM scope:<scope>]
  [WITH freshness < <duration>]
  [WITH reputation > <score>]
  [INCLUDE <annotation_list>]
  [FALLBACK scope:<s1> -> scope:<s2> [-> scope:<sN>]]
```

**Parameters:**

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| entity | Yes | — | The semantic address of the concept to resolve |
| FROM scope | No | Agent's active scope | The scope to search first |
| WITH freshness | No | No constraint | Maximum age of the returned value |
| WITH reputation | No | No constraint | Minimum reputation score threshold |
| INCLUDE | No | freshness, confidence | Metadata annotations to include |
| FALLBACK | No | Walk up scope hierarchy | Explicit fallback chain |

**Example:**

Intent: "What is our current ARR? I need it to be recent and trustworthy. If finance doesn't have it, check with the product team."

```
RESOLVE entity:finance:arr
  FROM scope:company:finance
  WITH freshness < 24h
  WITH reputation > 0.8
  FALLBACK scope:company:product -> scope:company
  INCLUDE freshness, reputation, owner, lineage
```

Response (abbreviated):

```json
{
  "data": [{
    "name": "arr",
    "namespace": "finance",
    "description": "Annual Recurring Revenue",
    "type": "metric",
    "reputation": 0.95,
    "owner": "finance_team",
    "certified": true,
    "freshness_hours_ago": 2
  }],
  "cost": { "adapters_queried": 1, "operations": 1, "execution_ms": 8 }
}
```

---

#### DISCOVER — Neighborhood Scan

The orientation primitive. Returns a navigable map of concepts related to an anchor entity or search term, annotated with quality signals. DISCOVER combines graph traversal (relationship-based) and semantic similarity search (embedding-based), merging results from both modalities.

**Syntax:**

```
DISCOVER concepts
  RELATED TO entity:<namespace>:<name> | "<search_term>"
  [WITHIN scope:<s1> [, scope:<s2>, ...]]
  [DEPTH <integer>]
  [DIRECTION outbound | inbound | both]
  [ANNOTATE <annotation_list>]
  [LIMIT <integer>]
```

**Parameters:**

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| RELATED TO | Yes | — | Anchor entity or free-text search term |
| WITHIN scope | No | Agent's visible scopes | Scope constraint |
| DEPTH | No | 2 | Graph traversal depth |
| DIRECTION | No | both | Edge traversal direction |
| ANNOTATE | No | freshness, reputation | Metadata annotations |
| LIMIT | No | No limit | Maximum results |

**Prefix mode (`entity:<segment>(:<segment>)*:*`).** When the `RELATED TO` target ends in the literal `:*` sentinel, DISCOVER switches from typed-relationship neighborhood scan to hierarchical prefix enumeration. The engine performs a depth-first traversal of `CONTAINS` edges starting at the address before the `:*` and returns every visible descendant entity. Branch-level scope pruning omits any subtree whose root the agent cannot see and does not descend into it, so a blocked subtree is structurally indistinguishable from a missing one. `WITHIN`, `DEPTH`, `DIRECTION`, and `LIMIT` clauses are accepted for syntactic uniformity but the prefix walk is bounded by the containment graph itself rather than by an explicit depth.

```
DISCOVER concepts RELATED TO entity:product:retention:*
```

**Direction semantics:** Edges are stored once, directionally. The relationship type always reads in its original stored direction (e.g., CONTRIBUTES_TO always means source contributes to target). The `direction` parameter controls which edges are traversed:

- `outbound` — returns entities the anchor points TO (the anchor is the source)
- `inbound` — returns entities that point AT the anchor (the anchor is the target)
- `both` — returns the union, each result tagged with a `direction` field

**Design rationale:** DISCOVER defaults to `both` because it is the exploration primitive — "show me the full neighborhood." Directed traversal for causal and impact analysis is handled by TRACE (inherently inbound/lineage) and HYPOTHESIZE (inherently outbound/impact). The underlying graph traversal engine is shared across all three primitives; they differ in metadata enrichment and semantic intent, not in traversal mechanics.

**Example — Exploration (both directions):**

Intent: "What's connected to our churn rate?"

```
DISCOVER concepts
  RELATED TO entity:product:churn_rate
  DEPTH 2
```

Response (abbreviated):

```json
{
  "data": [
    { "entity": "product:nps", "relationship": "CORRELATES_WITH", "strength": 0.7, "direction": "outbound", "reputation": 0.82 },
    { "entity": "finance:arr", "relationship": "CONTRIBUTES_TO", "strength": 0.75, "direction": "outbound", "reputation": 0.95 },
    { "entity": "product:feature_adoption", "relationship": "DEPENDS_ON", "strength": 0.5, "direction": "outbound", "reputation": 0.78 },
    { "entity": "product:retention_rate", "relationship": "CORRELATES_WITH", "strength": 0.8, "direction": "inbound", "reputation": 0.86 }
  ]
}
```

**Example — Impact analysis (inbound only):**

Intent: "What feeds into ARR?"

```
DISCOVER concepts
  RELATED TO entity:finance:arr
  DIRECTION inbound
```

Response (abbreviated):

```json
{
  "data": [
    { "entity": "product:churn_rate", "relationship": "CONTRIBUTES_TO", "strength": 0.75, "direction": "inbound" },
    { "entity": "product:retention_rate", "relationship": "CONTRIBUTES_TO", "strength": 0.75, "direction": "inbound" },
    { "entity": "customer_success:expansion_revenue", "relationship": "CONTRIBUTES_TO", "strength": 0.3, "direction": "inbound" }
  ]
}
```

---

### Category 2: Context Creation

#### ASSERT — Agent-Written Context

Agents write governed but uncertified context into the organizational knowledge graph. Asserted entities are visible and queryable but carry lower trust than certified entities — "rumor with a paper trail."

**Syntax:**

```
ASSERT entity:<namespace>:<name>
  TYPE <entity_type>
  DESCRIPTION "<description>"
  INTENT "<why_this_is_being_asserted>"
  DERIVED_FROM entity:<namespace>:<name> [, entity:<namespace>:<name>, ...]
  [IN scope:<scope>]
  [CONFIDENCE <score>]
```

**Parameters:**

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| entity | Yes | — | Semantic address for the new context |
| TYPE | Yes | — | Entity type (metric, definition, policy, etc.) |
| DESCRIPTION | Yes | — | Human-readable description |
| INTENT | Yes | — | Why the agent is asserting this — mandatory for governance auditability |
| DERIVED_FROM | Yes | — | Source entities this assertion was derived from — mandatory for lineage |
| IN scope | No | Agent's active scope | Scope assignment |
| CONFIDENCE | No | 0.5 | Agent's self-assessed confidence |

**Two-tier trust model:** Asserted entities enter the graph with `certified: false` and the asserting agent's identity attached. They are immediately visible to RESOLVE and DISCOVER but carry explicit trust markers. To become certified, an asserted entity must go through the CERTIFY governance lifecycle (proposed → under_review → certified). This creates a clear separation between agent-generated knowledge and human-approved organizational truth.

**Mandatory INTENT and DERIVED_FROM:** These fields are not optional because they are the governance paper trail. Every assertion must explain why it exists and what it was derived from. This enables downstream auditing: if an assertion turns out to be wrong, the lineage chain shows how the error propagated.

**Example:**

Intent: "Based on the correlation between churn and NPS, I believe there's a leading indicator relationship we should track."

```
ASSERT entity:product:churn_nps_leading_indicator
  TYPE derived_metric
  DESCRIPTION "Leading indicator: NPS decline of >5 points predicts churn increase within 60 days"
  INTENT "Identified statistical pattern during quarterly review analysis"
  DERIVED_FROM entity:product:churn_rate, entity:product:nps
  IN scope:company:product
  CONFIDENCE 0.65
```

This entity is now visible in the graph with `certified: false`, `confidence: 0.65`, and full lineage back to churn_rate and nps. Any agent can RESOLVE or DISCOVER it, but the trust metadata makes its uncertified status explicit. A governance stakeholder can later CERTIFY it to elevate its trust level.

---

### Category 3: Reasoning

#### TRACE — Temporal & Causal Reasoning

Returns trajectories rather than snapshots — how an entity evolved, what caused state changes, and who acted. TRACE walks the lineage chain, following cause-and-effect relationships. It is inherently inbound/causal in direction.

**Syntax:**

```
TRACE entity:<namespace>:<name>
  [OVER last <duration>]
  [INCLUDE state_transitions, actors, triggers]
  [DEPTH causal:<integer>]
```

**Example:**

Intent: "How has our headcount changed over the last quarter and what drove the changes?"

```
TRACE entity:hr:headcount
  OVER last 90d
  INCLUDE state_transitions, actors, triggers
  DEPTH causal:2
```

This returns the headcount trajectory over 90 days — every value change, who or what triggered it (hiring event, attrition, restructuring), and follows the causal chain two hops deep (e.g., attrition was triggered by compensation_gap, which was triggered by market_benchmark_shift).

---

#### HYPOTHESIZE — Impact Projection

Speculative impact analysis. Given an assumed change to an entity, projects outbound effects through the relationship graph with confidence scoring. HYPOTHESIZE is inherently outbound in direction — it asks "if this changes, what downstream effects would we expect?"

**Syntax:**

```
HYPOTHESIZE CHANGE entity:<namespace>:<name>
  BY <delta_description>
  [DEPTH <integer>]
  [CONFIDENCE_THRESHOLD <score>]
```

**Example:**

Intent: "What would happen if our churn rate increased by 3 percentage points?"

```
HYPOTHESIZE CHANGE entity:product:churn_rate
  BY "increase of 3 percentage points"
  DEPTH 3
  CONFIDENCE_THRESHOLD 0.4
```

This walks outbound from churn_rate through CONTRIBUTES_TO, CORRELATES_WITH, and DEPENDS_ON edges, scoring each downstream entity's projected impact. Expected results: ARR decline (via CONTRIBUTES_TO, high confidence), NPS correlation shift (via CORRELATES_WITH, moderate confidence), expansion_revenue pressure (via indirect path, lower confidence).

---

#### COMPARE — Multi-Entity Analysis

Side-by-side comparison of two or more entities, surfacing shared relationships, divergent metadata, and quality differentials.

**Syntax:**

```
COMPARE entity:<ns1>:<n1>, entity:<ns2>:<n2> [, entity:<ns3>:<n3>, ...]
  [ON <attribute_list>]
  [WITHIN scope:<scope>]
```

**Example:**

Intent: "Compare our DORA metrics — deployment frequency vs lead time."

```
COMPARE entity:engineering:deployment_frequency, entity:engineering:lead_time
  ON reputation, freshness, owner, relationships
  WITHIN scope:company:engineering
```

This returns a structured comparison: both entities' quality metadata side by side, their shared relationships (they CORRELATE_WITH each other), their distinct relationships, and any divergences in freshness, reputation, or certification status.

---

#### ANCHOR — Epistemic Grounding

Evaluates the composite quality of a set of resolved context entities — the reasoning chain's overall trustworthiness. Identifies weakest links, risk flags, and generates actionable recommendations.

**Syntax:**

```
ANCHOR entity:<ns1>:<n1>, entity:<ns2>:<n2> [, ...]
  [CONFIDENCE_FLOOR <score>]
  [INCLUDE risk_flags, recommendations]
```

**Example:**

Intent: "I'm about to make a board presentation using ARR, churn rate, and NPS. How trustworthy is this data set?"

```
ANCHOR entity:finance:arr, entity:product:churn_rate, entity:product:nps
  CONFIDENCE_FLOOR 0.7
  INCLUDE risk_flags, recommendations
```

This evaluates all three entities as a set: the confidence floor (weakest link), average reputation, certification coverage (2 of 3 certified? All 3?), and freshness spread. If NPS hasn't been updated in 30 days, it flags `stale` and recommends `REFRESH entity:product:nps`. If churn_rate is uncertified, it recommends `CERTIFY entity:product:churn_rate`. The agent knows exactly how much to trust the data set before presenting it.

---

### Category 4: Governance

#### SIGNAL — Quality Feedback

Agents write quality assessments back into the semantic layer, building a distributed trust network maintained by every agent in the ecosystem. SIGNAL is how agents curate context — not just consume it.

**Syntax:**

```
SIGNAL reputation ON entity:<namespace>:<name>
  SCORE <score>
  EVIDENCE "<description>"
  AGENT agent:<identifier>
  [ESCALATE TO agent:<target>]
```

**Example:**

Intent: "The NPS data seems outdated — I want to flag it for the resource readiness team."

```
SIGNAL reputation ON entity:product:nps
  SCORE 0.4
  EVIDENCE "Data appears outdated based on last known update timestamp. Survey was conducted 45 days ago."
  AGENT agent:twin:michael
  ESCALATE TO agent:resource_readiness
```

This writes a reputation assessment of 0.4 (low) on the NPS entity with evidence explaining why, and escalates to the resource readiness agent for follow-up. The NPS entity's aggregate reputation score adjusts based on the distributed reputation network's aggregation algorithm.

---

#### CERTIFY — Governance Lifecycle

Manages the definition lifecycle through proposal, review, and certification phases. Definitions emerge bottom-up from practitioners, get refined by service agents, and require human authority for certification.

**Syntax:**

```
CERTIFY entity:<namespace>:<name>
  STATUS proposed | under_review | certified | contested | superseded
  [AUTHORITY <identifier>]
  [EVIDENCE "<description>"]
```

**Certification lifecycle:**

```
nil ─► proposed ─► under_review ─► certified ─► contested ─► under_review
                                       │                          │
                                       ▼                          ▼
                                   superseded ──► proposed ──► …
```

- `proposed → under_review → certified` is the forward path.
- `certified → contested` is the outcome of an UPDATE proposing a `redefinition` or `reclassification` on a certified entity. The change is deferred to a pending `UpdateRecord` and is not applied until the contest resolves.
- `contested → under_review` is the only transition out of `contested` — review the pending update, then re-certify or revert.
- `superseded` is **non-terminal**: `superseded → proposed` allows a retired entity to be revived into the lifecycle. An UPDATE on a superseded entity also revives it in a single step (certification resets to `nil`, reputation resets to 0.5).

The AUTHORITY and EVIDENCE fields accept free-form strings (including colons and other special characters). Each CERTIFY operation creates an audit record with the certifying agent's identity, timestamp, and evidence chain.

**Example — Full lifecycle:**

Step 1: An agent proposes certification after validating the entity.

```
CERTIFY entity:finance:arr
  STATUS proposed
  AUTHORITY twin:michael
  EVIDENCE "Validated ARR metric definition against finance team standards. Reputation 0.95, owner confirmed."
```

Step 2: A peer reviews the proposal.

```
CERTIFY entity:finance:arr
  STATUS under_review
  AUTHORITY twin:michael
  EVIDENCE "Peer review completed by finance operations lead."
```

Step 3: The entity is certified as an organizational standard.

```
CERTIFY entity:finance:arr
  STATUS certified
  AUTHORITY twin:michael
  EVIDENCE "ARR definition certified as organizational standard. Matches GAAP SaaS revenue recognition criteria."
```

After certification, RESOLVE on this entity returns `certified: true` with the certifying authority and timestamp in the quality metadata.

---

### Category 5: Evolution

#### UPDATE — Governed Knowledge Evolution

Evolves the content of an existing entity while preserving its semantic address. The entity's namespace and name are stable across updates — only description, type, evidence, and confidence may change — so every inbound reference (`DERIVED_FROM`, relationship edges, certification records) remains valid. Every UPDATE writes a `VersionRecord` node linked from the entity by `PREVIOUS_VERSION`, capturing the prior state as an immutable audit snapshot.

**Syntax:**

```
UPDATE entity:<namespace>:<name>
  CHANGE_TYPE correction | refresh | scope_change | redefinition | reclassification
  [DESCRIPTION "<new_description>"]
  [TYPE <new_entity_type>]
  [EVIDENCE "<rationale>"]
  [CONFIDENCE <score>]
```

**Parameters:**

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| entity | Yes | — | Semantic address of the entity being updated |
| CHANGE_TYPE | Yes | — | Semantic category of the change (see below) |
| DESCRIPTION | No | Unchanged | New description text |
| TYPE | No | Unchanged | New entity type identifier |
| EVIDENCE | No | — | Rationale for the change; recorded on the VersionRecord |
| CONFIDENCE | No | Unchanged | New confidence score in `[0.0, 1.0]` |

**Change types:**

| Change type | Meaning |
|-------------|---------|
| `correction` | Fix a factual error in the current content |
| `refresh` | Update to current values without semantic change |
| `scope_change` | Re-scope without redefinition |
| `redefinition` | Change the entity's meaning |
| `reclassification` | Change the entity's type |

**Governance matrix.** The outcome of an UPDATE depends on the entity's current certification status and the requested `change_type`:

| Current status | `correction`, `refresh`, `scope_change` | `redefinition`, `reclassification` |
|----------------|-----------------------------------------|------------------------------------|
| `nil` / `proposed` | Apply; preserve certification | Apply; reset certification to `nil` |
| `under_review` | Apply; preserve certification | **Blocked** — complete the review first |
| `certified` | Apply; preserve certification | **Contest** — entity transitions to `contested`, a pending `UpdateRecord` is written, change is deferred to governance review |
| `contested` | Blocked — contest in progress | Blocked — contest in progress |
| `superseded` | Apply; revive (certification → `nil`, reputation → 0.5) | Apply; revive (certification → `nil`, reputation → 0.5) |

A contested entity rejects all further UPDATEs until the contest resolves (via a `CERTIFY` transition out of `contested → under_review`, then forward).

**VersionRecord schema.** Every UPDATE writes an audit node with the following fields:

```
VersionRecord {
  record_id:              <UUIDv4>,
  entity_namespace:       <string>,
  entity_name:            <string>,
  agent_id:               <string>,
  change_type:            <one of the five above>,
  evidence:               <string>,
  status:                 "applied" | "pending_review",
  previous_description:   <string>,
  previous_type:          <string>,
  previous_status:        <string>,
  previous_reputation:    <float>,
  previous_confidence:    <float>,
  proposed_description:   <string>,    # pending_review only
  proposed_type:          <string>,    # pending_review only
  proposed_confidence:    <float>,     # pending_review only
  timestamp:              <ISO 8601>
}
```

Applied updates are linked from the entity via `PREVIOUS_VERSION`. Pending contests are linked via `PENDING_UPDATE`; they become `PREVIOUS_VERSION` edges only when the contest resolves and the change is committed.

**Example — Applied correction on a certified entity:**

Intent: "The churn_rate denominator was documented incorrectly — it's rolling 30-day MRR, not ARR."

```
UPDATE entity:product:churn_rate
  CHANGE_TYPE correction
  DESCRIPTION "Customer churn calculated as lost MRR / rolling 30-day MRR"
  EVIDENCE "Audit surfaced inconsistent denominator against finance standard"
  CONFIDENCE 0.9
```

Result: the entity's description is updated, a `VersionRecord` with `status: "applied"` captures the prior description, and certification is preserved.

**Example — Redefinition on a certified entity (deferred to governance):**

Intent: "Churn rate should include expansion downgrades, not just full cancellations."

```
UPDATE entity:product:churn_rate
  CHANGE_TYPE redefinition
  DESCRIPTION "Net revenue churn including cancellations and expansion downgrades"
  EVIDENCE "Revised definition approved at Q2 revenue ops review"
  CONFIDENCE 0.8
```

Result: the entity transitions from `certified` to `contested`. A `VersionRecord` with `status: "pending_review"` captures both the prior state and the proposed change. No DESCRIPTION change is applied to the entity itself. The response carries a pending-review envelope; subsequent UPDATEs are blocked until a governance agent resolves the contest via `CERTIFY … STATUS under_review`.

---

### Category 6: Maintenance & Perception

#### REFRESH — Context Maintenance

Two modes: CHECK is a lightweight staleness scan that identifies entities exceeding their freshness threshold. EXPAND re-reads a context branch and expands the scan radius to capture peripheral context shifts that naive TTL-based invalidation would miss.

**Syntax:**

```
REFRESH CHECK active_context
  [WHERE age > <duration>]
  [RETURN stale_items]

REFRESH EXPAND entity:<namespace>:<name>
  [RADIUS <integer>]
```

**Example — Staleness scan:**

Intent: "Check if any of my active context has gone stale."

```
REFRESH CHECK active_context
  WHERE age > 4h
  RETURN stale_items
```

This scans all entities in the agent's active context set and returns any that haven't been updated in more than 4 hours, along with recommendations for which ones to re-resolve.

**Example — Peripheral expansion:**

Intent: "The churn data changed — check if anything related has shifted too."

```
REFRESH EXPAND entity:product:churn_rate
  RADIUS 2
```

This re-reads churn_rate and expands outward 2 hops through the relationship graph, checking whether any related entities (NPS, ARR, feature_adoption) have also changed since the agent last resolved them.

---

#### AWARENESS — Ecosystem Perception

Ambient perception of the agentic environment — which other agents are operating within scope, what their intent is, and what resources they hold. AWARENESS enables coordination without explicit messaging.

**Syntax:**

```
AWARENESS
  [WITHIN scope:<scope>]
  [RETURN active_agents, intent, resources]
  [FILTER role:<role>]
```

**Example:**

Intent: "Who else is working on churn analysis right now?"

```
AWARENESS
  WITHIN scope:company:product
  RETURN active_agents, intent
  FILTER role:twin
```

This returns all active Teipsum Agents (personal agents, filtered by `role:twin`) operating within the product scope, along with their declared intent. If another agent is also analyzing churn data, the requesting agent can coordinate or defer rather than duplicating work.

---

## 6. Scope Model

### Hierarchical Scope Tree

Scopes form a tree: `scope:company` → `scope:company:finance`, `scope:company:product`, `scope:company:engineering`, etc. Scope determines what context is visible and who can govern it.

### Hierarchical Containment and Scope

Entity addresses are themselves hierarchical (Section 4) and the engine treats a deep address as a path through container entities, not just a flat key. When an agent asserts `entity:product:retention:cohort:q4:weekly`, the engine creates whichever interior containers are missing (`retention`, `cohort`, `q4` if they do not yet exist), writes a `CONTAINS` edge from each parent to its child, and assigns each container the asserting agent's active scope. Container scopes do **not** widen with depth — every auto-created node lives in the asserting agent's scope.

For every read or write that names a hierarchical address, scope authorization is checked at every node from root to leaf. **A denial at any ancestor returns `entity_not_found`, never `scope_access`** — agents cannot infer the existence or shape of subtrees in scopes they cannot see. This applies uniformly to RESOLVE, DISCOVER (anchor and prefix modes), ASSERT (target validation in `DERIVED_FROM` and `RELATIONSHIPS`), CERTIFY, SIGNAL, TRACE, and UPDATE. The same rule governs DISCOVER prefix mode's branch pruning: a subtree whose root the agent cannot see is omitted entirely, and the prefix walk does not descend into it.

After every ASSERT the engine runs a post-write integrity check verifying that the leaf's full `CONTAINS` chain back to the root is intact and that every interior container exists. A failed check rolls the assertion back rather than leaving the graph in a partial state.

### Bidirectional Visibility

The scope visibility model is bidirectional along the hierarchy:

- **Parent sees children.** An agent at `scope:company` can see entities in `scope:company:finance`, `scope:company:product`, and all other descendant scopes. This is essential for company-wide admin agents.
- **Child sees ancestors.** An agent at `scope:company:finance` can see entities in `scope:company` (the fallback chain is preserved).
- **Siblings are isolated.** An agent at `scope:company:finance` cannot see entities in `scope:company:engineering`. This maintains organizational security boundaries.

`visible_scopes/1` returns: self + ancestors + descendants. Siblings are excluded.

### Scope Access Examples

| Agent Scope | Can See | Cannot See |
|-------------|---------|------------|
| `scope:company` | All descendant scopes (finance, product, engineering, hr, customer_success) | — |
| `scope:company:finance` | `scope:company` (ancestor) | `scope:company:engineering` (sibling) |
| `scope:company:product` | `scope:company` (ancestor) | `scope:company:hr` (sibling) |

---

## 7. Standard Return Envelope

Every CQR operation returns a response within a standard envelope. Quality metadata is present on every response without exception.

```json
{
  "data": [...],
  "quality": {
    "freshness": "<duration>",
    "confidence": 0.0-1.0,
    "reputation": 0.0-1.0,
    "owner": "<owner_identifier>",
    "lineage": ["<version_chain>"],
    "certified_by": "<authority> | null",
    "certified_at": "<timestamp> | null",
    "provenance": "<source_description>"
  },
  "sources": ["<adapter_ids>"],
  "conflicts": [...],
  "cost": {
    "adapters_queried": 1,
    "operations": 3,
    "execution_ms": 8
  }
}
```

The cost accounting feeds directly into an agentic budget model where teams receive allocations of context operations, creating natural accountability and measurable ROI for AI investments.

---

## 8. MCP Delivery Interface

CQR is delivered to AI agents through the Model Context Protocol (MCP), an open standard for connecting large language models to external data sources and tools.

### Tools

| MCP Tool | CQR Primitive | Parameters | Description |
|----------|--------------|------------|-------------|
| `cqr_resolve` | RESOLVE | entity, scope, freshness, reputation | Canonical entity retrieval with quality metadata |
| `cqr_discover` | DISCOVER | topic, depth, direction, scope | Neighborhood scan with direction control |
| `cqr_assert` | ASSERT | entity, type, description, intent, derived_from, scope, confidence, relationships | Agent write with mandatory INTENT and DERIVED_FROM paper trail |
| `cqr_assert_batch` | ASSERT (batched) | entities | Batched ASSERT for high-throughput writes |
| `cqr_certify` | CERTIFY | entity, status, authority, evidence | Governance lifecycle management |
| `cqr_signal` | SIGNAL | entity, score, evidence | Reputation assessment preserving certification status |
| `cqr_update` | UPDATE | entity, change_type, description, type, evidence, confidence | Governed content evolution with VersionRecord audit chain |
| `cqr_trace` | TRACE | entity, depth, time_window | Provenance walk: assertion, certification, signal, version history |
| `cqr_refresh` | REFRESH | threshold, scope | Staleness scan across visible scopes |
| `cqr_compare` | COMPARE | entities, attributes, scope | Multi-entity side-by-side analysis |
| `cqr_hypothesize` | HYPOTHESIZE | entity, change, depth, confidence_threshold | Outbound impact projection |
| `cqr_anchor` | ANCHOR | entities, confidence_floor | Composite confidence floor for a reasoning chain |
| `cqr_awareness` | AWARENESS | scope, role | Ambient perception of other agents in scope |

### Resources

| MCP Resource | URI | Description |
|-------------|-----|-------------|
| Agent Session | `cqr://session` | Current agent identity, scope, permissions, visible scopes, connected adapters, protocol version, uptime, and session metadata |

### Session Resource

The `cqr://session` resource provides the agent's full connection context:

```json
{
  "agent_id": "twin:michael",
  "agent_scope": "scope:company",
  "visible_scopes": [
    "scope:company",
    "scope:company:finance",
    "scope:company:product",
    "scope:company:engineering",
    "scope:company:hr",
    "scope:company:customer_success"
  ],
  "permissions": ["resolve", "discover", "certify"],
  "connected_adapters": ["grafeo"],
  "protocol": "CQR/1.0",
  "server_version": "0.1.0",
  "uptime_seconds": 34,
  "connection": {
    "transport": "stdio",
    "connected_at": "2026-04-10T21:58:56Z",
    "session_id": "40c8fb87-ec9d-44a7-b7f1-f3cd4ed563db"
  }
}
```

### Governance Invariance

The scope-first semantics, quality metadata annotation, conflict preservation, and cost accounting behaviors are identical regardless of delivery interface (MCP, REST API, gRPC, direct Elixir call). Governance enforcement occurs at the context assembly engine level, below any delivery interface. No delivery mechanism can bypass, weaken, or alter governance behavior.

---

## 9. Implementation Reference

### Current Stack

| Component | Technology | Notes |
|-----------|-----------|-------|
| Runtime | Elixir/OTP 27 (BEAM VM) | Supervision trees, fault tolerance, hot code reload |
| Database | Grafeo v0.5.34 | Pure-Rust embeddable graph DB, Apache 2.0. Supports LPG, GQL, Cypher, HNSW vector search, BM25 full-text, ACID transactions |
| Integration | Rustler NIF | Grafeo embedded directly into the BEAM — no separate process, no network latency |
| Transport | MCP over stdio | JSON-RPC 2.0. SSE transport planned for remote connections |
| Repository | `github.com/teipsum/cqr-mcp` | GPG-signed commits |

### Architecture

The CQR MCP server is a self-contained appliance. Grafeo is embedded directly into the BEAM via a Rustler NIF — no separate database container, no Docker, no network latency between engine and storage. The database starts with the OTP application and lives inside the supervision tree.

The governance invariance boundary is `Cqr.Engine.execute/2` — the single entry point through which all operations pass, regardless of delivery interface. Everything above the engine (MCP server, REST API, direct call) goes through this boundary. Everything below it (adapters, scope resolution, quality annotation) is delivery-agnostic.

### Adapter Behavior Contract

Any storage backend participates in CQR by implementing the adapter behaviour:

- `resolve/3` — canonical retrieval by namespace:name within accessible scopes
- `discover/3` — graph traversal from anchor entity with direction and depth control
- `assert/3` — write a governed, uncertified entity with provenance
- `certify/3` — move an entity through the certification lifecycle
- `signal/3` — write a reputation assessment with evidence
- `update/3` — evolve an entity's content with VersionRecord audit chain and governance matrix enforcement
- `trace/3` — walk the provenance chain of an entity
- `refresh_check/3` — staleness scan across visible scopes
- `compare/3`, `hypothesize/3`, `anchor/3` — reasoning callbacks
- `awareness/3` — ambient agent perception in scope
- `capabilities/0` — declared primitive coverage used by the planner
- `health_check/0` — connectivity and version status

Write, evolution, reasoning, and perception callbacks are optional. Read-only or partial backends declare their supported primitives through `capabilities/0` and the engine planner routes around the rest.

The Grafeo adapter is the reference implementation. Additional adapters (PostgreSQL/pgvector, Neo4j, Elasticsearch, TimescaleDB) can be added without modifying the engine — adapter registration is a configuration change, not a code change.

### Validated Results

| Metric | Value |
|--------|-------|
| Test suite | 234 ExUnit tests, 0 failures |
| Syntactic accuracy | 97% (qwen2.5:14b, 100-intent validation suite) |
| Semantic accuracy | 96% (qwen2.5:14b, 100-intent validation suite) |
| Scope resolution latency | Sub-millisecond (ETS-cached scope tree) |
| Sample dataset | 27 entities, 6 scopes, 17 relationships |

---

## 10. Protocol Positioning

CQR sits above orchestration frameworks in the agent infrastructure stack:

| Protocol | Layer | Function |
|----------|-------|----------|
| MCP | Agent-to-tool | Connectivity between agents and external tools/data sources |
| A2A | Agent-to-agent | Communication and coordination between agents |
| CQR | Agent-to-governed-context | Interaction with organizational knowledge under governance constraints |

CQR is the governed context infrastructure layer that enterprise agents depend on — not a competing agent platform or orchestration framework. It solves the governance gap that no other protocol addresses: how do AI agents interact with organizational knowledge in a way that is scoped, quality-annotated, auditable, and trustworthy?

### License

This specification is licensed under the Business Source License 1.1 (BSL 1.1). The licensed work is the CQR Protocol Specification and associated implementation. The change date is April 8, 2030, at which point the license automatically converts to MIT License. Prior to the change date, use is permitted for production purposes. After April 8, 2030, the specification and implementation are available under the permissive terms of MIT License with no restrictions. Full license terms are available in the LICENSE file.

**CQR Protocol Specification v1.0 · April 2026 ·**

**Copyright © 2026 Michael Cram. All rights reserved.**
