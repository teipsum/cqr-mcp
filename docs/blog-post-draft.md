# Why AI Agents Need a Query Language for Governed Context

Enterprise AI agents have two protocols for reaching outside their own context. **MCP** lets them call tools — APIs, scripts, databases, files — through a uniform interface. **A2A** lets them coordinate with other agents. Between the two, the tooling for agent infrastructure looks solved.

It isn't. There is a third question every production deployment eventually asks, and neither protocol answers it. *Can this agent see this data? How fresh is it? Who owns it? Has anyone certified it as organizational truth, or is it a colleague's working draft? What was it derived from, and how confident should we be in that chain?*

Those questions are not afterthoughts. They are the difference between an agent that can be deployed inside a regulated organization and one that cannot. Today, every company doing this work is building the governance layer itself: ad-hoc metadata bolted onto a vector store, scope filters applied after retrieval, provenance captured in logs nobody reads. None of it composes. All of it fails silently the first time it matters.

The question isn't whether this layer gets built. It's whether a protocol exists that makes the work portable.

## The ordering problem

Conventional retrieval pipelines — RAG, vector databases, hand-rolled similarity search — all share the same architecture. They run a similarity search against the full corpus, return the top-k results, and then apply access control as a filter. Governance is a postcondition.

That ordering is wrong in every governed context. Consider a product manager's agent asking "what's our revenue breakdown?" A similarity-first engine will happily surface HR compensation data if its embedding lands close enough to the query. The filter step catches it — usually. But the existence of the filter is itself a leak: access-denied errors reveal that a document exists, and error-message side channels are a real attack surface in multi-tenant deployments. The result set is also unbounded by scope, so a user with access to one percent of the corpus pays compute costs for the other ninety-nine. And the security model relies on every caller remembering to apply the filter. Security that relies on caller discipline is security that fails.

CQR inverts this. Scope traversal runs first and produces a bounded candidate set. Similarity search and BM25 ranking run *within* that candidate set. Out-of-scope entities never enter the pipeline, because there is nothing to filter — they were never retrieved in the first place. The practical consequences fall out naturally: predictable result-set sizes, compute that scales with the agent's scope rather than the full corpus, and access control that is structural rather than performative.

This is what "governance-first" actually means in an architectural sense. It is the ordering of operations, not a feature.

## What CQR looks like

CQR — Contextual Query Resolution, pronounced "seeker" — sits above MCP and A2A in the agent infrastructure stack. MCP is agent-to-tool. A2A is agent-to-agent. CQR is agent-to-governed-context. It is not a competitor to MCP; the reference implementation *is* an MCP server that exposes CQR primitives as tools any MCP-compatible agent can call.

What CQR adds is a vocabulary designed for machine cognition. The primitives correspond to reasoning patterns, not CRUD verbs. Here is a concrete flow. An agent is asked "what's related to customer churn?" It generates a CQR expression:

```
DISCOVER concepts
  RELATED TO entity:product:churn_rate
  DEPTH 2
  DIRECTION both
  ANNOTATE freshness, reputation, owner
```

The engine walks the scope hierarchy, bounds the candidate set, and composes graph traversal with BM25 full-text and HNSW vector similarity against a single embedded graph database. The response is a neighborhood map: `CORRELATES_WITH entity:product:nps` at strength 0.7, `CONTRIBUTES_TO entity:finance:arr` at strength 0.6, each relationship carrying its direction, its source scope, and a mandatory quality envelope — freshness timestamp, reputation score, owner, certification status, provenance, lineage.

The agent does not have to trust the response blindly. Every field has metadata describing how much to trust it. It can reason about whether to present the number, request a refresh, or escalate to a human. None of that reasoning is possible without structured quality metadata on every response, and none of it is reliable if that metadata is optional. CQR makes it mandatory. Missing fields are explicit `:unknown`, never silently dropped.

