# CQR Protocol Specification

**Cognitive Query Resolution — The Query Language for Machine Cognition**

Version 0.9 · April 2026

---

## Abstract

CQR (Cognitive Query Resolution) is a declarative query language designed for AI agents as the primary consumer. Its eleven cognitive operation primitives map to reasoning patterns — resolve, orient, assert, trace, hypothesize, compare, ground, assess, govern, maintain, and perceive — rather than data manipulation operations.

Agents don't just read through CQR. They write. The ASSERT primitive lets agents contribute knowledge back into the governed semantic layer as structurally untrusted context — carrying full provenance about why it was created, what reasoning produced it, and how it connects to existing knowledge. This agent-generated context is architecturally distinct from human-certified organizational truth. The trust gap between the two is itself a first-class cognitive signal: it tells downstream agents how much confirmation they need before acting.

Every CQR response includes mandatory quality metadata: provenance, freshness, confidence, reputation, lineage, and ownership. The agent always knows how much to trust what it received.

CQR is designed for reliable generation by large language models. Its grammar avoids constructs that LLMs commonly misgenerate — nested parentheses, complex operator precedence, quoted identifiers with escape sequences, and ambiguous keyword boundaries. Empirical validation demonstrates 94–97% syntactic accuracy and 93–96% semantic accuracy across models ranging from 8B to 14B parameters running entirely locally without cloud dependency.

---

## Where CQR Sits

The agentic AI ecosystem is converging on standard protocols at different layers of the stack. Two have gained significant traction:

- **MCP (Model Context Protocol)** addresses agent-to-tool communication — how an agent invokes external tools, reads data sources, and receives structured results.
- **A2A (Agent2Agent Protocol)** addresses agent-to-agent communication — how agents discover each other, negotiate capabilities, and coordinate multi-agent workflows.

Neither addresses a third problem: **how does an agent interact with governed organizational context?**

When an enterprise deploys dozens or hundreds of AI agents, those agents need to resolve canonical business concepts, understand the quality and provenance of the data they receive, contribute their own findings back into a governed knowledge fabric, operate within organizational scope boundaries, participate in governance workflows, and perceive what other agents are doing. These are not tool calls or agent-to-agent messages. They are interactions with a governed semantic layer — the organizational knowledge fabric that agents reason over and write into.

CQR occupies this layer.

| Layer | Protocol | Relationship |
|-------|----------|-------------|
| Agent ↔ Tool | MCP | How agents invoke tools and read data sources |
| Agent ↔ Agent | A2A | How agents discover, negotiate, and coordinate |
| Agent ↔ Governed Context | **CQR** | How agents resolve meaning, write knowledge, and trust what they receive |

CQR is not a competing protocol. It is the governed context infrastructure that sits beneath agent orchestration. It can be delivered through MCP as a transport — CQR primitives become callable by any MCP-compatible agent without requiring CQR-specific client libraries. The governance semantics are preserved regardless of the delivery interface.

---

## Design Principles

**1. Agents are the users.** Every syntactic and semantic decision optimizes for reliable LLM generation, not human developer ergonomics. Primitives are unambiguous, keywords are semantically clear, and the grammar avoids constructs that LLMs commonly hallucinate or misgenerate.

**2. Cognitive operations, not data operations.** CQR primitives map to reasoning patterns — resolve a canonical concept, orient in a neighborhood, assert a finding, trace a causal chain, hypothesize impact, compare across boundaries, ground a reasoning chain, assess quality, govern definitions, maintain freshness, perceive the ecosystem.

**3. Quality metadata is mandatory.** Every CQR response includes provenance, freshness, confidence, reputation, lineage, and ownership data in a standard return envelope. An agent always knows how much to trust what it received.

**4. Scope is first-class.** Every expression operates within a defined organizational scope hierarchy. Scope is not a filter applied after retrieval — it is a fundamental part of the query semantics that determines what is visible, what is authoritative, and what falls back to broader scopes.

**5. Trust is a spectrum, not a binary.** Agent-generated context enters the semantic layer as structurally untrusted knowledge. It accumulates community reputation through assessment. It graduates to organizational truth through human certification. The trust level at every point in this lifecycle is visible in the quality metadata and informs agent decision-making.

**6. Fail informatively.** When an expression cannot be satisfied, the error response gives the agent enough information to reason about what went wrong and what to try next. Errors are cognitive inputs, not exceptions.

---

## Type System

CQR operates over a deliberately constrained set of types. Constraining the type system reduces the surface area for LLM generation errors and keeps the language semantically focused.

### Core Types

