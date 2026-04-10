# ASSERT Primitive Specification

**CQR Protocol Extension — Context Creation by AI Agents**

Version 0.1 · April 2026

TEIPSUM / UNICA Platform

---

## Innovation Context

This document specifies the ASSERT primitive, the eleventh cognitive operation primitive in the CQR (Cognitive Query Resolution) protocol. ASSERT addresses a fundamental gap in the original protocol design: agents could read, reason over, and govern context, but could not write knowledge back into the governed semantic fabric.

ASSERT is a continuation of the invention disclosed in the SEQUR provisional patent application (filed 2026, USPTO). The protocol has been renamed from SEQUR to CQR to better reflect the cognitive nature of its operations. This specification is committed to the UNICA repository with a GPG-signed commit to establish a timestamped evidence chain linking this extension to the original filing.

The core innovation: agent-generated context enters the semantic layer as **structurally untrusted knowledge** — carrying full provenance about why it was created, what reasoning produced it, and how it connects to existing context — while remaining architecturally distinct from human-certified organizational truth. This trust distinction is itself a first-class cognitive signal that downstream agents use to calibrate their decision confidence.

---

## Problem Statement

In a multi-agent enterprise environment, AI agents continuously generate knowledge: research findings, synthesized insights, correlation discoveries, anomaly detections, recommendations. Without a governed write primitive, this knowledge faces a forced choice:

1. **Ungoverned storage.** Agent-produced knowledge lives outside the semantic layer in scratch space, conversation logs, or ephemeral memory. It cannot be found by DISCOVER, traced by TRACE, assessed by SIGNAL, or grounded by ANCHOR. It is invisible to the governed context fabric — as if it never existed.

2. **Premature certification.** Agent-produced knowledge is forced through the CERTIFY governance workflow, which requires human authority for certification. This is architecturally inappropriate for working knowledge that an agent produces in the course of its tasks. It would flood human authorities with certification requests and create a bottleneck that defeats the purpose of autonomous agents.

Neither option is acceptable. The first wastes agent-generated intelligence. The second collapses the distinction between working knowledge and organizational truth.

ASSERT provides the third path: governed but uncertified context that participates fully in the semantic layer while carrying explicit trust metadata that distinguishes it from certified truth.

---

## The Two-Tier Trust Model

ASSERT introduces a formal distinction between two tiers of context in the semantic layer:

### Certified Context (Organizational Truth)

Context that has passed through the CERTIFY governance workflow and been stamped by human authority. When an agent RESOLVEs certified context, the `certified_by` and `certified_at` fields in the quality metadata envelope are populated. The agent knows this is organizational truth — it can act with higher autonomy and lower confirmation requirements.

Certified context is the **catalog**: the authoritative semantic definitions, metrics, relationships, and governance policies that the organization has explicitly endorsed.

### Asserted Context (Agent-Generated Knowledge)

Context written by agents through ASSERT. It enters the semantic layer with:

- Full provenance metadata (who asserted, when, why, from what)
- A trust status of `:asserted` (distinct from `:proposed`, `:certified`, `:superseded`)
- Self-assessed confidence from the asserting agent
- A reputation score of `0.0` (no community assessment yet)
- Complete graph integration (relationship edges to existing entities)
- A derivation chain linking back to the CQR operations that produced the underlying reasoning

Asserted context is **rumor with a paper trail**. It is visible to DISCOVER, traceable by TRACE, assessable by SIGNAL, and groundable by ANCHOR — but every downstream agent that encounters it sees the trust tier distinction in the quality metadata and calibrates accordingly.

### Trust as a Cognitive Signal

The gap between certified and asserted context is not a deficiency — it is actionable intelligence. When an agent assembles a reasoning chain through ANCHOR and finds that its context includes a mix of certified and asserted data, the quality metadata tells it exactly how much human confirmation it needs before acting:

- A decision grounded entirely in certified context → higher autonomy, lower confirmation threshold
- A decision resting partly on asserted context with high community reputation → moderate confirmation
- A decision resting on fresh assertions with no community assessment → explicit human validation required

