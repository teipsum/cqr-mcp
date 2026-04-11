# A CQR Primer

*What CQR is, what problem it solves, and why it looks the way it does. Read this first if you have never seen the protocol before.*

## The Governed Context Gap

Enterprise AI agents already have two protocols for reaching out into the world:

- **MCP (Model Context Protocol)** lets an agent call tools — APIs, scripts, databases, files — through a uniform interface.
- **A2A (Agent-to-Agent)** lets agents communicate and coordinate with one another.

Neither protocol answers the questions every governed deployment eventually hits. *What is this agent authorized to know?* *How fresh is the data it just received?* *Who owns it?* *Is it certified organizational truth, or a colleague's working draft?* *What other data was it derived from, and how confident should we be in that chain?*

Conventional retrieval pipelines — RAG systems, vector databases, even hand-rolled lookup — treat these questions as afterthoughts. Access control is a filter slapped on after a similarity search. Provenance is something you hope your logging captured. Freshness is whatever the ingestion pipeline last wrote. Certification is a spreadsheet someone in governance maintains.

This works until you deploy an agent at scale inside an organization that actually cares about any of it. Then it stops working, and the fixes — custom metadata layers bolted onto vector stores, brittle scope filters applied after retrieval, ad-hoc provenance conventions — do not compose.

**CQR is the layer that composes.** It is a declarative query protocol designed from the first line for *machine cognition as the primary consumer*. Agents generate CQR expressions directly from natural-language intent. The protocol's primitives correspond to reasoning patterns, not data operations. Quality metadata is mandatory. Scope is first-class. Provenance is built into the grammar of writes.

## Eleven Cognitive Operation Primitives

CQR defines eleven primitives in five categories. Each one maps to a cognitive operation an agent actually performs, not a CRUD verb.

### Context Resolution

**RESOLVE** — *Targeted retrieval.* The agent already knows what it wants: a specific canonical concept by semantic address. RESOLVE returns the single authoritative instance from the nearest matching scope, with quality metadata. Optional clauses constrain freshness, reputation, and the scope fallback chain.

**DISCOVER** — *Neighborhood scan.* The agent wants to orient itself. DISCOVER composes graph traversal, full-text search, and vector similarity to return a navigable map of concepts related to an anchor entity or search term. Direction control (`outbound`, `inbound`, `both`) and depth limits give the agent fine-grained control over exploration scope.

### Context Creation

**ASSERT** — *Uncertified write with provenance.* Agents write findings, derived metrics, and working hypotheses into the graph with mandatory `INTENT` and `DERIVED_FROM` fields. Asserted entities are immediately visible to RESOLVE and DISCOVER but carry explicit trust markers — `certified: false`, the asserting agent's identity, the lineage chain back to source entities. This is "rumor with a paper trail," and it is what makes agent-generated knowledge governable.

### Reasoning

**TRACE** — *Provenance history.* Walks AssertionRecords, CertificationRecords, SignalRecords, and `DERIVED_FROM` chains to reconstruct how an entity came to exist and what changed it. Configurable causal depth steps through the lineage chain one hop at a time, and an optional time window filters history events. TRACE is how an agent explains not just what it knows, but *how* it came to know it and why it should be trusted.

### Governance

**CERTIFY** — *Lifecycle management.* Definitions move through a formal lifecycle: `proposed → under_review → certified → superseded`. Each transition creates an audit record with authority, evidence, and timestamp. After certification, RESOLVE on the entity returns `certified: true` with the certifying authority in the quality envelope. This is how asserted knowledge becomes organizational truth.

**SIGNAL** — *Quality assessment.* Writes a reputation score update with evidence and creates an immutable `SignalRecord` audit node. Use SIGNAL when data quality changes — a pipeline refreshed, a source went stale, a validation check failed. Unlike CERTIFY, SIGNAL preserves the entity's certification status while updating its reputation, so "certified but currently degraded" is expressible. Every signal is surfaced through TRACE as part of the entity's provenance chain.

### Maintenance

