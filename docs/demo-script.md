# CQR MCP Demo Script

A reproducible walkthrough of the CQR MCP server. Runs in roughly six minutes against a fresh clone — no Docker, no external database, no network dependencies. Every step works every time because the embedded Grafeo database and sample dataset ship with the repository.

The demo covers the full V1 knowledge lifecycle: resolve canonical context, discover neighborhoods, enforce scope boundaries, assert agent findings with provenance, and certify them through the governance lifecycle.

---

## Setup (30 seconds)

```bash
git clone https://github.com/teipsum/cqr-mcp.git
cd cqr-mcp
mix deps.get
mix run --no-halt
```

On first boot the embedded Grafeo database is created, the sample SaaS dataset is seeded (6 scopes, 27 entities, 17 typed relationships), and the server begins listening on stdio for MCP connections.

In a second terminal, connect Claude Desktop (or any MCP client) to the running server. The tools `cqr_resolve`, `cqr_discover`, `cqr_certify`, and `cqr_assert` should appear in the client's tool picker.

For the rest of the demo, commands are issued through the MCP client as natural-language prompts. The client's LLM translates them into CQR expressions and calls the appropriate tool.

---

## 1. RESOLVE — point lookup with quality metadata (45 seconds)

**Prompt the agent:**
> What's our current churn rate?

**Under the hood** — the agent calls `cqr_resolve` with:

```json
{ "entity": "entity:product:churn_rate" }
```

**What to show:**
- The returned entity value
- The mandatory quality envelope: `freshness`, `reputation`, `owner`, `certified_by`, `certified_at`, `provenance`, `lineage`
- The `cost` field with `adapters_queried`, `operations`, and `execution_ms`

**Point to make:** this is not a raw database query. Every response carries trust metadata. The agent can reason about whether the number is fresh enough to present, whether it has been certified, and who owns it — without any custom integration code.

---

## 2. DISCOVER — neighborhood exploration (45 seconds)

**Prompt the agent:**
> What's related to churn?

**Under the hood** — the agent calls `cqr_discover` with:

```json
{ "topic": "entity:product:churn_rate", "depth": 2, "direction": "both" }
```

**What to show:**
- The typed relationships: `CORRELATES_WITH entity:product:nps`, `DEPENDS_ON entity:product:feature_adoption`, `CONTRIBUTES_TO entity:finance:arr`
- The direction tag on each result (outbound, inbound)
- The strength score on each edge
- Quality annotations on each neighbor

**Point to make:** the agent now has a map of the knowledge neighborhood around churn. Direction is explicit — no reverse-edge ambiguity. The agent can walk outward through CORRELATES_WITH to NPS, or inward through CONTRIBUTES_TO to see what churn affects.

---

## 3. DISCOVER — free-text semantic search (45 seconds)

**Prompt the agent:**
> Find concepts related to "customer satisfaction".

**Under the hood** — the agent calls `cqr_discover` with a string literal:

```json
{ "topic": "customer satisfaction", "depth": 2 }
```

**What to show:**
- Results ranked by combined BM25 full-text and HNSW vector similarity
- Source attribution on each result: `:text`, `:vector`, or `:both`
- entity:product:nps and entity:product:churn_rate should both appear, scored by relevance

**Point to make:** multi-paradigm search — graph traversal, full-text, and vector similarity — composed in a single query against one embedded database. No separate vector store, no separate search index, no glue code. And because scope traversal ran first, the results are already bounded by what this agent is allowed to see.

---

## 4. Scope enforcement — the governance guarantee (60 seconds)

**Set the agent scope to product:**

```bash
export CQR_AGENT_SCOPE=scope:company:product
```

Restart the server and reconnect the MCP client.

**Prompt the agent:**
> Resolve entity:hr:headcount.

**What to show:**
- The response: `entity_not_found` — not `access_denied`
- The entity exists in the database. The product-scoped agent simply cannot see it.

**Point to make:** this is genuine invisibility, not post-hoc filtering. The HR entity never enters the candidate set. There is no filter to forget, no error message that leaks the entity's existence, no side channel.

**Now change the scope to the company root:**

```bash
export CQR_AGENT_SCOPE=scope:company
```

Restart and reconnect.

**Prompt the agent again:**
> Resolve entity:hr:headcount.

**What to show:**
- The entity resolves successfully
- The quality envelope includes the HR team as owner

**Point to make:** visibility is bidirectional along the scope hierarchy. The root scope sees all descendants, including HR. Siblings remain isolated — the product agent cannot see HR, and the HR agent cannot see product. This is real access control, not a filter.

---

## 5. ASSERT — agent writes with provenance (60 seconds)

**Prompt the agent (back at company scope):**
> Based on the correlation between churn and NPS, I'm seeing a leading-indicator pattern. Assert this as a derived metric.

**Under the hood** — the agent calls `cqr_assert` with an entity definition that carries mandatory `INTENT` and `DERIVED_FROM` fields pointing back to `entity:product:churn_rate` and `entity:product:nps`.

**What to show:**
- The new entity is created with `certified: false` and `reputation: 0.5`
- The lineage chain links back to the source entities
- The asserting agent's identity is recorded
- `RESOLVE` the new entity — it is immediately visible, with its asserted trust markers intact

**Point to make:** agent-generated knowledge is governable. Every write carries a paper trail — intent, lineage, authority — and the trust state is explicit. This is how you build a knowledge graph that grows through agent use without losing the ability to audit it.

---

## 6. CERTIFY — governance lifecycle (45 seconds)

**Prompt the agent:**
> Certify the new derived metric. Move it through proposed, under_review, and then certified, with authority "data_science_lead" and evidence "validated against Q1 cohort data".

**Under the hood** — three `cqr_certify` calls, one per state transition. Each transition creates an audit record with authority, evidence, and timestamp.

**What to show:**
- The entity moves through `proposed → under_review → certified`
- After certification, `RESOLVE` on the entity now returns:
  - `certified: true`
  - `certified_by: "data_science_lead"`
  - `certified_at: <timestamp>`
  - Reputation jumps from 0.5 to 0.9
- The governance audit trail is queryable

**Point to make:** the full knowledge lifecycle in one protocol. Discover existing context, derive new findings with provenance, govern those findings through a formal lifecycle. Every step is a CQR primitive. Every step leaves an audit trail.

---

## Closing (30 seconds)

Zero Docker. Zero external database. One OS process. Under ten minutes from `git clone` to governed context in Claude Desktop.

**Links:**
- Repository: `github.com/teipsum/cqr-mcp`
- Protocol primer: `docs/cqr-primer.md`
- Architecture: `docs/architecture.md`
- MCP integration: `docs/mcp-integration.md`

---

## Troubleshooting

**Server fails to boot.** Check Elixir (1.15+) and Erlang/OTP (26+). The precompiled Grafeo NIF ships with the hex package — no Rust toolchain required.

**Claude Desktop shows no tools.** Confirm the MCP server config in `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) points to the correct `elixir` binary and `cwd`. Restart Claude Desktop after changes.

**Scope change does not take effect.** `CQR_AGENT_SCOPE` is read at server startup. Restart `mix run --no-halt` and reconnect the MCP client after any scope change.

**Entity not found when you expected it.** Confirm the agent's active scope by reading the `cqr://session` resource. If the entity lives in a sibling scope, it is genuinely invisible — this is the intended behavior, not a bug.