| Type | Syntax | Description | Examples |
|------|--------|-------------|----------|
| Entity | `entity:<namespace>:<n>` | A named concept in the semantic repository, namespaced to prevent collisions | `entity:finance:arr`, `entity:product:churn_rate` |
| Scope | `scope:<path>` | An organizational boundary defining visibility, authority, and access control | `scope:finance`, `scope:product:growth`, `scope:global` |
| Duration | `<number><unit>` | A time span. Units: `m` (minutes), `h` (hours), `d` (days), `w` (weeks) | `24h`, `7d`, `90d` |
| Score | `<0.0–1.0>` | A normalized quality score | `0.7`, `0.85` |
| Agent | `agent:<type>:<id>` | A reference to an agent in the runtime | `agent:twin:user_42`, `agent:service:semantic_admin` |
| Annotation List | Comma-separated identifiers | Metadata fields to include in the response | `freshness, reputation, owner` |

### Relationship Types

Typed relationships between entities define the dependency and causal graph:

| Relationship | Semantics |
|-------------|-----------|
| `CORRELATES_WITH` | Statistical co-occurrence without directional causation |
| `CAUSES` | Directional causal relationship with strength score |
| `CONTRIBUTES_TO` | Partial contribution with attenuation weight |
| `DEPENDS_ON` | Directional dependency — changes propagate forward |
| `PART_OF` | Compositional containment |

---

## Primitives

CQR provides eleven cognitive operation primitives organized into five functional categories.

---

### I. Context Resolution

#### RESOLVE — Canonical Concept Retrieval

Retrieve the authoritative instance of a named concept from the nearest matching organizational scope with quality metadata.

Unlike search, RESOLVE targets a specific canonical concept by semantic address — not "find me something about revenue" but "give me the authoritative definition of ARR from the finance team."

```
RESOLVE entity:<namespace>:<n>
  [FROM scope:<scope>]
  [WITH freshness < <duration>]
  [WITH reputation > <score>]
  [INCLUDE <annotation_list>]
  [FALLBACK scope:<s1> → scope:<s2> → ...]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| entity | Yes | — | The canonical concept to resolve |
| FROM | No | Agent's active scope | The scope to resolve from |
| WITH freshness | No | No constraint | Maximum acceptable age |
| WITH reputation | No | No constraint | Minimum community trust score |
| INCLUDE | No | freshness, confidence | Quality metadata to include |
| FALLBACK | No | Scope hierarchy default | Explicit fallback chain |

RESOLVE fans out across all adapters that hold data for the requested entity and returns ALL results. This conflict preservation enables the requesting agent to reason over disagreements between backends.

**Example:**

```
RESOLVE entity:finance:arr
  FROM scope:finance
  WITH freshness < 24h
  WITH reputation > 0.7
  FALLBACK scope:product → scope:global
  INCLUDE lineage, confidence, owner
```

#### DISCOVER — Neighborhood Scan

Return a navigable map of concepts in the conceptual neighborhood of an anchor entity or search term, annotated with quality signals.

DISCOVER is the orientation primitive — the table-of-contents operation. The agent learns the shape of available knowledge without paying the cost of loading it all. It combines graph traversal and semantic similarity search, merges and deduplicates results from both modalities.

```
DISCOVER concepts
  RELATED TO entity:<namespace>:<n> | "<search_term>"
  [WITHIN scope:<s1> [, scope:<s2>, ...]]
  [DEPTH <integer>]
  [ANNOTATE <annotation_list>]
  [LIMIT <integer>]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| RELATED TO | Yes | — | Anchor entity or free-text search term |
| WITHIN | No | Agent's active scope | Scope(s) to search |
| DEPTH | No | 1 | Graph traversal depth |
| ANNOTATE | No | freshness, reputation | Quality metadata per result |
| LIMIT | No | 10 | Maximum results |

**Example:**

```
DISCOVER concepts
  RELATED TO entity:product:churn_rate
  WITHIN scope:product, scope:finance
  DEPTH 2
  ANNOTATE freshness, reputation, owner
```

---

### II. Context Creation

#### ASSERT — Governed Knowledge Writing

Write agent-generated knowledge into the governed semantic layer as structurally untrusted context with full provenance, derivation chain, and graph integration.

ASSERT is the write primitive. When an agent synthesizes a finding, detects an anomaly, or builds a working hypothesis, ASSERT captures that knowledge in the semantic fabric — not as a note in a scratchpad, but as a first-class entity with relationships, quality metadata, and a complete audit trail of the reasoning that produced it.

Asserted context enters the semantic layer at reputation `0.0` with trust status `:asserted`. It is **rumor with a paper trail** — visible to DISCOVER, traceable by TRACE, assessable by SIGNAL, groundable by ANCHOR — but every downstream agent sees the trust distinction and calibrates accordingly.