The agent doesn't need a hard-coded rule about when to ask for human confirmation. The trust metadata makes the answer emergent from the quality of its context chain.

---

## The Certification Lifecycle

ASSERT creates a natural lifecycle for agent-generated knowledge:

```
ASSERT (agent writes) → SIGNAL (other agents assess) → reputation builds →
  agent strategizes certification path → CERTIFY (human authority approves) →
  organizational truth
```

Getting assertions certified is part of an agent's job. The agent may develop strategies for certification based on the situation:

- **Direct escalation:** The agent identifies the relevant human authority and submits a certification request with its full derivation chain as evidence.
- **Peer validation:** The agent uses AWARENESS to find other agents (particularly digital twins) working in the same domain, shares its assertion, and gathers SIGNAL assessments to build reputation before seeking certification.
- **Authority navigation:** The agent uses AWARENESS and DISCOVER to find the digital twin of the human authority, interacts with that twin to understand the best path to certification for this particular type of knowledge, and tailors its approach accordingly.
- **Deferred certification:** The agent determines that the assertion is useful as working knowledge but does not yet warrant organizational certification, and leaves it in the asserted tier where it accumulates community reputation over time.

This creates emergent governance dynamics: agents don't just produce knowledge — they shepherd it through a trust lifecycle that mirrors how knowledge actually gains authority in human organizations.

---

## Syntax

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

---

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| entity | Yes | — | The entity being asserted. Uses standard `entity:<namespace>:<n>` notation. If the entity does not yet exist in the semantic definition repository, ASSERT creates it with `:asserted` status. If it already exists, ASSERT creates a new version with provenance linking to the prior version. |
| VALUE | Yes | — | The value being asserted. Accepts numeric values, string literals, JSON structures, or temporal expressions. |
| TYPE | Yes | — | The entity type: `metric`, `dimension`, `attribute`, `event`, or `relationship`. Determines how the entity integrates into the semantic graph. |
| SCOPE | Yes | — | The scope this assertion belongs to. The asserting agent must have write access to this scope. Assertions cannot be written to scopes above the agent's authorized level. |
| AGENT | Yes | — | The agent making the assertion. Immutably recorded in the provenance chain. |
| INTENT | Yes | — | A human-readable description of *why* this assertion is being made — the use case, the task context, the question being answered. This is mandatory because every assertion must carry its justification. |
| DERIVED_FROM | Yes | — | References to the CQR operations that produced the reasoning behind this assertion. This is the derivation chain — the cognitive lineage. Accepts operation IDs from prior RESOLVE, DISCOVER, TRACE, HYPOTHESIZE, COMPARE, or ANCHOR operations in the current session. |
| CONFIDENCE | No | 0.5 | The asserting agent's self-assessed confidence in this assertion (0.0–1.0). Distinct from the reputation score, which is community-assessed via SIGNAL. |
| RELATES_TO | No | — | Explicit relationship edges connecting this assertion to existing entities in the graph. Each relationship specifies the target entity, relationship type (`CORRELATES_WITH`, `CAUSES`, `CONTRIBUTES_TO`, `DEPENDS_ON`, `PART_OF`), and optional strength score. |
| CONTEXT | No | — | Additional reasoning context beyond what INTENT captures. May include the agent's interpretation, caveats, or conditions under which the assertion holds. |
| EXPIRES | No | No expiration | Optional TTL for the assertion. After expiration, the assertion remains in the graph but is flagged as `:expired` in quality metadata. Useful for time-sensitive working knowledge that should not persist indefinitely as valid context. |
| VISIBILITY | No | `scope` | Controls who can see this assertion. `private`: only the asserting agent and its bound human. `scope`: all agents with access to the specified scope. `global`: all agents in the system. |

---

## Return Envelope