Reads are only half the story. Agents also generate context — derived metrics, working hypotheses, synthesized findings — and most systems have no coherent way to absorb that output. Dump it in a scratch table and it pollutes the canonical store. Reject it entirely and you lose the agent's reasoning. CQR splits the difference with a two-tier trust model. The `ASSERT` primitive lets an agent write a new entity with mandatory `INTENT` and `DERIVED_FROM` clauses, and the result lands in the graph as `certified: false` with full lineage to its source entities. It is immediately visible to subsequent resolves and discovers, but every downstream reader knows it is rumor with a paper trail. A separate `CERTIFY` primitive walks definitions through a formal lifecycle — `proposed → under_review → certified → superseded` — with each transition producing an audit record. Agent-generated knowledge becomes governable, not just storable.

And when quality shifts — a pipeline refreshes, a source goes stale, a validation check fails — `SIGNAL` updates reputation scores with evidence and leaves an immutable `SignalRecord` in the audit trail, preserving certification status so "certified but currently degraded" is a first-class state. `TRACE` walks the provenance chain in the other direction: given any entity, it reconstructs the assertion record, the full certification history, every signal written against it, and the `DERIVED_FROM` lineage out to configurable depth. Together, the write primitives and TRACE give the agent an answer not just to "what is this value" but to "how did this come to exist, what has changed it, and why should I trust it."

## The architecture bet

The reference implementation is one Elixir/OTP application. Grafeo — a pure-Rust graph database with LPG + RDF, Cypher + GQL, HNSW vector search, BM25 full-text, and ACID MVCC — is embedded directly into the BEAM via a Rustler NIF. No Docker. No external database. No network hop between engine and storage. The entire server boots in a single OS process and listens on stdio for MCP connections.

The architectural bet is that the BEAM is the right runtime for agent infrastructure. Processes as agents, supervision trees as structural governance, distribution as the scaling story. Every query in CQR goes through a single governance invariance boundary — `Cqr.Engine.execute/2` — which performs scope validation, quality annotation, conflict preservation, and cost accounting before any delivery interface sees the result. Scope traversal is ETS-cached for sub-millisecond lookups. The engine fans out across adapters with `Task.async_stream`. Multi-paradigm query composition — graph traversal plus vector plus full-text against one embedded database — happens inside that boundary, not outside it.

The governance invariance boundary is the load-bearing idea. `Cqr.Engine.execute/2` is the single entry point for every CQR operation, regardless of how the request arrives. MCP tool call, future REST endpoint, future LiveView console, direct Elixir call — all of them funnel through the same function, and the governance checks happen inside it. No delivery interface can bypass scope validation, quality annotation, or cost accounting, because there is no code path that reaches the adapter layer without passing through the engine first. This is a simple architectural invariant, but most governance systems fail precisely because they do not have one: the controls live at the edges, and every new interface either reimplements them or silently omits them.

The adapter contract is backend-agnostic. Grafeo is the reference adapter; PostgreSQL/pgvector, Neo4j, Elasticsearch, and warehouse backends are configuration changes, not code changes. The bet on embedded-by-default is about the first-run experience: clone, `mix deps.get`, `mix run --no-halt`, connect an MCP client, query governed context. Ten minutes, no infrastructure.

The server is open source under Business Source License 1.1. The change date is April 8, 2030, at which point the license automatically converts to MIT License with no restrictions.

## Try it

The repository is at `github.com/teipsum/cqr-mcp`. Clone it, run it, connect Claude Desktop, and query governed context in under ten minutes. The protocol specification lives in `docs/cqr-primer.md` — read that if you want the full eleven-primitive grammar (seven shipped in V1, four reasoning primitives specified for V2) and the adapter behaviour contract.

If you are deploying agents inside an organization that cares about who is allowed to know what, we are talking to design partners. File an issue, open a discussion, and push on the architecture. The problem is real, the work is in progress, and the protocol is ready to be used.