```
ASSERT entity:<namespace>:<n>
  VALUE <value_expression>
  TYPE metric | dimension | attribute | event | relationship
  SCOPE scope:<scope>
  AGENT agent:<type>:<id>
  INTENT "<use_case_description>"
  DERIVED_FROM [<cqr_operation_refs>]
  [CONFIDENCE <score>]
  [RELATES_TO entity:<ns>:<n> AS <relationship_type> [STRENGTH <score>], ...]
  [CONTEXT "<additional_reasoning>"]
  [EXPIRES <duration>]
  [VISIBILITY private | scope | global]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| entity | Yes | — | Entity to assert. Creates if new; versions if existing |
| VALUE | Yes | — | The asserted value: numeric, string, JSON, or temporal |
| TYPE | Yes | — | Entity type: `metric`, `dimension`, `attribute`, `event`, `relationship` |
| SCOPE | Yes | — | Scope for the assertion. Agent must have write access |
| AGENT | Yes | — | The asserting agent. Immutable in provenance |
| INTENT | Yes | — | Why this assertion exists — the use case, the question being answered |
| DERIVED_FROM | Yes | — | References to the CQR operations that produced the reasoning. The cognitive lineage |
| CONFIDENCE | No | 0.5 | Agent's self-assessed confidence (0.0–1.0) |
| RELATES_TO | No | — | Relationship edges to existing entities |
| CONTEXT | No | — | Additional reasoning, caveats, conditions |
| EXPIRES | No | No expiration | TTL for time-sensitive working knowledge |
| VISIBILITY | No | `scope` | `private` (agent + human only), `scope`, or `global` |

**INTENT and DERIVED_FROM are mandatory by design.** Every assertion must carry its justification and its cognitive lineage. An agent cannot assert "revenue will decline 15%" without showing the RESOLVE, TRACE, or HYPOTHESIZE operations that produced that conclusion. This makes every assertion auditable — not by policy, but by architecture.

ASSERT never modifies or overwrites certified context. If an agent asserts a value for an entity that has a certified version, both coexist — the divergence is a governance signal visible through COMPARE.

**The certification lifecycle:** Assertions accumulate community reputation through SIGNAL assessments. An agent's job includes shepherding its assertions toward certification — identifying the right human authority, building evidence, navigating the governance path. Getting knowledge certified is a strategic activity, not a rubber stamp.

**Example:**

```
ASSERT entity:product:churn_correlation_nps
  VALUE "NPS below 30 correlates with 2.3x higher churn probability"
  TYPE relationship
  SCOPE scope:product:retention
  AGENT agent:twin:user_42
  INTENT "Investigating root causes of Q1 churn spike for executive review"
  DERIVED_FROM [op:resolve:7a3f, op:trace:8b2c, op:compare:9d4e]
  CONFIDENCE 0.72
  RELATES_TO entity:product:churn_rate AS CORRELATES_WITH STRENGTH 0.81,
             entity:product:nps AS CORRELATES_WITH STRENGTH 0.81
  CONTEXT "Correlation observed in NA and LATAM regions. EMEA data insufficient."
  VISIBILITY scope
```

---

### III. Reasoning

#### TRACE — Temporal Trajectory

Return state transition trajectories — how an entity evolved, what caused state changes, and who acted. Causal depth follows chains of cause and effect.

```
TRACE entity:<namespace>:<n>
  [FOR entity:<namespace>:<n>]
  OVER last <duration>
  [INCLUDE state_transitions, actors, triggers]
  [DEPTH causal:<integer>]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| entity | Yes | — | Entity to trace |
| FOR | No | — | Secondary entity to trace in relation |
| OVER | Yes | — | Temporal window |
| INCLUDE | No | state_transitions | Trajectory data to return |
| DEPTH causal | No | 1 | Causal hops to follow |

**Example:**

```
TRACE entity:hr:headcount
  OVER last 90d
  INCLUDE state_transitions, actors, triggers
  DEPTH causal:2
```

#### HYPOTHESIZE — Forward Causal Propagation

Compute downstream impact of a hypothetical change by propagating it forward through dependency and causal chains. The forward complement to TRACE: where TRACE explains what already happened, HYPOTHESIZE predicts what would be affected.

```
HYPOTHESIZE entity:<namespace>:<n>
  CHANGE <change_expression>
  [PROPAGATE THROUGH <relationship_types>]
  [DEPTH <integer>]
  [WITHIN scope:<scope>]
  [WITH confidence > <score>]
  [INCLUDE <annotation_list>]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| entity | Yes | — | Entity whose change to propagate |
| CHANGE | Yes | — | Hypothetical perturbation: `+15%`, `-10%`, `SET 0` |
| PROPAGATE THROUGH | No | DEPENDS_ON, CONTRIBUTES_TO, CAUSES | Relationship types to follow |
| DEPTH | No | 2 | Maximum propagation depth |
| WITHIN | No | Agent's active scope | Scope boundary |
| WITH confidence | No | No constraint | Minimum edge confidence |
| INCLUDE | No | freshness, confidence | Metadata annotations |

Pure read operation. Never modifies actual data.

**Example:**

```
HYPOTHESIZE entity:product:churn_rate
  CHANGE SET 0.08
  PROPAGATE THROUGH CAUSES, CONTRIBUTES_TO
  DEPTH 3
  WITHIN scope:company
  WITH confidence > 0.6