```
{
  status: :asserted | :conflict | :scope_denied | :invalid_derivation,

  entity: entity:<namespace>:<n>,
  version: <version_id>,

  integration: {
    new_entity: <boolean>,
    relationships_created: <integer>,
    relationships_suggested: [
      {
        target: entity:<ns>:<n>,
        suggested_type: <relationship_type>,
        similarity_score: <0.0-1.0>,
        reason: "<why_this_relationship_is_suggested>"
      },
      ...
    ],
    namespace_collisions: [<existing_entities>] | [],
    graph_impact: {
      nodes_affected: <integer>,
      edges_created: <integer>,
      scopes_touched: [scope:<s>, ...]
    }
  },

  provenance: {
    asserted_by: agent:<type>:<id>,
    asserted_at: <timestamp>,
    intent: "<use_case_description>",
    derived_from: [<operation_refs>],
    confidence: <0.0-1.0>,
    trust_status: :asserted,
    certification_path: {
      recommended_authority: <identifier> | nil,
      estimated_complexity: :routine | :review_required | :cross_domain,
      similar_certifications: [<prior_cert_refs>]
    }
  },

  cost: {
    context_ops: <integer>,
    adapters_queried: [<adapter_ids>]
  }
}
```

---

## Execution Semantics

When an ASSERT expression is received, the context assembly engine executes the following sequence:

**1. Authorization check.** Verify the asserting agent has write access to the specified scope. Agents cannot assert into scopes above their authorized level. If denied, return `:scope_denied`.

**2. Derivation validation.** Verify that the `DERIVED_FROM` operation references are valid — that they reference actual CQR operations executed by this agent in the current or recent sessions. If the derivation chain is invalid or references non-existent operations, return `:invalid_derivation`. This prevents agents from asserting context without a legitimate reasoning chain.

**3. Namespace check.** Check whether the entity already exists in the semantic definition repository. If it exists:
- Create a new version linked to the prior version with full provenance.
- If the existing entity is `:certified`, the assertion creates a parallel `:asserted` version — it does not overwrite certified truth. The divergence is visible to COMPARE.
- If the existing entity is `:asserted` by the same agent, the new assertion supersedes the prior version.
- If the existing entity is `:asserted` by a different agent, both versions coexist. The divergence is a signal, not a conflict to be resolved automatically.

**4. Graph integration.** For each `RELATES_TO` clause, create the specified relationship edge in the semantic graph. Then perform automatic relationship suggestion: embed the new entity and compute cosine similarity against entities in the same scope to identify potential relationships the agent did not explicitly declare. Suggested relationships are returned in the `integration.relationships_suggested` field but are *not* automatically created — they require explicit agent action or human certification.

**5. Provenance recording.** Write the complete provenance record: asserting agent, timestamp, intent, derivation chain, confidence, and all relationship edges. This record is immutable — it cannot be modified after creation. The provenance record is the assertion's "birth certificate."

**6. Certification path analysis.** Analyze the assertion's scope, type, and relationship graph to recommend a certification path. Identify the likely human authority, estimate the complexity of certification (routine for well-established entity types, review-required for novel types, cross-domain for assertions that span scope boundaries), and reference similar prior certifications if they exist.

**7. Index for discoverability.** Register the entity in the semantic definition repository with `:asserted` status. Generate embeddings for vector similarity search. The assertion is now visible to DISCOVER, resolvable by RESOLVE (with `:asserted` trust status), traceable by TRACE, and assessable by SIGNAL.

---

## Side Effects

ASSERT is a write operation. It modifies the semantic definition repository:

- Creates or versions entity definitions
- Creates relationship edges in the semantic graph
- Generates vector embeddings for discoverability
- Writes immutable provenance records

ASSERT does NOT:

- Modify existing certified context
- Overwrite other agents' assertions
- Automatically create suggested relationships
- Bypass scope authorization

---

## Guarantees

