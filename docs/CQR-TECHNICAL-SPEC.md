> **⚠ HISTORICAL DOCUMENT — SUPERSEDED**
>
> This is the v0.1 March 2026 draft, written before the protocol was renamed from **SEQUR (Semantic Query Resolution)** to **CQR (Cognitive Query Resolution)** and before the addition of the ASSERT, HYPOTHESIZE, COMPARE, and ANCHOR primitives. The protocol now defines **11 cognitive operation primitives** in 5 categories, not the 7 documented here, and the scope visibility model is bidirectional rather than ancestors-only.
>
> The **canonical CQR Protocol Specification** is `README.md` at the repository root (v1.0, April 2026).
>
> This document is preserved unchanged below for patent-evidence continuity. The USPTO provisional patent application was filed under the SEQUR name; all claims and semantics in the patent apply to CQR. The terminology in this document — "Semantic Query Resolution," 7 primitives, ancestors-only scope traversal — should be read as the historical state at the priority date, not as the current protocol.

---

**CQR** (originally filed as **SEQUR**)

Semantic Query Resolution

Native Language for Governed Context

Technical Specification v0.1

DRAFT — March 2026

**CONFIDENTIAL**

# Table of Contents

# Overview

CQR (Semantic Query Resolution) is the native context interaction language of the host platform. It is designed for machine cognition as the primary consumer—agents generate CQR expressions to interact with organizational context, and the host platform translates those expressions into operations across heterogeneous storage backends.

This document defines the formal specification for CQR: the grammar, type system, primitive semantics, return envelope, error model, and agent generation contract. It serves as both the implementation reference for the NimbleParsec parser and the validation reference for testing LLM generation accuracy.

## Design Principles

- **Agents are the users. **Every syntactic and semantic decision optimizes for reliable LLM generation, not human developer ergonomics. Primitives are unambiguous, keywords are semantically clear, and the grammar avoids constructs that LLMs commonly hallucinate.

- **Cognitive operations, not data operations. **CQR primitives map to reasoning patterns (resolve a canonical concept, orient in a neighborhood, trace a causal chain) rather than data manipulation patterns (select, join, filter).

- **Quality metadata is mandatory. **Every CQR response includes provenance, freshness, confidence, and reputation data. An agent always knows how much to trust what it received.

- **Scope is first-class. **Every expression operates within a defined scope hierarchy. Scope is not a filter applied after retrieval—it is a fundamental part of the query semantics that determines what is visible, what is authoritative, and what falls back to broader scopes.

- **Fail informatively. **When an expression cannot be satisfied, the error response gives the agent enough information to reason about what went wrong and what to try next. Errors are cognitive inputs, not exceptions.

# Type System

CQR operates over a small, well-defined set of types. Constraining the type system is deliberate—it reduces the surface area for LLM generation errors and keeps the language semantically focused.

## Core Types

| **Type** | **Syntax** | **Description** | **Examples** |
| --- | --- | --- | --- |
| Entity | entity:<namespace>:<name> | A named concept in the semantic repository. Namespaced to prevent collisions across domains. | entity:finance:arr, entity:product:churn_rate, entity:hr:headcount |
| Scope | scope:<name> | An organizational boundary that defines visibility, authority, and access control. Scopes form a hierarchy. | scope:finance, scope:product:growth, scope:global |
| Duration | <number><unit> | A time span used for freshness constraints and temporal queries. Units: m (minutes), h (hours), d (days), w (weeks). | 24h, 7d, 90d, 30m |
| Score | <decimal> | A value between 0.0 and 1.0 used for reputation thresholds and confidence levels. | 0.7, 0.5, 0.95 |
| Depth | <integer> | A traversal depth for neighborhood scans and causal chain following. | 1, 2, 3 |
| Agent Reference | agent:<identifier> | A reference to a specific agent or agent role in the ecosystem. | agent:semantic_admin, agent:resource_readiness, agent:twin:user_42 |
| String Literal | "<text>" | A quoted text value used for evidence descriptions and search terms. | "3/5 resolutions returned stale data" |
| Annotation List | <annotation>, <annotation> | A comma-separated list of metadata fields to include in the response. | freshness, confidence, owner, lineage, reputation |
| Role Filter | role:<name> | A filter for agent types in AWARENESS queries. | role:twin, role:service, role:worker, role:manager |

## Scope Hierarchy

Scopes are hierarchical, using colon-delimited nesting. A query against a parent scope includes all child scopes unless explicitly restricted. The hierarchy supports the six context scoping levels defined in the host platform architecture:

scope:global                    → organizational root

scope:finance                   → domain level

scope:finance:revenue           → subdomain

scope:finance:revenue:recurring → specific area

Scope resolution follows nearest-match semantics: when a RESOLVE targets a scope, the engine first searches the exact scope, then walks up the hierarchy until it finds a match or reaches scope:global. This fallback behavior can be overridden with explicit FALLBACK chains.

## Entity Namespacing

Entities are namespaced to prevent collisions. The namespace typically corresponds to the owning domain but is not required to match the query scope—an agent in scope:product can RESOLVE entity:finance:arr if it has the appropriate permissions.

Entity names use snake_case and must be stable identifiers in the semantic definition repository. Display names and descriptions are metadata on the entity definition, not part of the CQR address.

# Primitive Specifications

Each CQR primitive is defined by its syntax, semantics (what it does), parameters (what it accepts), return type (what it gives back), side effects (what state it modifies), and guarantees (what the caller can rely on).

## RESOLVE

**Purpose: **Retrieve a canonical entity by semantic address from the nearest matching scope, with quality metadata.

### Syntax

RESOLVE entity:<namespace>:<name>

  [FROM scope:<scope>]

  [WITH freshness < <duration>]

  [WITH reputation > <score>]

  [INCLUDE <annotation_list>]

  [FALLBACK scope:<s1> → scope:<s2> [→ scope:<sN>]]

### Parameters

| **Parameter** | **Required** | **Default** | **Description** |
| --- | --- | --- | --- |
| entity | Yes | — | The semantic address of the concept to resolve |
| FROM scope | No | Agent’s active scope | The scope to search first |
| WITH freshness | No | No constraint | Maximum age of the returned value |
| WITH reputation | No | No constraint | Minimum reputation score threshold |
| INCLUDE | No | freshness, confidence | Metadata annotations to include in the response |
| FALLBACK | No | Walk up scope hierarchy | Explicit fallback chain if the primary scope has no match |

### Return Envelope

Every RESOLVE returns a standard CQR response envelope:

{

  status: :resolved | :not_found | :stale | :below_reputation,

  entity: entity:<namespace>:<name>,

  value: <resolved_value>,

  source_scope: scope:<actual_scope_resolved_from>,

  source_adapter: <adapter_id>,

  metadata: {

    freshness: <duration_since_last_update>,

    confidence: <0.0-1.0>,

    reputation: <0.0-1.0>,

    owner: <owner_identifier>,

    lineage: [<definition_version_chain>],

    certified_by: <authority> | nil,

    certified_at: <timestamp> | nil

  },

  cost: {context_ops: 1, adapters_queried: [<adapter_ids>]}

}

### Semantics

- The engine looks up the entity in the semantic definition repository to find its canonical definition and the adapter(s) that hold its data.

- The engine checks scope permissions for the requesting agent.

- The engine queries the appropriate adapter(s) for the entity’s current value, starting from the FROM scope.

- If the entity is not found in the FROM scope, the engine either follows the explicit FALLBACK chain or walks up the scope hierarchy.

- If WITH freshness is specified and the entity’s last update exceeds the threshold, the engine returns status: :stale with the stale value and its actual freshness.

- If WITH reputation is specified and the entity’s reputation score is below the threshold, the engine returns status: :below_reputation with the value and its actual score.

- The engine annotates the response with the requested metadata and returns the envelope.

### Side Effects

RESOLVE is a read operation. It does not modify state. However, the Telemetry system emits a [:cqr, :resolve, :stop] event recording the operation, and the entity’s access counter is incremented in the reputation network (contributing to usage frequency tracking).

### Guarantees

- If status is :resolved, the value is the most current version available within the requested freshness and reputation constraints.

- The source_scope always reflects the actual scope the value was resolved from, which may differ from the requested scope if fallback occurred.

- The cost field always accurately reflects the context operations consumed.

## DISCOVER

**Purpose: **Map the conceptual neighborhood of an entity or topic, returning a navigable inventory of available context annotated with quality signals.

### Syntax

DISCOVER concepts

  RELATED TO entity:<namespace>:<name> | "<search_term>"

  [WITHIN scope:<s1> [, scope:<s2>, ...]]

  [DEPTH <integer>]

  [ANNOTATE <annotation_list>]

  [LIMIT <integer>]

### Parameters

