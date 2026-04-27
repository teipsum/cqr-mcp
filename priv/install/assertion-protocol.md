---
entity: entity:governance:assertion_protocol
type: policy
scope: scope:company
owner: cqr-mcp
certified: true
relationships:
  - PART_OF:entity:agent:default:0.9
  - DEPENDS_ON:entity:governance:relationship_guide:0.8
  - CONTRIBUTES_TO:entity:agent:default:0.6
---

# Assertion Protocol

This entity governs every write into the CQR knowledge graph. The CQR engine enforces some of these rules at write time and rejects assertions that fail them. Other rules are conventions you maintain — there is no enforcement, but breaking them produces a graph that future agents (including future instances of yourself) cannot reason over.

The core principle: **orient before you assert.** Every write is permanent. The graph keeps history through VersionRecords; you cannot make an assertion truly disappear, only supersede it. That makes write hygiene a first-order concern. An assertion made hastily — without checking what already exists, without reading the entities you reference, without naming a clear intent — pollutes the graph for everyone who comes after you.

## What the Engine Enforces

The following are checked at write time. An assertion that fails any of them is rejected.

### Mandatory `intent`

Every `cqr_assert` and `cqr_assert_batch` call requires an `intent` field. The intent is a free-text answer to one question: **why are you writing this entity right now?**

Intent is not a description of what the entity contains — that is what the `description` field is for. Intent is the task context, the use case, the question being answered. "I am asserting this engineering observation because the user asked me to investigate why the build broke." "I am asserting this product strategy refinement because the design partner conversation last week introduced a new constraint." "I am asserting this contact entity because I need to track follow-up actions across our pipeline."

Good intent statements survive context loss. A future agent reading the entity for the first time should be able to read the intent and understand what conversation, what task, what triggering event led to this entity existing. Intent is the cognitive anchor that connects an entity to the work that produced it.

Anti-pattern: copy-pasting the description into the intent field. The two are different. Description is what; intent is why.

### Mandatory `derived_from`

Every assertion requires `derived_from` — a comma-separated list of entity references that informed this assertion. This is your cognitive lineage, the sources you read or reasoned from when you produced this entity.

If you read three entities while orienting and then asserted a new entity that synthesizes what you found, those three entities go in `derived_from`. If you produced an entity from external research (a web search, a document, a conversation), record what you can — even if the source is not yet in the graph, name it descriptively in the intent and list any internal entities that contextualized your work.

The lineage is not optional and not decorative. It is how the graph remains auditable: anyone can trace any assertion backward through derived_from to the foundational entities it rests on. A graph with broken lineage chains is a graph nobody can trust.

### Relationship density: 3+

Every assertion needs at least three typed relationships. Below 3, the engine rejects the write. The five relationship types and their semantics are documented in `entity:governance:relationship_guide`. Read that entity if you have not already.

The 3-relationship floor is deliberate. Two relationships is not enough to make an entity discoverable through traversal queries — it is too easy to miss. Three is the minimum density at which an entity participates in the graph as a connected node rather than a near-orphan.

If you cannot find three genuine relationships, the relationship guide has a stuck-state diagnostic. Do not pad with weak relationships to clear the threshold. A rejected assertion is recoverable; a graph full of forced connections is not.

### Duplicate detection: Jaro-Winkler 0.8

The engine checks the description of every new assertion against existing entities in the same namespace using the Jaro-Winkler string similarity metric. If similarity exceeds 0.8, the engine flags it as a likely duplicate and may either reject the write or surface the existing entity for you to consider.

This is a soft check — it catches obvious duplicates ("ACME Corp" and "Acme Corp"), not semantic ones ("our biggest customer" and "ACME Corp"). The deeper protection against duplicates is orient-before-assert: if you DISCOVER and RESOLVE before writing, you find existing entities yourself and either supersede them deliberately or skip the write.

## What You Maintain by Convention

The following are not enforced by the engine. They are practices that distinguish a useful graph from a noisy one.

### Orient before you assert

Before writing into a namespace, run at least one DISCOVER and read the relevant existing entities. Specifically:

- **DISCOVER in the target namespace.** Before asserting `entity:engineering:something`, run `cqr_discover entity:engineering:*` (prefix mode) to see what already exists. You may find an existing entity that should be superseded rather than supplemented.
- **DISCOVER on the topic.** Run a free-text DISCOVER on the keywords your assertion will use. You may find related entities in other namespaces that should appear in your relationships list.
- **RESOLVE the entities you plan to relate to.** Do not declare relationships to entities you have not read. The relationship guide names this anti-pattern (stale reference) for a reason.