```

#### COMPARE — Cross-Scope Divergence Detection

Compare entities across organizational scopes and detect divergences in value, quality, ownership, or trajectory.

```
COMPARE entity:<ns>:<n> [, entity:<ns>:<n>, ...]
  ACROSS scope:<s1>, scope:<s2> [, ...]
  [DIMENSIONS value, freshness, reputation, confidence, owner, certification, trajectory]
  [AS_OF last <duration>]
  [WITH <quality_constraint>]
  [INCLUDE <annotation_list>]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| entities | Yes | — | One or more entities to compare |
| ACROSS | Yes | — | Two or more scopes |
| DIMENSIONS | No | value, freshness | Comparison dimensions |
| AS_OF | No | Current snapshot | Temporal window for trajectory |
| WITH | No | No constraint | Quality constraints |
| INCLUDE | No | freshness, confidence | Metadata annotations |

Automatically validates known mathematical relationships between compared entities across scopes.

**Example:**

```
COMPARE entity:finance:arr, entity:finance:mrr
  ACROSS scope:company:na, scope:company:latam, scope:company:emea
  DIMENSIONS value, trajectory, reputation, certification
  AS_OF last 90d
  WITH reputation > 0.7
  INCLUDE lineage, owner
```

#### ANCHOR — Epistemic Grounding

Introspect on a set of resolved context and return the dependency graph of epistemic assumptions, with quality metadata identifying weakest links. This is how an agent answers "how solid is my reasoning chain?" before it acts.

```
ANCHOR
  CONTEXT [entity:<ns>:<n>, entity:<ns>:<n>, ...]
  [WITHIN scope:<scope>]
  [THRESHOLD reputation < <score>]
  [THRESHOLD freshness > <duration>]
  [RETURN assumption_chain, weakest_link, confidence_floor,
          certification_gaps, staleness_risk]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| CONTEXT | Yes | — | Entities forming the reasoning chain to ground |
| WITHIN | No | Agent's active scope | Scope for analysis |
| THRESHOLD reputation | No | No constraint | Flag entities below this score |
| THRESHOLD freshness | No | No constraint | Flag entities older than this |
| RETURN | No | assumption_chain, weakest_link | Grounding analysis fields |

Pure read operation.

**Example:**

```
ANCHOR
  CONTEXT [entity:finance:arr, entity:finance:mrr,
           entity:hr:attrition_rate, entity:product:churn_rate,
           entity:customer_success:csat]
  WITHIN scope:company
  THRESHOLD reputation < 0.8
  THRESHOLD freshness > 3d
  RETURN assumption_chain, weakest_link, confidence_floor,
         certification_gaps, staleness_risk
```

---

### IV. Governance

#### SIGNAL — Quality Feedback

Write quality assessments into the distributed reputation network. Agents are not just consumers of context — they are curators.

```
SIGNAL reputation
  ON entity:<namespace>:<n>
  SCORE <score>
  EVIDENCE "<description>"
  AGENT agent:<type>:<id>
  [ESCALATE TO agent:<type>:<id>]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| ON | Yes | — | Entity being assessed |
| SCORE | Yes | — | Quality score (0.0–1.0) |
| EVIDENCE | Yes | — | Justification |
| AGENT | Yes | — | Agent making the assessment |
| ESCALATE TO | No | — | Escalation target |

**Example:**

```
SIGNAL reputation
  ON entity:product:nps
  SCORE 0.4
  EVIDENCE "Data appears outdated based on last known update"
  AGENT agent:twin:user_42
  ESCALATE TO agent:service:resource_readiness
```

#### CERTIFY — Governance Workflow

Manage the governance lifecycle. Definitions emerge bottom-up from practitioners, are refined by service agents, and require human authority for certification. CERTIFY tracks the full provenance chain: who proposed, who reviewed, who approved.

```
CERTIFY entity:<namespace>:<n>
  STATUS proposed | under_review | certified | superseded
  [AUTHORITY <identifier>]
  [SUPERSEDES entity:<namespace>:<n>]
  [EVIDENCE "<description>"]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| entity | Yes | — | Entity definition being governed |
| STATUS | Yes | — | Governance status to transition to |
| AUTHORITY | No | — | Certifying authority (required for `certified`) |
| SUPERSEDES | No | — | Prior definition being replaced |
| EVIDENCE | No | — | Justification for transition |

Each phase transition is immutably logged. When CERTIFY promotes an assertion to `:certified` status, the full derivation chain from ASSERT, the SIGNAL history, and the accumulated community reputation all become part of the certification evidence.

---

### V. Maintenance and Perception

#### REFRESH — Context Maintenance

Maintain context freshness in two modes:

**CHECK** — lightweight staleness scan:

```
REFRESH CHECK active_context
  [WHERE age > <duration>]
  RETURN stale_items