**REFRESH** — *Staleness scan.* `CHECK` mode scans every entity visible to the agent and returns those whose freshness exceeds a configurable threshold, sorted most-stale-first. This is a lightweight periodic health check — an agent loop can call REFRESH before answering questions to identify context that needs attention and proactively re-read, re-signal, or escalate it before the staleness silently corrupts downstream reasoning.

### V2 Primitives (Not Yet Shipped)

Four further primitives are specified but not yet shipped in this MCP server:

- **HYPOTHESIZE** *(Reasoning)* — projects outbound effects of an assumed change through the relationship graph with confidence scoring.
- **COMPARE** *(Reasoning)* — side-by-side comparison of multiple entities, surfacing shared relationships and quality differentials.
- **ANCHOR** *(Reasoning)* — evaluates the composite confidence of a set of resolved entities as a reasoning chain, returning a weakest-link floor and actionable recommendations.
- **AWARENESS** *(Perception)* — ambient perception of other agents operating in scope, their declared intent, and the resources they hold. Enables coordination without explicit messaging.

**This server implements seven primitives: RESOLVE, DISCOVER, ASSERT, CERTIFY, TRACE, SIGNAL, REFRESH.** The remaining four primitives are specified in the protocol and ship in V2.

## Governance-First Ordering

The single most important architectural decision in CQR is the ordering of operations during a DISCOVER.

Conventional RAG: search the full vector index for top-k similar documents, then filter by access control. This is backwards for three reasons:

1. **It leaks.** Access-denied errors reveal that the entity exists. Error-message side-channels are a real attack surface in multi-tenant deployments.
2. **It is unbounded.** Result-set sizes depend on top-k against a global corpus, not on the user's scope. A user with access to 1% of the data pays compute costs for the other 99%.
3. **It is brittle.** Filter-after retrieval depends on every caller remembering to apply the filter. Security that relies on every caller being careful is security that fails.

CQR inverts this. Scope traversal runs *first* and produces a candidate set bounded by the agent's visible scopes. Similarity search and BM25 ranking run *within* that candidate set. Out-of-scope entities never enter the pipeline — there is no filter to forget, because there is nothing to filter.

The practical result: predictable result-set sizes, compute efficiency that scales with scope rather than corpus, and security that is structural rather than performative.

## Quality Metadata

Every CQR response carries a mandatory quality envelope:

```json
{
  "data": [...],
  "quality": {
    "freshness":    "2026-04-10T09:12:00Z",
    "confidence":   0.92,
    "reputation":   0.87,
    "owner":        "finance_team",
    "lineage":      ["q4_actuals_v3", "q4_actuals_v2"],
    "certified_by": "cfo",
    "certified_at": "2026-03-14T16:00:00Z",
    "provenance":   "grafeo:finance:q4_actuals"
  },
  "sources": ["grafeo"],
  "cost": { "adapters_queried": 1, "operations": 3, "execution_ms": 8 }
}
```

This envelope is what makes CQR different from a raw database query. The agent receives not just data but metadata about the data's trustworthiness. It can reason about whether to present the number, ask for confirmation, request a REFRESH, or escalate to a human. None of that reasoning is possible without structured quality metadata, and none of it is reliable if the metadata is optional.

The `cost` field is equally deliberate. It feeds into an agentic budget model: teams receive allocations of context operations, and every query debits the budget. Natural accountability, measurable ROI, and a brake on runaway autonomous exploration.

## CQR vs. RAG

| Dimension | RAG | CQR |
|-----------|-----|-----|
| Search ordering | Similarity first, filter after | Governance first, similarity within scope |
| Access control | Post-retrieval filter | Query-level enforcement |
| Quality metadata | None or external | Mandatory envelope on every response |
| Provenance | Untracked | Mandatory on writes (INTENT + DERIVED_FROM) |
| Multi-backend | Single vector DB | Adapter fan-out across heterogeneous stores |
| Result set | Top-k from global corpus | Bounded by scope hierarchy |
| Error model | Exceptions | Structured data the agent can reason over |
| Primary consumer | Human developer via tool call | Agent via direct generation |

RAG is a pattern for retrieval. CQR is a protocol for governed retrieval. They solve adjacent problems, but only one of them composes inside an enterprise that cares about who is allowed to know what.