| **Parameter** | **Required** | **Default** | **Description** |
| --- | --- | --- | --- |
| RELATED TO | Yes | — | The anchor entity or search term to explore around |
| WITHIN scope | No | Agent’s active scopes | Scope(s) to search within |
| DEPTH | No | 1 | How many relationship hops to traverse from the anchor |
| ANNOTATE | No | freshness, reputation | Metadata to include on each discovered concept |
| LIMIT | No | 20 | Maximum number of concepts to return |

### Return Envelope

{

  status: :discovered | :empty | :scope_not_found,

  anchor: entity:<namespace>:<name> | "<search_term>",

  concepts: [

    {

      entity: entity:<namespace>:<name>,

      relationship: <relationship_type>,

      distance: <hops_from_anchor>,

      scope: scope:<scope>,

      annotations: {freshness: ..., reputation: ..., owner: ...}

    },

    ...

  ],

  total_available: <integer>,

  cost: {context_ops: 1, adapters_queried: [<adapter_ids>]}

}

### Semantics

DISCOVER combines graph traversal (for relationship-based discovery) with semantic similarity search (for embedding-based discovery). When the anchor is an entity, the engine traverses the knowledge graph outward to DEPTH hops. When the anchor is a search term, the engine performs vector similarity search across entity embeddings in the specified scopes. Results from both modalities are merged, deduplicated, and annotated.

DISCOVER is the orientation primitive—it tells the agent what exists before it commits to retrieving specific items. It is intentionally lightweight: it returns entity references and metadata, not full entity values. The agent issues RESOLVE for specific items of interest after reviewing the neighborhood map.

### Side Effects

Read-only. Emits [:cqr, :discover, :stop] telemetry.

## TRACE

**Purpose: **Follow the temporal trajectory of an entity, returning state transitions, causal chains, and the actors who drove changes.

### Syntax

TRACE entity:<namespace>:<name>

  [FOR entity:<namespace>:<name>]

  OVER last <duration>

  [INCLUDE state_transitions [, actors] [, triggers]]

  [DEPTH causal:<integer>]

### Parameters

| **Parameter** | **Required** | **Default** | **Description** |
| --- | --- | --- | --- |
| entity | Yes | — | The entity whose trajectory to trace |
| FOR entity | No | — | Narrows the trace to changes related to a specific entity (e.g., trace deal_status FOR entity:acme_corp) |
| OVER last | Yes | — | The time window to trace over |
| INCLUDE | No | state_transitions | What aspects of the trajectory to return |
| DEPTH causal | No | 0 (no causal chain) | How many levels of cause-and-effect to follow from each state transition |

### Return Envelope

{

  status: :traced | :no_history | :entity_not_found,

  entity: entity:<namespace>:<name>,

  period: {from: <timestamp>, to: <timestamp>},

  transitions: [

    {

      from_state: <value>, to_state: <value>,

      at: <timestamp>, actor: <agent_or_user>,

      trigger: <event_description>,

      causal_chain: [{cause: ..., depth: 1}, ...] | nil

    },

    ...

  ],

  cost: {context_ops: <n>, adapters_queried: [<adapter_ids>]}

}

### Semantics

TRACE queries the event store and temporal backends for the entity’s state change history within the specified window. When DEPTH causal is specified, the engine follows cause-and-effect links from each transition: what triggered this change, and what triggered that trigger, up to the specified depth. This enables agents to answer not just “what happened” but “why did this happen.”

TRACE costs scale with the number of transitions found and the causal depth requested. The cost field reflects the actual operations consumed.

## REFRESH

**Purpose: **Validate and update active context, either as a lightweight staleness check or an intelligent refresh with peripheral expansion.

### Syntax — CHECK mode

REFRESH CHECK active_context

  [WHERE age > <duration>]

  RETURN stale_items

### Syntax — EXPAND mode

REFRESH EXPAND branch:<scope_path>

  RADIUS <integer>

  [CAPTURE peripheral_context]

### Semantics

**CHECK mode: **Scans the agent’s active context (the set of entities currently in its working memory) and identifies items whose age exceeds the specified threshold or their entity-specific decay threshold. Returns a list of stale items with their current age and the threshold they exceeded. This is a lightweight heartbeat operation designed to be called periodically during long-running sessions.

**EXPAND mode: **Performs an intelligent refresh on a specific context branch. The engine re-reads the branch’s entities from their source adapters, but also expands the scan radius by the specified number of hops to capture peripheral context that may have shifted. If CAPTURE peripheral_context is specified, newly discovered entities within the expanded radius are added to the agent’s active context. This is the mechanism that catches neighborhood-level shifts that naive TTL invalidation misses.