```

**EXPAND** — intelligent refresh that widens scan radius to capture peripheral context shifts:

```
REFRESH EXPAND branch:<path>
  RADIUS <integer>
  [CAPTURE peripheral_context]
```

#### AWARENESS — Ecosystem Perception

Perceive the active state of the agentic environment within a scope — which agents are operating, what their intent is, and what resources they hold.

```
AWARENESS
  WITHIN scope:<scope>
  RETURN active_agents [, intent] [, progress] [, locks]
  [FILTER role:<role>]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| WITHIN | Yes | — | Scope to observe |
| RETURN | Yes | — | Information about active agents |
| FILTER role | No | All roles | Restrict to specific agent role |

Enables collision avoidance and self-organization. Agents in classified security modes are invisible.

**Example:**

```
AWARENESS
  WITHIN scope:product:retention
  RETURN active_agents, intent
  FILTER role:twin
```

---

## Standard Return Envelope

Every CQR operation returns a response within a standard envelope.

```
{
  status: <operation_specific_status>,

  cost: {
    context_ops: <integer>,
    adapters_queried: [<adapter_ids>]
  },

  metadata: {
    freshness: <duration>,
    confidence: <0.0-1.0>,
    reputation: <0.0-1.0>,
    trust_status: :certified | :asserted | :proposed | :superseded,
    owner: <identifier>,
    lineage: [<version_chain>],
    certified_by: <authority> | nil,
    certified_at: <timestamp> | nil
  }
}
```

| Field | Type | Present On | Description |
|-------|------|-----------|-------------|
| `status` | atom | All responses | Operation outcome |
| `cost` | map | All responses | Context operations consumed and adapters queried |
| `metadata` | map | RESOLVE, DISCOVER, ASSERT | Quality annotations including trust status |
| `error` | map | Error responses | Structured error information |

The `trust_status` field distinguishes certified organizational truth from agent-asserted working knowledge. This distinction propagates through every downstream operation — ANCHOR includes it in epistemic grounding, HYPOTHESIZE weights propagated effects by it, COMPARE surfaces divergences between certified and asserted versions.

### Cost Accounting

The `cost` field feeds into an organizational budget model. Organizational units receive allocations of context operations, creating natural accountability for AI agent activity and measurable ROI for context interactions.

---

## Error Semantics

Nine error categories, each designed as a cognitive input:

| Error Status | Meaning | Agent Action |
|-------------|---------|--------------|
| `:not_found` | Entity does not exist in any searched scope | Try DISCOVER; check namespace |
| `:access_denied` | Agent scope lacks visibility | Request scope elevation or broaden scope |
| `:stale` | Freshness constraint not met | Accept stale data or REFRESH |
| `:below_reputation` | Reputation below threshold | Accept or SIGNAL for re-assessment |
| `:adapter_error` | Adapter(s) failed | Retry; partial results may be available |
| `:parse_error` | Syntax error | Error includes parse position and expected tokens |
| `:scope_not_found` | Scope does not exist | Error includes similar scope suggestions |
| `:budget_exceeded` | Context operations budget exhausted | Request increase or prioritize |
| `:timeout` | Adapter execution exceeded time limit | Retry with simpler expression |

### Structured Error Envelope

```
{
  status: :<error_status>,

  error: {
    message: "<human_readable_description>",
    suggestions: [<similar_entities_or_scopes>],
    partial_results: <results_from_successful_adapters> | nil,
    retry_guidance: "<recommendation_for_retry>"
  },

  cost: {
    context_ops: <n>,
    adapters_queried: [...]
  }
}
```

---

## Adapter Behavioral Contract

CQR expressions are translated by adapters into native queries against heterogeneous storage backends — graph databases, vector databases, relational stores, time-series engines, document stores. A single expression can fan out across multiple adapters concurrently.

Every adapter implements a common behavioral contract:

| Operation | Purpose |
|-----------|---------|
| `resolve` | Translate canonical retrieval into native queries |
| `discover` | Translate neighborhood scan for the adapter's paradigm |
| `normalize` | Transform native results into the standard envelope with quality metadata |
| `health_check` | Report operational status and readiness |

Each adapter self-declares supported primitives through a capability declaration. The contract is extensible without modifying existing implementations.

### Polyglot Fan-Out with Conflict Preservation

When RESOLVE targets an entity mapped to multiple adapters, all are queried concurrently and all results returned. CQR does not select a "winner" — it preserves conflicts so the agent can reason over disagreements. Enterprise data is often inconsistent across systems. CQR makes that inconsistency visible as a first-class signal.

---

## Scope Hierarchy and Resolution

Scope is embedded in query execution semantics, not applied as a post-retrieval filter.

When an agent RESOLVEs:

1. Look for the entity in the specified scope (or agent's active scope).
2. If not found, walk up the hierarchy toward global scope.
3. If FALLBACK is explicit, follow that chain instead.
4. The providing scope is recorded in response metadata.

Scope determines visibility, authority, and fallback behavior. Governance boundaries are enforced at the query level.

---

## Agent Generation Contract

CQR includes a formal agent generation contract — the methodology by which LLMs reliably generate correct CQR expressions from natural language intent. Three components:

**Component 1: Grammar Reference.** Condensed syntax specification optimized for LLM consumption.

**Component 2: Active Schema.** Currently available entities, scopes, and adapters in a structured format.

**Component 3: Few-Shot Examples.** Curated intent-to-expression pairs across complexity levels.

The contract reflects specific grammar design decisions that reduce LLM generation errors:

- No nested parentheses, complex operator precedence, or quoted identifiers with escape sequences
- Distinct uppercase keyword tokens creating unambiguous tokenizer boundaries
- Constrained type system with explicit prefixes (`entity:`, `scope:`, `agent:`)
- Order-insensitive optional clauses accommodating autoregressive generation
- Semantic primitive names mapping directly to cognitive operations

---

## Example Generation Pairs

**"What's our current ARR?"**
```
RESOLVE entity:finance:arr FROM scope:finance:revenue WITH freshness < 24h
```

**"What data do we have related to customer churn?"**
```
DISCOVER concepts RELATED TO entity:product:churn_rate
  WITHIN scope:product, scope:finance DEPTH 2
  ANNOTATE freshness, reputation, owner
```

**"I found a correlation between NPS and churn — record it."**
```
ASSERT entity:product:churn_correlation_nps
  VALUE "NPS below 30 correlates with 2.3x higher churn probability"
  TYPE relationship
  SCOPE scope:product:retention
  AGENT agent:twin:user_42
  INTENT "Investigating root causes of Q1 churn spike for executive review"
  DERIVED_FROM [op:resolve:7a3f, op:trace:8b2c, op:compare:9d4e]
  CONFIDENCE 0.72
  RELATES_TO entity:product:churn_rate AS CORRELATES_WITH STRENGTH 0.81
  VISIBILITY scope
```

**"How has headcount changed over the last quarter and what drove the changes?"**
```
TRACE entity:hr:headcount OVER last 90d
  INCLUDE state_transitions, actors, triggers DEPTH causal:2
```

**"What would be affected if we cut headcount by 15%?"**
```
HYPOTHESIZE entity:hr:headcount CHANGE -15% WITHIN scope:company
```

**"Compare ARR across all regions with trajectory data for the last quarter."**
```
COMPARE entity:finance:arr, entity:finance:mrr
  ACROSS scope:company:na, scope:company:latam, scope:company:emea
  DIMENSIONS value, trajectory, reputation, certification
  AS_OF last 90d
  WITH reputation > 0.7
```

**"Before I present these findings, check the quality of everything I'm relying on."**
```
ANCHOR
  CONTEXT [entity:finance:arr, entity:finance:mrr,
           entity:hr:attrition_rate, entity:product:churn_rate]
  WITHIN scope:company
  THRESHOLD reputation < 0.8
  THRESHOLD freshness > 3d
  RETURN assumption_chain, weakest_link, confidence_floor
```

**"The NPS data seems outdated — flag it."**
```
SIGNAL reputation ON entity:product:nps SCORE 0.4
  EVIDENCE "Data appears outdated based on last known update"
  AGENT agent:twin:user_42
  ESCALATE TO agent:service:resource_readiness
```

**"Who else is working on churn analysis right now?"**
```
AWARENESS WITHIN scope:product:retention
  RETURN active_agents, intent FILTER role:twin
```

**"Check if any of my active context has gone stale."**
```
REFRESH CHECK active_context WHERE age > 4h RETURN stale_items
```

---

## Formal Grammar (PEG Notation)

The following Parsing Expression Grammar defines the complete syntax. Every keyword is a distinct uppercase word, every parameter has a clear prefix, and optional clauses can appear in any order within each primitive.

```peg
# Top-level expression
expression     <- resolve / discover / assert / trace / refresh / signal
                / certify / awareness / compare / hypothesize / anchor

# RESOLVE
resolve        <- 'RESOLVE' sp entity (sp from_clause)? (sp with_clause)*
                  (sp include_clause)? (sp fallback_clause)?
from_clause    <- 'FROM' sp scope
with_clause    <- 'WITH' sp (freshness_constraint / reputation_constraint)
freshness_constraint <- 'freshness' sp '<' sp duration
reputation_constraint <- 'reputation' sp '>' sp score
include_clause <- 'INCLUDE' sp annotation_list
fallback_clause <- 'FALLBACK' sp scope (sp arrow sp scope)*

# DISCOVER
discover       <- 'DISCOVER' sp 'concepts' sp related_clause
                  (sp within_clause)? (sp depth_clause)?
                  (sp annotate_clause)? (sp limit_clause)?
related_clause <- 'RELATED' sp 'TO' sp (entity / string_literal)
within_clause  <- 'WITHIN' sp scope (',' sp scope)*
depth_clause   <- 'DEPTH' sp integer
annotate_clause <- 'ANNOTATE' sp annotation_list
limit_clause   <- 'LIMIT' sp integer

# ASSERT
assert         <- 'ASSERT' sp entity sp value_clause sp type_clause
                  sp scope_clause sp agent_clause sp intent_clause
                  sp derived_clause (sp confidence_clause)?
                  (sp relates_clause)* (sp context_clause)?
                  (sp expires_clause)? (sp visibility_clause)?
value_clause   <- 'VALUE' sp (string_literal / json_literal / number)
type_clause    <- 'TYPE' sp entity_type
entity_type    <- 'metric' / 'dimension' / 'attribute' / 'event' / 'relationship'
scope_clause   <- 'SCOPE' sp scope
intent_clause  <- 'INTENT' sp string_literal
derived_clause <- 'DERIVED_FROM' sp '[' sp op_ref (',' sp op_ref)* sp ']'
op_ref         <- 'op:' identifier ':' hex_id
confidence_clause <- 'CONFIDENCE' sp score
relates_clause <- 'RELATES_TO' sp entity sp 'AS' sp relationship_type
                  (sp 'STRENGTH' sp score)?
context_clause <- 'CONTEXT' sp string_literal
expires_clause <- 'EXPIRES' sp duration
visibility_clause <- 'VISIBILITY' sp visibility_level
visibility_level <- 'private' / 'scope' / 'global'

# TRACE
trace          <- 'TRACE' sp entity (sp for_clause)? sp over_clause
                  (sp trace_include)? (sp causal_depth)?
for_clause     <- 'FOR' sp entity
over_clause    <- 'OVER' sp 'last' sp duration
trace_include  <- 'INCLUDE' sp trace_field (',' sp trace_field)*
trace_field    <- 'state_transitions' / 'actors' / 'triggers'
causal_depth   <- 'DEPTH' sp 'causal:' integer

# HYPOTHESIZE
hypothesize    <- 'HYPOTHESIZE' sp entity sp change_clause
                  (sp propagate_clause)? (sp depth_clause)?
                  (sp within_clause)? (sp confidence_constraint)?
                  (sp include_clause)?
change_clause  <- 'CHANGE' sp change_expression
change_expression <- percentage_change / absolute_change / set_change
percentage_change <- ('+' / '-') digit+ '%'
absolute_change <- ('+' / '-') digit+
set_change     <- 'SET' sp (digit+ ('.' digit+)? / string_literal)
propagate_clause <- 'PROPAGATE' sp 'THROUGH' sp relationship_type
                    (',' sp relationship_type)*
relationship_type <- 'DEPENDS_ON' / 'CONTRIBUTES_TO' / 'CAUSES'
                   / 'CORRELATES_WITH' / 'PART_OF'
confidence_constraint <- 'WITH' sp 'confidence' sp '>' sp score

# COMPARE
compare        <- 'COMPARE' sp entity (',' sp entity)+
                  sp across_clause
                  (sp dimensions_clause)? (sp as_of_clause)?
                  (sp with_clause)? (sp include_clause)?
across_clause  <- 'ACROSS' sp scope (',' sp scope)*
dimensions_clause <- 'DIMENSIONS' sp dimension_list
dimension_list <- dimension (',' sp dimension)*
dimension      <- 'value' / 'freshness' / 'reputation' / 'confidence'
                / 'owner' / 'certification' / 'trajectory'
as_of_clause   <- 'AS_OF' sp 'last' sp duration

# ANCHOR
anchor         <- 'ANCHOR' sp context_clause
                  (sp within_clause)? (sp threshold_clause)*
                  (sp anchor_return_clause)?
context_clause <- 'CONTEXT' sp '[' sp entity (',' sp entity)* sp ']'
threshold_clause <- 'THRESHOLD' sp (reputation_threshold / freshness_threshold)
reputation_threshold <- 'reputation' sp '<' sp score
freshness_threshold <- 'freshness' sp '>' sp duration
anchor_return_clause <- 'RETURN' sp anchor_field (',' sp anchor_field)*
anchor_field   <- 'assumption_chain' / 'weakest_link' / 'confidence_floor'
                / 'certification_gaps' / 'staleness_risk'

# SIGNAL
signal         <- 'SIGNAL' sp 'reputation' sp on_clause sp score_clause
                  sp evidence_clause sp agent_clause (sp escalate_clause)?
on_clause      <- 'ON' sp entity
score_clause   <- 'SCORE' sp score
evidence_clause <- 'EVIDENCE' sp string_literal
agent_clause   <- 'AGENT' sp agent_ref
escalate_clause <- 'ESCALATE' sp 'TO' sp agent_ref

# CERTIFY
certify        <- 'CERTIFY' sp entity sp status_clause
                  (sp authority_clause)? (sp supersedes_clause)?
                  (sp certify_evidence)?
status_clause  <- 'STATUS' sp certify_status
certify_status <- 'proposed' / 'under_review' / 'certified' / 'superseded'
authority_clause <- 'AUTHORITY' sp identifier
supersedes_clause <- 'SUPERSEDES' sp entity
certify_evidence <- 'EVIDENCE' sp string_literal

# REFRESH
refresh        <- refresh_check / refresh_expand
refresh_check  <- 'REFRESH' sp 'CHECK' sp 'active_context'
                  (sp where_age)? sp 'RETURN' sp 'stale_items'
where_age      <- 'WHERE' sp 'age' sp '>' sp duration
refresh_expand <- 'REFRESH' sp 'EXPAND' sp branch sp radius_clause
                  (sp capture_clause)?
branch         <- 'branch:' identifier (':' identifier)*
radius_clause  <- 'RADIUS' sp integer
capture_clause <- 'CAPTURE' sp 'peripheral_context'

# AWARENESS
awareness      <- 'AWARENESS' sp within_clause sp return_clause
                  (sp filter_clause)?
return_clause  <- 'RETURN' sp awareness_field (',' sp awareness_field)*
awareness_field <- 'active_agents' / 'intent' / 'progress' / 'locks'
filter_clause  <- 'FILTER' sp role_filter (',' sp role_filter)*

# Terminals
entity         <- 'entity:' identifier ':' identifier
scope          <- 'scope:' identifier (':' identifier)*
agent_ref      <- 'agent:' identifier ':' identifier
duration       <- digit+ ('m' / 'h' / 'd' / 'w')
score          <- '0' '.' digit+  /  '1' '.' '0'+  /  '0'  /  '1'
identifier     <- [a-z_] [a-z0-9_]*
string_literal <- '"' [^"]* '"'
json_literal   <- '{' [^}]* '}'
number         <- '-'? digit+ ('.' digit+)?
hex_id         <- [0-9a-f]+
annotation_list <- identifier (',' sp identifier)*
arrow          <- '→'  /  '->'
sp             <- ' '+
digit          <- [0-9]
integer        <- digit+
```

---

## Delivery via MCP

CQR can be delivered through the Model Context Protocol. When deployed as an MCP server, CQR primitives map to MCP capabilities:

| CQR Primitive | MCP Capability | Type |
|--------------|----------------|------|
| RESOLVE | `cqr_resolve` | Tool |
| DISCOVER | `cqr_discover` | Tool |
| ASSERT | `cqr_assert` | Tool |
| CERTIFY | `cqr_certify` | Tool |
| Strategic vectors, scope hierarchies, policies | — | Resources |

The MCP server is a thin translation layer: JSON-RPC 2.0 messages in, CQR primitive invocations executed, structured results out.

**Governance invariance:** Scope-first semantics, quality metadata, conflict preservation, trust status tracking, and cost accounting are identical regardless of delivery interface — native protocol, MCP, REST, gRPC, or any future transport. Governance enforcement occurs below the delivery layer. No delivery mechanism can bypass, weaken, or alter governance behavior.

---

## Semantic Definition Repository

The authoritative store that CQR operates against:

- **Entity Definitions:** Namespace, name, type, description, adapter mappings, scope assignments, owner, creation timestamp, certification status, and trust status (`:certified` or `:asserted`).
- **Scope Hierarchy:** Tree structure with parent-child relationships, visibility rules, and scope-level configuration.
- **Adapter Routing Table:** Entity-to-adapter mappings including per-primitive capability declarations.
- **Relationship Metadata:** Typed relationships with directionality, strength scores, and scope assignments.

Entities enter through two paths: ASSERT (agent-generated, `:asserted` status) or direct registration followed by CERTIFY (governance workflow, `:certified` status). Both paths produce first-class entities in the repository.

---

## Cross-Domain Reasoning

A distinguishing capability is cross-domain causal reasoning across heterogeneous backends. Consider a TRACE with `DEPTH causal:2` on employee NPS:

1. Graph database adapter returns: declining eNPS → rising attrition rate (HR → HR, depth 1)
2. Same adapter returns: rising attrition rate → increasing operating expenses (HR → Finance, depth 2)
3. Relational database adapter returns specific numerical values at each state transition
4. Merged result: complete cross-domain causal narrative with numbers, timestamps, and confidence scores per link

This requires cognitive primitives for causal reasoning, polyglot fan-out across backends, scope-aware access control, and quality metadata at every step — capabilities that no combination of existing tools provides as a unified query language.

---

## Status

CQR is under active development. This specification describes the protocol as designed and validated. A working implementation achieves the stated accuracy targets on local models.

The protocol is the work of [TEIPSUM](https://teipsum.com). Patent pending.

---

## License

This specification is published for review and community feedback. See [LICENSE](LICENSE) for terms.
