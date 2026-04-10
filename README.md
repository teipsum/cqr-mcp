# CQR — Cognitive Query Resolution

## Protocol Specification v1.0

**April 2026**

The native context interaction language of the UNICA platform.

**Note:** CQR was previously named SEQUR (Semantic Query Resolution). The USPTO provisional patent application was filed under the SEQUR name. All protocol semantics, claims, and architectural properties described in the patent apply to CQR. The rename reflects the protocol's evolution from seven primitives to eleven, and its broader scope as a cognitive operations protocol rather than a purely semantic query language. "C-Q-R" is pronounced like "seeker."

---

## Overview

CQR (Cognitive Query Resolution) is designed for machine cognition as the primary consumer. AI agents generate CQR expressions to interact with organizational context, and the UNICA platform translates those expressions into operations across heterogeneous storage backends.

This document defines the formal specification: the grammar, type system, primitive semantics, return envelope, error model, and agent generation contract.

## Design Principles

- **Agents are the users.** Every syntactic and semantic decision optimizes for reliable LLM generation, not human developer ergonomics. Primitives are unambiguous, keywords are semantically clear, and the grammar avoids constructs that LLMs commonly hallucinate.

- **Cognitive operations, not data operations.** CQR primitives map to reasoning patterns (resolve a canonical concept, orient in a neighborhood, trace a causal chain, assert new context) rather than data manipulation patterns (select, join, filter).

- **Quality metadata is mandatory.** Every CQR response includes provenance, freshness, confidence, and reputation data. An agent always knows how much to trust what it received.

- **Scope is first-class.** Every expression operates within a defined scope hierarchy. Scope is not a filter applied after retrieval — it is a fundamental part of the query semantics that determines what is visible, what is authoritative, and what falls back to broader scopes.

- **Two-tier trust model.** Context exists in two trust states: asserted (written by agents, governed but uncertified) and certified (approved through the CERTIFY governance lifecycle). Both are visible; trust level is explicit metadata.

- **Fail informatively.** When an expression cannot be satisfied, the error response gives the agent enough information to reason about what went wrong and what to try next. Errors are cognitive inputs, not exceptions.

---

## Type System

CQR operates over a small, well-defined set of types. Constraining the type system is deliberate — it reduces the surface area for LLM generation errors and keeps the language semantically focused.

### Core Types

| Type | Syntax | Description |
|------|--------|-------------|
| Entity | `entity:<namespace>:<name>` | A named concept in the semantic repository. Namespaced to prevent collisions across domains. |
| Scope | `scope:<segment>[:<segment>]` | An organizational boundary that defines visibility, authority, and access control. Scopes form a hierarchy. |
| Duration | `<number><unit>` | A time span. Units: m (minutes), h (hours), d (days), w (weeks). |
| Score | `<decimal>` | A 0.0–1.0 value for reputation thresholds and strength scores. |
| Agent Reference | `agent:<identifier>` | A reference to a specific agent or agent role. |
| String Literal | `"<text>"` | A quoted text value for evidence descriptions and search terms. |
| Direction | `outbound \| inbound \| both` | Edge traversal direction for DISCOVER operations. |

---

## Cognitive Operation Primitives

CQR defines 11 cognitive operation primitives organized into 5 categories. Each primitive maps to a reasoning pattern that agents actually perform.

### Category 1: Context Resolution

#### RESOLVE — Canonical Retrieval

Retrieve a canonical entity by semantic address from the nearest matching scope, with quality metadata.

```
RESOLVE entity:<namespace>:<name>
  [FROM scope:<scope>]
  [WITH freshness < <duration>]
  [WITH reputation > <score>]
  [INCLUDE <annotation_list>]
  [FALLBACK scope:<s1> -> scope:<s2> [-> scope:<sN>]]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| entity | Yes | — | The semantic address of the concept to resolve |
| FROM scope | No | Agent's active scope | The scope to search first |
| WITH freshness | No | No constraint | Maximum age of the returned value |
| WITH reputation | No | No constraint | Minimum reputation score threshold |
| INCLUDE | No | freshness, confidence | Metadata annotations to include |
| FALLBACK | No | Walk up scope hierarchy | Explicit fallback chain |

Optional clauses may appear in any order. The parser is order-insensitive for optional clauses within each primitive — a deliberate design decision to accommodate the variable ordering tendencies of LLM generation.

#### DISCOVER — Neighborhood Scan

The orientation primitive. Returns a navigable map of concepts related to an anchor entity or search term, annotated with quality signals. DISCOVER combines graph traversal (relationship-based) and semantic similarity search (embedding-based), merging results from both modalities.

```
DISCOVER concepts
  RELATED TO entity:<namespace>:<name> | "<search_term>"
  [WITHIN scope:<s1> [, scope:<s2>, ...]]
  [DEPTH <integer>]
  [DIRECTION outbound | inbound | both]
  [ANNOTATE <annotation_list>]
  [LIMIT <integer>]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| RELATED TO | Yes | — | Anchor entity or free-text search term |