### Side Effects

CHECK is read-only. EXPAND may write updated freshness timestamps to the semantic definition repository and may modify the agent’s active context set.

## SIGNAL

**Purpose: **Write a quality or reputation assessment back into the semantic layer, contributing to the distributed trust network.

### Syntax

SIGNAL reputation

  ON entity:<namespace>:<name>

  SCORE <score>

  EVIDENCE "<rationale>"

  AGENT agent:<identifier>

  [ESCALATE TO agent:<identifier>]

### Parameters

| **Parameter** | **Required** | **Default** | **Description** |
| --- | --- | --- | --- |
| ON entity | Yes | — | The entity being assessed |
| SCORE | Yes | — | The reputation score (0.0 = completely unreliable, 1.0 = fully trustworthy) |
| EVIDENCE | Yes | — | A human-readable rationale for the assessment |
| AGENT | Yes | — | The agent issuing the signal (for attribution) |
| ESCALATE TO | No | No escalation | An agent to notify if the score is below a threshold (typically agent:resource_readiness) |

### Semantics

SIGNAL writes the assessment to the ETS reputation table on the local BEAM node. The delta-state CRDT synchronization mechanism propagates the update to other nodes eventually. The entity’s aggregate reputation score is recalculated as a weighted average of recent SIGNALs, with recency weighting ensuring that current assessments carry more influence than historical ones.

If ESCALATE TO is specified and the entity’s aggregate score drops below the platform-configured escalation threshold, a notification is sent to the specified agent (typically the Resource Readiness Agent) with the entity reference, current score, recent SIGNAL history, and the escalation rationale.

### Side Effects

Writes to the reputation network (ETS + CRDT sync). May trigger escalation notifications. Emits [:cqr, :signal, :stop] telemetry. The Governance Logger records the SIGNAL with full attribution.

### Return Envelope

{

  status: :signaled | :entity_not_found | :permission_denied,

  entity: entity:<namespace>:<name>,

  new_aggregate_score: <score>,

  escalated: true | false,

  cost: {context_ops: 1}

}

## CERTIFY

**Purpose: **Submit, review, or approve a semantic definition through the governance workflow.

### Syntax

CERTIFY definition:<name>

  [PROPOSED BY <user_or_agent>]

  [REVIEWED BY agent:semantic_admin]

  [APPROVED BY authority:<authority_id>]

  [SCOPE scope:<target_scope>]

  [SUPERSEDES definition:<previous_version>]

### Semantics

CERTIFY operates in three phases, each represented by which parameters are present:

- **Proposal (PROPOSED BY only): **A knowledge worker or Twin submits a new or modified definition. The definition enters the review queue.

- **Review (REVIEWED BY added): **The Semantic Administration Agent has evaluated the proposal, identified conflicts, suggested alignments, and prepared it for certification. The definition moves to the approval queue.

- **Certification (APPROVED BY added): **A human authority has approved the definition. It becomes the canonical version in the specified scope. If SUPERSEDES is specified, the previous version is marked as superseded with a reference to the new version.

Each phase transition is immutably logged by the Governance Logger, creating a complete provenance chain.

### Side Effects

Writes to the semantic definition repository. On certification, the new definition becomes resolvable via RESOLVE. Superseded definitions remain accessible for historical queries via TRACE. Emits [:cqr, :certify, :stop] telemetry.

## AWARENESS

**Purpose: **Perceive the active state of the agentic environment within a scope—which agents are operating, what their intent is, and what resources they hold.

### Syntax

AWARENESS

  WITHIN scope:<scope>

  RETURN active_agents [, intent] [, progress] [, locks]

  [FILTER role:<role>]

### Parameters

| **Parameter** | **Required** | **Default** | **Description** |
| --- | --- | --- | --- |
| WITHIN scope | Yes | — | The scope to observe |
| RETURN | Yes | — | What information to return about active agents |
| FILTER role | No | All roles | Restrict results to agents of a specific role |

### Return Envelope

{

  status: :observed | :scope_not_found | :no_awareness_access,

  scope: scope:<scope>,

  agents: [

    {

      agent_id: agent:<id>,

      role: :twin | :worker | :service,

      intent: "<description>" | nil,

      progress: <0.0-1.0> | nil,

      locks: [entity:<n>, ...] | nil,

      security_mode: :standard | :restricted

    },

    ...

  ],

  cost: {context_ops: 1}

}