- ASSERT always returns a response. If authorization or derivation validation fails, the error envelope explains why.
- The provenance record is immutable once written. No operation can modify the assertion's birth certificate.
- Asserted context is always distinguishable from certified context through the `trust_status` field in quality metadata.
- Asserted context participates fully in all CQR primitives (RESOLVE, DISCOVER, TRACE, COMPARE, HYPOTHESIZE, ANCHOR, SIGNAL, CERTIFY) — it is a first-class citizen of the semantic layer, not a second-class annotation.
- The derivation chain creates an auditable cognitive lineage: any human reviewing an assertion can trace it back through every CQR operation that contributed to the agent's reasoning.

---

## Interaction with Other Primitives

| Primitive | Interaction with Asserted Context |
|-----------|----------------------------------|
| RESOLVE | Returns asserted context with `trust_status: :asserted` and `certified_by: nil` in the quality envelope. The agent sees that this is not certified truth. |
| DISCOVER | Asserted context appears in neighborhood scans, annotated with trust status and asserting agent. |
| TRACE | TRACE can follow the evolution of asserted context — how it was created, when it was modified, when it was SIGNALed, and if/when it was certified. |
| HYPOTHESIZE | Asserted context participates in forward causal propagation. The confidence scores on propagated effects reflect the lower trust of asserted inputs. |
| COMPARE | COMPARE can detect divergences between asserted and certified versions of the same entity across scopes — a powerful signal for governance. |
| ANCHOR | ANCHOR includes asserted context in its epistemic grounding analysis. Assertions with low reputation or no community assessment are flagged as weak links in the reasoning chain. |
| SIGNAL | Other agents can SIGNAL on asserted context, building community reputation. High-reputation assertions become strong candidates for CERTIFY. |
| CERTIFY | CERTIFY can promote an assertion to certified status. The full derivation chain, SIGNAL history, and community reputation become part of the certification evidence. |
| REFRESH | Asserted context with an EXPIRES duration is flagged as stale by REFRESH CHECK when it approaches or exceeds its TTL. |
| AWARENESS | Agents actively asserting context broadcast their intent, making their assertion activity visible to other agents in the same scope. |

---

## Example Expressions

**A digital twin synthesizes a finding from research:**

```
ASSERT entity:product:churn_correlation_nps
  VALUE "NPS scores below 30 correlate with 2.3x higher churn probability"
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

**An agent records an anomaly detection:**

```
ASSERT entity:finance:revenue_anomaly_q1
  VALUE {"type": "deviation", "magnitude": -12.3, "baseline": "trailing_4q_avg"}
  TYPE event
  SCOPE scope:finance:revenue
  AGENT agent:service:anomaly_detector
  INTENT "Automated anomaly detection flagged significant revenue deviation"
  DERIVED_FROM [op:resolve:2f1a, op:trace:3c5b, op:compare:4d6c]
  CONFIDENCE 0.89
  RELATES_TO entity:finance:arr AS DEPENDS_ON STRENGTH 0.95
  EXPIRES 30d
  VISIBILITY scope
```

**A twin captures a strategic insight for its human:**

```
ASSERT entity:strategy:market_entry_risk_latam
  VALUE "Regulatory timeline estimated 8-14 months based on comparable entries"
  TYPE attribute
  SCOPE scope:strategy:expansion
  AGENT agent:twin:user_7
  INTENT "Preparing competitive analysis for board strategy session"
  DERIVED_FROM [op:discover:5e8f, op:resolve:6a9b, op:hypothesize:7c2d]
  CONFIDENCE 0.61
  RELATES_TO entity:strategy:latam_expansion AS CONTRIBUTES_TO STRENGTH 0.7,
             entity:finance:expansion_budget AS DEPENDS_ON STRENGTH 0.5
  CONTEXT "Based on 3 comparable market entries. Confidence limited by regulatory data."
  VISIBILITY private
```

---

## PEG Grammar Extension

```peg
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
agent_clause   <- 'AGENT' sp agent_ref
intent_clause  <- 'INTENT' sp string_literal
derived_clause <- 'DERIVED_FROM' sp '[' sp op_ref (',' sp op_ref)* sp ']'
op_ref         <- 'op:' identifier ':' hex_id
confidence_clause <- 'CONFIDENCE' sp score