| WITHIN scope | No | Agent's visible scopes | Scope constraint |
| DEPTH | No | 2 | Graph traversal depth |
| DIRECTION | No | both | Edge traversal direction |
| ANNOTATE | No | freshness, reputation | Metadata annotations |
| LIMIT | No | No limit | Maximum results |

**Direction semantics:** Edges are stored once, directionally. The relationship type always reads in its original stored direction (e.g., CONTRIBUTES_TO always means source contributes to target). The `direction` parameter controls which edges are traversed:

- `outbound` — returns entities the anchor points TO (the anchor is the source)
- `inbound` — returns entities that point AT the anchor (the anchor is the target)
- `both` — returns the union, each result tagged with a `direction` field

**Design rationale:** DISCOVER defaults to `both` because it is the exploration primitive — "show me the full neighborhood." Directed traversal for causal and impact analysis is handled by TRACE (inherently inbound/lineage) and HYPOTHESIZE (inherently outbound/impact). The underlying graph traversal engine is shared across all three primitives; they differ in metadata enrichment and semantic intent, not in traversal mechanics.

### Category 2: Context Creation

#### ASSERT — Agent-Written Context

Agents write governed but uncertified context into the organizational knowledge graph. Asserted entities are visible and queryable but carry lower trust than certified entities — "rumor with a paper trail."

```
ASSERT entity:<namespace>:<name>
  TYPE <entity_type>
  DESCRIPTION "<description>"
  INTENT "<why_this_is_being_asserted>"
  DERIVED_FROM entity:<namespace>:<name> [, entity:<namespace>:<name>, ...]
  [IN scope:<scope>]
  [CONFIDENCE <score>]
```

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

### Category 3: Reasoning

#### TRACE — Temporal & Causal Reasoning

Returns trajectories rather than snapshots — how an entity evolved, what caused state changes, and who acted. TRACE walks the lineage chain (inherently inbound/causal direction).

```
TRACE entity:<namespace>:<name>
  [OVER last <duration>]
  [INCLUDE state_transitions, actors, triggers]
  [DEPTH causal:<integer>]
```

#### HYPOTHESIZE — Impact Projection

Speculative impact analysis. Given an assumed change to an entity, projects outbound effects through the relationship graph with confidence scoring.

```
HYPOTHESIZE CHANGE entity:<namespace>:<name>
  BY <delta_description>
  [DEPTH <integer>]
  [CONFIDENCE_THRESHOLD <score>]
```

#### COMPARE — Multi-Entity Analysis

Side-by-side comparison of two or more entities, surfacing shared relationships, divergent metadata, and quality differentials.

```
COMPARE entity:<ns1>:<n1>, entity:<ns2>:<n2> [, entity:<ns3>:<n3>, ...]
  [ON <attribute_list>]
  [WITHIN scope:<scope>]
```

#### ANCHOR — Epistemic Grounding

Evaluates the composite quality of a set of resolved context entities — the reasoning chain's overall trustworthiness. Identifies weakest links, risk flags, and generates actionable recommendations.

```
ANCHOR entity:<ns1>:<n1>, entity:<ns2>:<n2> [, ...]
  [CONFIDENCE_FLOOR <score>]
  [INCLUDE risk_flags, recommendations]
```

### Category 4: Governance

#### SIGNAL — Quality Feedback

Agents write quality assessments back into the semantic layer, building a distributed trust network maintained by every agent in the ecosystem.

```
SIGNAL reputation ON entity:<namespace>:<name>
  SCORE <score>
  EVIDENCE "<description>"
  AGENT agent:<identifier>
  [ESCALATE TO agent:<target>]
```

#### CERTIFY — Governance Lifecycle

Manages the definition lifecycle. Definitions emerge bottom-up from practitioners, get refined by service agents, and require human authority for certification.

```
CERTIFY entity:<namespace>:<name>
  STATUS proposed | under_review | certified | superseded
  [AUTHORITY <identifier>]
  [EVIDENCE "<description>"]
```

**Certification lifecycle:** `proposed → under_review → certified → superseded`