### Semantics

AWARENESS queries the Phoenix PubSub topic for the specified scope and the pg process groups to enumerate active agents. Agents operating in :classified security mode are invisible—they do not appear in results and their absence is not indicated. Agents in :restricted mode appear only to authorized observers (CAO Twin and designated oversight agents).

The intent field is populated by agents broadcasting their current task description when they enter a scope. Progress is optionally reported by long-running Workers. Locks indicate entities that an agent is actively writing to (relevant for SIGNAL and CERTIFY coordination).

### Side Effects

Read-only against the PubSub and process group state. Emits [:cqr, :awareness, :stop] telemetry.

# Standard Return Envelope

Every CQR operation returns a response within a standard envelope structure. This consistency is critical for agents—they can apply the same response-handling logic regardless of which primitive produced the result.

## Common Fields

| **Field** | **Type** | **Present On** | **Description** |
| --- | --- | --- | --- |
| status | atom | All responses | The outcome of the operation. Each primitive defines its own set of valid status values. |
| cost | map | All responses | The context operations consumed and adapters queried. Used for budget tracking and telemetry. |
| metadata | map | RESOLVE, DISCOVER | Quality annotations: freshness, confidence, reputation, lineage, ownership, certification status. |
| error | map | Error responses only | Structured error information (see Error Semantics section). |

## Cost Accounting

Every response includes a cost field that tracks resource consumption. This feeds directly into the host platform’s agentic budget model:

- **context_ops: **The number of context operations consumed. RESOLVE and SIGNAL each cost 1. DISCOVER costs 1. TRACE costs 1 + N where N is the number of causal depth expansions. REFRESH EXPAND costs 1 + the number of entities refreshed.

- **adapters_queried: **The list of adapter identifiers that were consulted. This provides transparency into which backends contributed to the response.

# Error Semantics

CQR errors are designed to be cognitive inputs for agents, not exceptions to be caught. Each error provides enough information for the agent to reason about what went wrong and decide what to do next.

## Error Categories

| **Error Status** | **Meaning** | **Agent Recovery Strategy** |
| --- | --- | --- |
| :entity_not_found | The referenced entity does not exist in the semantic definition repository | Agent should DISCOVER to find the correct entity name, or propose a new definition via CERTIFY |
| :scope_not_found | The referenced scope does not exist | Agent should use a broader scope or check scope naming |
| :permission_denied | The requesting agent does not have access to the specified scope | Agent should inform its human user or operate within permitted scopes |
| :stale | The entity exists but its freshness exceeds the requested threshold | Agent receives the stale value with actual freshness; can use it with appropriate caveats or trigger a REFRESH |
| :below_reputation | The entity exists but its reputation score is below the requested threshold | Agent receives the value with actual reputation; can use with caveats, seek corroborating context, or SIGNAL its own assessment |
| :adapter_unavailable | One or more required storage backends are unreachable | Agent receives partial results from available adapters with a list of unavailable backends; can retry or proceed with partial context |
| :timeout | The operation exceeded the configured timeout | Agent receives any partial results gathered before timeout; can retry with a broader timeout or narrower scope |
| :budget_exceeded | The agent’s team has exhausted its context operation budget | Agent should inform its human user; operations resume when budget is refreshed or reallocated |
| :no_awareness_access | The agent does not have AWARENESS permissions for the requested scope | Agent operates without awareness of other agents in that scope |

## Error Envelope

{

  status: :<error_status>,

  error: {

    code: :<error_status>,

    message: "<human_readable_description>",

    context: {

      requested: <the_original_expression>,

      available_scopes: [scope:<s1>, ...] | nil,

      partial_results: <any_partial_data> | nil,

      unavailable_adapters: [<adapter_ids>] | nil,

      retry_after: <duration> | nil

    }

  },

  cost: {context_ops: <ops_consumed_before_error>}

}

The error.context field provides actionable information. For example, an :entity_not_found error may include a list of similar entity names found via fuzzy matching, helping the agent self-correct its query.

# Agent Generation Contract

This section defines the contract for LLM-based CQR generation—the system prompt structure, schema format, and validation criteria that enable agents to reliably produce correct CQR expressions from natural language intent.

This contract is the primary deliverable for Phase 1 validation. Its effectiveness is measured by the rate at which LLMs generate syntactically correct and semantically accurate CQR expressions against a test suite of natural language intents.

## System Prompt Structure