relates_clause <- 'RELATES_TO' sp entity sp 'AS' sp relationship_type
                  (sp 'STRENGTH' sp score)? (',' sp relates_clause)*
context_clause <- 'CONTEXT' sp string_literal
expires_clause <- 'EXPIRES' sp duration
visibility_clause <- 'VISIBILITY' sp visibility_level
visibility_level <- 'private' / 'scope' / 'global'

json_literal   <- '{' [^}]* '}'
number         <- '-'? digit+ ('.' digit+)?
hex_id         <- [0-9a-f]+
```

The top-level expression rule in the CQR grammar is extended:

```peg
expression     <- resolve / discover / assert / trace / refresh / signal
                / certify / awareness / compare / hypothesize / anchor
```

---

## Security Considerations

- **Scope enforcement:** Agents cannot assert into scopes above their authorization level. A digital twin bound to a product manager cannot write into `scope:finance:revenue` unless explicitly authorized.
- **Derivation integrity:** The `DERIVED_FROM` requirement prevents agents from injecting context without a legitimate reasoning chain. Every assertion must be traceable to prior CQR operations.
- **Certified context protection:** ASSERT never modifies or overwrites certified context. If an agent asserts a value for an entity that has a certified version, both coexist — the divergence is a governance signal, not a data corruption risk.
- **Immutable provenance:** The provenance record cannot be modified after creation. An agent cannot retroactively change its stated intent or derivation chain.
- **Visibility controls:** The `VISIBILITY` parameter prevents unintended information leakage. Private assertions are invisible to agents outside the asserting agent's human's scope.

---

## Design Rationale

### Why INTENT is mandatory

Every assertion must carry its justification. Without INTENT, the semantic layer accumulates context with no explanation of why it exists. When a human authority reviews an assertion for potential certification, the INTENT field — combined with the derivation chain — provides the complete cognitive story: what the agent was trying to accomplish, what it found, and why it concluded what it concluded.

### Why DERIVED_FROM is mandatory

The derivation chain is the assertion's cognitive lineage. It prevents the semantic layer from becoming a dumping ground for ungrounded claims. An agent cannot assert "revenue will decline 15%" without showing the RESOLVE, TRACE, or HYPOTHESIZE operations that produced that conclusion. This makes every assertion auditable — not by policy, but by architecture.

### Why asserted context starts at reputation 0.0

Asserted context has no community assessment at creation time. Starting at 0.0 means that every agent that encounters the assertion through RESOLVE or DISCOVER sees an explicit signal: "no one else has evaluated this yet." As other agents SIGNAL on the assertion, the reputation rises or falls based on community assessment. This creates a natural quality curve that mirrors how knowledge gains credibility in human organizations.

### Why ASSERT does not auto-certify

The separation between ASSERT and CERTIFY is architectural, not bureaucratic. Certified context is organizational truth — it has been reviewed by human authority and carries institutional weight. Asserted context is agent-generated working knowledge. Collapsing the distinction would either devalue certification (if agents can self-certify) or create an impossible bottleneck (if every assertion requires human certification). The two-tier model preserves the value of both.

---

## Relationship to Filed Patent

This primitive specification extends the CQR protocol (formerly SEQUR) described in the provisional patent application filed with the USPTO in 2026. The core claims in the provisional application cover the cognitive operation primitive architecture, the adapter behavioral contract, the quality metadata envelope, and the scope-first execution semantics. ASSERT builds on all four of these foundations:

- It is a cognitive operation primitive (context creation as a reasoning pattern)
- It writes through the adapter abstraction (governed storage integration)
- It produces and consumes quality metadata (trust status, confidence, reputation, derivation chain)
- It enforces scope-first semantics (scope authorization, visibility controls)

This document is GPG-signed and timestamped to establish a continuous innovation chain from the original filing.