The AUTHORITY and EVIDENCE fields accept free-form strings (including colons and other special characters). Each CERTIFY operation creates an audit record with the certifying agent's identity, timestamp, and evidence chain.

### Category 5: Maintenance & Perception

#### REFRESH — Context Maintenance

Two modes: CHECK is a lightweight staleness scan. EXPAND re-reads a context branch and expands the scan radius to capture peripheral context shifts.

```
REFRESH CHECK active_context
  [WHERE age > <duration>]
  [RETURN stale_items]

REFRESH EXPAND entity:<namespace>:<name>
  [RADIUS <integer>]
```

#### AWARENESS — Ecosystem Perception

Ambient perception of the agentic environment — which other agents are operating within scope, what their intent is, and what resources they hold.

```
AWARENESS
  [WITHIN scope:<scope>]
  [RETURN active_agents, intent, resources]
  [FILTER role:<role>]
```

---

## Scope Model

### Hierarchical Scope Tree

Scopes form a tree: `scope:company` → `scope:company:finance`, `scope:company:product`, `scope:company:engineering`, etc. Scope determines what context is visible and who can govern it.

### Bidirectional Visibility

The scope visibility model is bidirectional along the hierarchy:

- **Parent sees children.** An agent at `scope:company` can see entities in `scope:company:finance`, `scope:company:product`, and all other descendant scopes. This is essential for company-wide admin agents.
- **Child sees ancestors.** An agent at `scope:company:finance` can see entities in `scope:company` (the fallback chain is preserved).
- **Siblings are isolated.** An agent at `scope:company:finance` cannot see entities in `scope:company:engineering`. This maintains organizational security boundaries.

`visible_scopes/1` returns: self + ancestors + descendants. Siblings are excluded.

---

## Standard Return Envelope

Every CQR operation returns a response within a standard envelope:

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

Quality metadata is present on every response. No exceptions.

---

## MCP Delivery Interface

### Tools

CQR primitives are exposed as MCP tools:

| MCP Tool | CQR Primitive | Description |
|----------|--------------|-------------|
| `cqr_resolve` | RESOLVE | Canonical entity retrieval with quality metadata |
| `cqr_discover` | DISCOVER | Neighborhood scan with direction control |
| `cqr_certify` | CERTIFY | Governance lifecycle management |

### Resources

| MCP Resource | URI | Description |
|-------------|-----|-------------|
| Agent Session | `cqr://session` | Current agent identity, scope, permissions, visible scopes, connected adapters, protocol version, uptime, session metadata |

### Session Resource Schema

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

The scope-first semantics, quality metadata annotation, conflict preservation, and cost accounting behaviors are identical regardless of delivery interface (MCP, REST API, gRPC, direct call). Governance enforcement occurs at the context assembly engine level, below any delivery interface.

---

## Implementation

### Current Stack

- **Runtime:** Elixir/OTP (BEAM VM)
- **Database:** Grafeo (pure-Rust embeddable graph DB, Apache 2.0)
- **Transport:** MCP over stdio (JSON-RPC 2.0)
- **Repository:** `github.com/teipsum/cqr-mcp`

### Architecture

The CQR MCP server is a self-contained appliance. Grafeo is embedded directly into the BEAM via a Rustler NIF — no separate database container, no Docker, no network latency between engine and storage. `mix deps.get && mix run --no-halt` is the entire setup.

### Adapter Behaviour Contract

Any storage backend participates in CQR by implementing the adapter behaviour:

- `resolve/3` — canonical retrieval by namespace:name within accessible scopes
- `discover/3` — graph traversal from anchor entity with direction and depth control
- `health_check/0` — connectivity and version status

### Validated Results

- 234 ExUnit tests passing
- 97%/96% syntactic/semantic accuracy on qwen2.5:14b (100-intent validation suite)
- Sub-millisecond scope resolution (ETS-cached scope tree)
- 27 entities, 6 scopes, 17 relationships in sample organizational dataset

---

## Protocol Positioning

CQR sits above orchestration frameworks in the agent infrastructure stack:

- **MCP** (Model Context Protocol) = agent-to-tool connectivity
- **A2A** (Agent2Agent Protocol) = agent-to-agent communication
- **CQR** (Cognitive Query Resolution) = agent-to-governed-context interaction

CQR is the governed context infrastructure layer that enterprise agents depend on — not a competing agent platform or orchestration framework. It solves the governance gap that no other protocol addresses.

### Open Protocol Model

CQR is the open protocol specification. UNICA is the commercial platform. This mirrors the PostgreSQL/RDS relationship: CQR defines how agents interact with governed context; UNICA provides the enterprise-grade platform that implements, manages, and scales it.