An agent generating CQR expressions requires three context inputs in its system prompt:

- **The CQR grammar reference: **A condensed version of the primitive specifications, including syntax patterns and parameter descriptions. This reference should be compact enough to fit within a system prompt without consuming excessive context window, while being precise enough to prevent syntactic errors.

- **The active schema: **The set of entities, scopes, and relationships currently available in the semantic definition repository. This is the navigable index that tells the agent what it can RESOLVE, DISCOVER, and TRACE. The schema should include entity namespaces, names, types, and scope assignments.

- **Few-shot examples: **A set of 5–10 natural-language-to-CQR translation examples covering each primitive. Examples should demonstrate both simple expressions and expressions with multiple optional clauses.

## Schema Format

The active schema is provided to the agent in a structured format optimized for LLM consumption:

CQR SCHEMA v1

---

SCOPES:

  scope:finance → [scope:finance:revenue, scope:finance:costs]

  scope:product → [scope:product:growth, scope:product:retention]

  scope:hr → [scope:hr:workforce, scope:hr:compensation]

ENTITIES:

  entity:finance:arr          | scope:finance:revenue  | Recurring revenue

  entity:finance:burn_rate    | scope:finance:costs    | Monthly cash burn

  entity:product:churn_rate   | scope:product:retention| Customer churn %

  entity:product:nps          | scope:product:growth   | Net promoter score

  entity:hr:headcount         | scope:hr:workforce     | Total employee count

  entity:hr:attrition_rate    | scope:hr:workforce     | Employee turnover %

RELATIONSHIPS:

  entity:finance:arr DRIVEN_BY entity:product:churn_rate

  entity:product:churn_rate CORRELATES entity:product:nps

  entity:hr:attrition_rate IMPACTS entity:product:churn_rate

This format is designed for LLM readability: clear delimiters, one entity per line, relationship types in uppercase. The schema is generated from the semantic definition repository and updated as definitions are certified.

## Validation Criteria

A generated CQR expression is evaluated against three criteria:

- **Syntactic correctness: **Does the expression parse without errors against the NimbleParsec grammar? This is a binary pass/fail.

- **Semantic accuracy: **Does the expression reference entities and scopes that exist in the active schema? Are the parameter types correct (durations, scores, depths)? This is validated against the schema.

- **Intent fidelity: **Does the expression capture the user’s actual intent? This requires human evaluation or a judge LLM comparing the natural language intent to the generated expression.

The Phase 1 POC target is 90%+ syntactic correctness and 85%+ semantic accuracy across a test suite of 100 natural language intents of varying complexity. Intent fidelity is evaluated qualitatively on a subset.

## Example Generation Pairs

The following examples illustrate the mapping from natural language intent to CQR expression:

**Intent: **"What’s our current ARR?"

RESOLVE entity:finance:arr FROM scope:finance:revenue WITH freshness < 24h

**Intent: **"What data do we have related to customer churn?"

DISCOVER concepts RELATED TO entity:product:churn_rate WITHIN scope:product, scope:finance DEPTH 2 ANNOTATE freshness, reputation, owner

**Intent: **"How has our headcount changed over the last quarter and what drove the changes?"

TRACE entity:hr:headcount OVER last 90d INCLUDE state_transitions, actors, triggers DEPTH causal:2

**Intent: **"The NPS data seems outdated — flag it."

SIGNAL reputation ON entity:product:nps SCORE 0.4

  EVIDENCE "Data appears outdated based on last known update"

  AGENT agent:twin:user_42

  ESCALATE TO agent:resource_readiness

**Intent: **"Who else is working on churn analysis right now?"

AWARENESS WITHIN scope:product:retention RETURN active_agents, intent FILTER role:twin

**Intent: **"Check if any of my active context has gone stale."

REFRESH CHECK active_context WHERE age > 4h RETURN stale_items

**Intent: **"Get me the ARR definition, but I don’t trust the finance team’s version. Fall back to the product team’s if necessary."

RESOLVE entity:finance:arr FROM scope:finance WITH reputation > 0.7 FALLBACK scope:product → scope:global INCLUDE lineage, confidence, owner

# Formal Grammar (PEG Notation)

The following Parsing Expression Grammar defines the complete syntax for CQR expressions. This grammar is the reference specification for the NimbleParsec parser implementation.

# Top-level expression

expression   <- resolve / discover / trace / refresh / signal / certify / awareness

# RESOLVE