The orient-act protocol in `entity:agent:default` describes the full sequence (AWARENESS → DISCOVER → RESOLVE → act). For assertions, the load-bearing step is DISCOVER in the target namespace before writing. Skipping it is the most common cause of duplicate or near-duplicate entities.

### Honest confidence

Every assertion takes a `confidence` value in [0.0, 1.0]. Calibrate honestly:

- **0.9-1.0** — you have direct evidence and your assertion is a faithful summary of it
- **0.7-0.8** — strong reasoning from credible sources but some interpretive synthesis
- **0.5-0.6** — informed but speculative; you would update it readily on new evidence
- **0.3-0.4** — preliminary; flagged for review or further investigation
- **Below 0.3** — barely-grounded; consider whether to assert at all, or assert as a hypothesis rather than an observation

Anti-pattern: defaulting to 0.5. The same calibration plateau described in the relationship guide applies here. If you cannot tell the difference between 0.5 and 0.7 for a particular assertion, you have not thought hard enough about what makes it credible.

### Use `cqr_assert_batch` for 3+ entities

When you have three or more related entities to assert at the same time — say, an installer creating an agent identity, its bootstrap, and its structural reference nodes in one go — use `cqr_assert_batch` rather than calling `cqr_assert` repeatedly.

The batch call accepts an array of entity objects with the same fields as `cqr_assert`. Each entity is executed independently: a failure on one does not block the others. The return value summarizes the result of each.

This is mostly a performance and token-efficiency optimization, but it has a coordination benefit too: a related set of entities all carrying the same intent and asserted in a single call read more clearly in audit history than the same set spread across many individual writes.

### Type discipline

CQR has six entity types: `metric`, `definition`, `policy`, `derived_metric`, `observation`, and `recommendation`. They are not interchangeable.

- **definition** — a stable, structural meaning (an entity, a stage, a category, a role identity)
- **policy** — a rule, protocol, or convention that other agents are expected to follow
- **metric** — a measured quantity from an external system
- **derived_metric** — a metric computed from other metrics
- **observation** — a finding, a state of the world at a point in time, evidence
- **recommendation** — a proposed course of action, a strategy, a plan

When you assert, pick the type that most accurately describes what the entity is. A misclassified entity remains discoverable but loses some of its semantic value: agents looking for policies will not find observations even when the namespace overlaps.

### Namespace discipline

Each agent has a domain namespace and an intake namespace. The conventions are documented in `entity:agent:default`. Briefly:

- **Domain** — your work goes here. Decisions, observations, definitions you produce.
- **Intake** — your inbox. Other agents file work for you here.

Never assert into your own intake. Never assert into another agent's domain. When responding to another agent's work, file in their intake namespace using their conventions.

If your work could benefit another agent — for example a research finding that should inform a product decision — file an intake entity in their namespace rather than dumping the finding into your own domain and hoping they find it.

## When the Engine Rejects Your Assertion

Engine rejections come back as structured errors with a reason. Common reasons and their fixes:

- **Insufficient relationship density.** You have fewer than 3 typed relationships. Run more orientation queries, find genuine connections, retry.
- **Missing intent or derived_from.** The required field is empty or absent. Add it and retry.
- **Duplicate detected.** A near-identical entity exists in the target namespace. RESOLVE it, decide whether to supersede or skip, retry accordingly.
- **Scope access denied.** The target scope is outside what your agent identity can write to. Check `entity:agent:default:coordination` for the agent roster and your namespace; if the rejection is unexpected, escalate to the user.
- **Invalid relationship target.** A relationship in your list points to an entity that does not exist or that you cannot see. RESOLVE the target first; if it does not exist, drop or rewrite that relationship.

Rejections are recoverable. The graph is not corrupted by failed writes — only successful writes change state. Treat rejections as feedback from a strict reviewer, not as failure conditions.

## The Audit Trail

Every assertion creates an AssertionRecord node alongside your Entity. The AssertionRecord captures the full original CQR expression text, the timestamp, the agent_id of who made it, the derived_from list, the intent, and the confidence — verbatim. This means the assertion you just made is replayable from the graph itself, not just inferable from the resulting entity state.

Two consequences worth understanding:

1. **History is permanent.** You cannot delete an assertion, only supersede it with a new one (which creates a VersionRecord linking the old and new versions). Anything you write into the graph stays in the audit chain forever.

2. **Honesty in intent and derived_from has compounding value.** The audit chain is what makes the graph trustworthy across long time horizons. An entity you wrote 3 months ago is interpretable today because the AssertionRecord still carries your reasoning. A graph with weak audit chains becomes unmaintainable as agents and contexts change.

Treat every assertion as something a future agent (or a regulator, or an acquirer's due diligence team) will read. Write the intent and derived_from for that audience.