resolve      <- 'RESOLVE' sp entity (sp from_clause)? (sp with_clause)* (sp include_clause)? (sp fallback_clause)?

from_clause   <- 'FROM' sp scope

with_clause   <- 'WITH' sp (freshness_constraint / reputation_constraint)

freshness_constraint <- 'freshness' sp '<' sp duration

reputation_constraint <- 'reputation' sp '>' sp score

include_clause <- 'INCLUDE' sp annotation_list

fallback_clause <- 'FALLBACK' sp scope (sp '→' sp scope)*

# DISCOVER

discover     <- 'DISCOVER' sp 'concepts' sp related_clause (sp within_clause)? (sp depth_clause)? (sp annotate_clause)? (sp limit_clause)?

related_clause <- 'RELATED' sp 'TO' sp (entity / string_literal)

within_clause <- 'WITHIN' sp scope (',' sp scope)*

depth_clause  <- 'DEPTH' sp integer

annotate_clause <- 'ANNOTATE' sp annotation_list

limit_clause  <- 'LIMIT' sp integer

# TRACE

trace        <- 'TRACE' sp entity (sp for_clause)? sp over_clause (sp trace_include)? (sp causal_depth)?

for_clause    <- 'FOR' sp entity

over_clause   <- 'OVER' sp 'last' sp duration

trace_include <- 'INCLUDE' sp trace_field (',' sp trace_field)*

trace_field   <- 'state_transitions' / 'actors' / 'triggers'

causal_depth  <- 'DEPTH' sp 'causal:' integer

# REFRESH

refresh      <- refresh_check / refresh_expand

refresh_check <- 'REFRESH' sp 'CHECK' sp 'active_context' (sp where_age)? sp 'RETURN' sp 'stale_items'

where_age     <- 'WHERE' sp 'age' sp '>' sp duration

refresh_expand <- 'REFRESH' sp 'EXPAND' sp branch sp radius_clause (sp capture_clause)?

branch        <- 'branch:' identifier (':' identifier)*

radius_clause <- 'RADIUS' sp integer

capture_clause <- 'CAPTURE' sp 'peripheral_context'

# SIGNAL

signal       <- 'SIGNAL' sp 'reputation' sp on_clause sp score_clause sp evidence_clause sp agent_clause (sp escalate_clause)?

on_clause     <- 'ON' sp entity

score_clause  <- 'SCORE' sp score

evidence_clause <- 'EVIDENCE' sp string_literal

agent_clause  <- 'AGENT' sp agent_ref

escalate_clause <- 'ESCALATE' sp 'TO' sp agent_ref

# CERTIFY

certify      <- 'CERTIFY' sp definition (sp proposed_clause)? (sp reviewed_clause)? (sp approved_clause)? (sp certify_scope)? (sp supersedes_clause)?

definition    <- 'definition:' identifier

proposed_clause <- 'PROPOSED' sp 'BY' sp identifier

reviewed_clause <- 'REVIEWED' sp 'BY' sp agent_ref

approved_clause <- 'APPROVED' sp 'BY' sp 'authority:' identifier

certify_scope <- 'SCOPE' sp scope

supersedes_clause <- 'SUPERSEDES' sp definition

# AWARENESS

awareness    <- 'AWARENESS' sp awareness_within sp return_clause (sp filter_clause)?

awareness_within <- 'WITHIN' sp scope

return_clause <- 'RETURN' sp awareness_field (',' sp awareness_field)*

awareness_field <- 'active_agents' / 'intent' / 'progress' / 'locks'

filter_clause <- 'FILTER' sp role_filter

# Terminals

entity       <- 'entity:' identifier ':' identifier

scope        <- 'scope:' identifier (':' identifier)*

agent_ref    <- 'agent:' identifier (':' identifier)*

role_filter  <- 'role:' identifier

duration     <- integer ('m' / 'h' / 'd' / 'w')

score        <- [0-9] '.' [0-9]+

integer      <- [0-9]+

identifier   <- [a-z_] [a-z0-9_]*

string_literal <- '"' [^"]* '"'

annotation_list <- annotation (',' sp annotation)*

annotation   <- 'freshness' / 'confidence' / 'reputation' / 'owner' / 'lineage'

sp           <- ' '+

This grammar intentionally avoids constructs that LLMs commonly misgenerate: nested parentheses, complex operator precedence, quoted identifiers with escape sequences, and ambiguous keyword boundaries. Every keyword is a distinct uppercase word, every parameter has a clear prefix, and optional clauses can appear in any order (the parser is order-insensitive for optional clauses within each primitive).

# Implementation Notes

## NimbleParsec Implementation

The PEG grammar maps directly to NimbleParsec combinator definitions. Each primitive becomes a top-level parser function, and the expression parser is a choice combinator across all seven primitives. The parser produces an Elixir struct for each expression type (e.g., %Cqr.Resolve{}, %Cqr.Discover{}) that the query planner consumes.

Key implementation considerations:

- Optional clause ordering: the parser must accept optional clauses in any order within a primitive. NimbleParsec’s repeat and optional combinators handle this, but the AST must normalize clause order for consistent downstream processing.

- Error recovery: when parsing fails, the parser should return the position of the failure and the set of expected tokens. This feeds into the error envelope so the agent can understand what went wrong with its generated expression.

- Whitespace handling: the grammar treats newlines as equivalent to spaces. CQR expressions may be formatted across multiple lines for readability without affecting semantics.

## Query Planner

The query planner takes a parsed CQR AST and produces an execution plan:

- Consult the semantic definition repository to resolve entity references to adapter-specific locations.

- Determine which adapters need to be queried based on the entity’s storage locations and the expression’s requirements (graph traversal needs Neo4j, vector similarity needs pgvector, etc.).

- Plan concurrent fan-out via Task.async_stream across the identified adapters.

- Define the merge strategy for results from multiple adapters (deduplication, annotation merging, conflict resolution).

- Apply scope permissions check before execution begins.

- Execute and return results within the standard envelope.

## Adapter Behaviour Contract

Each adapter implements the Cqr.Adapter behaviour:

defmodule Cqr.Adapter do

  @callback resolve(entity :: map(), scope :: map(), opts :: keyword()) ::

    {:ok, result :: map()} | {:error, reason :: atom()}

  @callback discover(anchor :: map(), scope :: map(), opts :: keyword()) ::

    {:ok, concepts :: [map()]} | {:error, reason :: atom()}

  @callback trace(entity :: map(), period :: map(), opts :: keyword()) ::

    {:ok, transitions :: [map()]} | {:error, reason :: atom()}

  @callback health_check() :: :ok | {:error, reason :: atom()}

end

The behaviour contract deliberately mirrors the CQR primitive signatures. Each adapter translates the common parameter maps into native queries for its specific backend.

# Phase 1 Validation Plan

The Phase 1 POC validates CQR’s core thesis: that LLMs can reliably generate correct CQR expressions, and that those expressions produce better context retrieval than direct tool calls.

## Test Suite Design

The test suite consists of 100 natural language intents stratified by complexity:

| **Tier** | **Count** | **Complexity** | **Example** |
| --- | --- | --- | --- |
| Simple | 40 | Single primitive, 1–2 parameters | "What’s our current ARR?" |
| Moderate | 35 | Single primitive, 3–4 parameters with constraints | "Get the churn rate from the product team, must be less than a week old" |
| Complex | 15 | Single primitive, full parameter set with fallbacks | "Resolve ARR from finance with high reputation, fall back to product then global, include full lineage" |
| Multi-step | 10 | Intent requires 2+ CQR expressions in sequence | "Find everything related to churn, then trace the top driver over the last quarter" |

## Evaluation Metrics

- **Syntactic accuracy: **Percentage of generated expressions that parse without errors. Target: 90%+.

- **Semantic accuracy: **Percentage of parsed expressions that reference valid entities, scopes, and parameter types. Target: 85%+.

- **Intent fidelity: **Human-evaluated score (1–5) on whether the expression captures the natural language intent. Target: 4.0+ average on a 5-point scale.

- **Comparative retrieval quality: **A/B comparison of context retrieved via CQR vs. the same LLM using direct tool calls against the same backends. Measured by relevance, completeness, and metadata richness of returned context.

## Test Protocol

- Provide the LLM with the CQR grammar reference, active schema, and few-shot examples as system prompt context.

- Present each natural language intent as a user message.

- Capture the generated CQR expression.

- Run the expression through the NimbleParsec parser for syntactic validation.

- Validate entity and scope references against the test schema for semantic accuracy.

- For the multi-step tier, evaluate whether the LLM correctly identifies that multiple expressions are needed and generates them in a logical sequence.

- Document all failures with the incorrect output and the expected output for error pattern analysis.

Error patterns are analyzed to identify systematic generation failures that can be addressed through grammar simplification, additional few-shot examples, or constrained decoding techniques.

END OF SPECIFICATION