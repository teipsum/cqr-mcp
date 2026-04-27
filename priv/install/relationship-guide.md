---
entity: entity:governance:relationship_guide
type: policy
scope: scope:company
owner: cqr-mcp
certified: true
relationships:
  - PART_OF:entity:agent:default:0.9
  - DEPENDS_ON:entity:governance:assertion_protocol:0.6
---

# Relationship Guide

This entity is the practitioner's guide for building typed relationships between entities in the CQR knowledge graph. Reading it once is not enough — refer back when you find yourself reaching for a relationship type out of habit instead of out of analysis.

A graph is only as useful as its edges. Without typed relationships, a CQR graph is just a collection of named documents — discoverable by full-text search and nothing more. The edges are what make traversal queries possible: "what depends on this," "what does this contribute to," "what changes when this changes." Every assertion you make either earns its place in the graph by being meaningfully connected, or it sits as a dead node nobody ever finds.

## The Five Relationship Types

CQR offers five relationship types. Each has a specific test. If your candidate relationship does not pass the test for any of the five, you do not yet have a relationship — you have a topical association, which is not the same thing.

### DEPENDS_ON — upstream dependency

**Test:** Would my entity break, become invalid, or lose meaning if the target entity were removed or changed materially?

DEPENDS_ON is the strongest relationship type. It is reserved for genuine causal or definitional dependencies. A revenue forecast DEPENDS_ON the underlying revenue metric. A product strategy entity DEPENDS_ON the customer segments it targets. A migration plan DEPENDS_ON the system being migrated.

Anti-pattern: using DEPENDS_ON for "this seems related to that." If your entity would still be true and useful with the target removed, it does not depend on it.

### CONTRIBUTES_TO — downstream contribution

**Test:** Does my entity make the target entity stronger, more accurate, more complete, or more actionable?

CONTRIBUTES_TO is the inverse of DEPENDS_ON in spirit but not in graph mechanics — both are directed edges, just from different ends. A bug report CONTRIBUTES_TO the quality of the system it reports against. A research finding CONTRIBUTES_TO the strategy it informs. A design partner conversation CONTRIBUTES_TO the product positioning it shaped.

Use this when your entity is one of several inputs into something larger. The target entity will continue to exist without you, but it is materially weaker without you.

### CORRELATES_WITH — paired observation

**Test:** When one entity changes, should someone check the other?

CORRELATES_WITH is the workhorse relationship type for observational graphs. Two metrics that move together. Two strategic decisions that interact. Two bugs whose fixes might conflict. The relationship does not assert causation — only that change in one is a signal worth investigating in the other.

This is also the right type for "these two things are about the same underlying phenomenon" when you cannot name a stronger structural connection. A customer-facing product change and the marketing campaign for that change CORRELATE_WITH each other; neither depends on the other in a graph-mechanical sense, but a change in one is a signal worth checking against the other.

### CAUSES — direct causal mechanism

**Test:** Can I name the specific mechanism by which my entity causes the target entity?

CAUSES is the rarest and strictest of the five. Use it only when the causal chain is explicit and reproducible. A specific code change CAUSES a specific bug fix. A specific market event CAUSES a specific business decision. A specific configuration change CAUSES a specific behavioral outcome.

If you cannot finish the sentence "my entity causes the target entity *because* ___," do not use CAUSES. Downgrade to CORRELATES_WITH.

### PART_OF — structural containment

**Test:** Is my entity structurally contained by, owned by, or a member of the target entity?

PART_OF is the structural relationship. A specific commit is PART_OF a release. A specific scope is PART_OF a parent scope. A specific agent role is PART_OF the organization it operates within. A specific component is PART_OF the system it belongs to.

PART_OF and DEPENDS_ON are easily confused. The distinguishing question: does the target *contain* my entity (PART_OF), or does my entity *rely on* the target (DEPENDS_ON)? A function in a module is PART_OF the module. A function that calls another function DEPENDS_ON the function it calls.

## Calibrating Strength

Every relationship carries a strength value in [0.0, 1.0]. Use the full range honestly:

- **0.9 — definitional.** The relationship is part of what it means for these entities to exist. Removing it would change the semantics of the source entity.
- **0.7 — strong operational.** The relationship is load-bearing in normal use. The source entity functions without it but loses important context.
- **0.5 — real but secondary.** The relationship is genuine but not central. Useful for traversal queries.
- **0.3 — weak but genuine.** The relationship exists but is peripheral. Including it improves graph richness without claiming more than is warranted.

Anti-pattern: every strength at 0.5. This is the calibration plateau — the cognitive shortcut of "I'm not sure, so middle." Be more specific. If you cannot tell the difference between a 0.5 and a 0.7 for a particular relationship, you have not thought hard enough about why this relationship matters.

## Relationship Density

Aim for **3-8 typed relationships per entity** at assertion time. Below 3, your entity is poorly connected and unlikely to be found through traversal. Above 8, you are probably reaching — most of the trailing relationships will be weak topical associations rather than genuine connections.

Within those bounds, structure your relationships for graph richness:

- At least one **upstream** relationship (DEPENDS_ON or PART_OF — what your entity relies on or belongs to)
- At least one **downstream** relationship (CONTRIBUTES_TO — what your entity strengthens)
- At least one **cross-domain bridge** (a relationship to an entity in a different namespace from yours)

The cross-domain bridge is the most valuable relationship you can build. Within-namespace connections (a sales entity related to other sales entities) tell the graph what the namespace already implies. Cross-namespace connections (a sales entity related to a product entity) teach the graph something the namespace structure cannot capture on its own.

## Anti-Patterns

A few patterns to recognize and avoid:

**Echo chamber.** All relationships go to entities in your own namespace. Your entity is well-connected to its neighbors and disconnected from everything else. Look outside your domain — there is almost always at least one cross-namespace relationship worth declaring.

**Celebrity connection.** Relating your entity to a famous, central entity (the company strategy, the flagship product, a major decision) without a structural basis. If your relationship to the celebrity entity does not pass any of the five tests, you do not have a relationship — you have proximity.

**Strength plateau.** Every relationship at 0.5 because thinking about strength is hard. Force yourself to use the full range. If everything is medium, your strength values carry no information.

**Stale reference.** Relating your entity to an entity you have not actually read. RESOLVE the target before declaring a relationship to it — otherwise you may be relating to something you misremember or that has changed since you last touched it.

**Folder thinking.** Treating namespace hierarchy as the primary organizational tool. CQR sits on a graph database; relationships are first-class. Do not assert `entity:sales:leads` as a category folder and then put leads "in" it via CONTAINS edges. Assert real-world lead entities and relate them to shared structural reference nodes (stage definitions, status values) via DEPENDS_ON or CONTRIBUTES_TO.

## The Golden Rule

Relate to what you actually touched, used, or will feed — not to what shares your topic.

If you read an entity while orienting and used what you learned to inform your assertion, that entity is a candidate for DEPENDS_ON or CONTRIBUTES_TO. If you produced an output that another agent or process will consume, the consumer is a candidate for CONTRIBUTES_TO. If you observed something that moves in tandem with another entity, that other entity is a candidate for CORRELATES_WITH.

If an entity merely shares a keyword with yours, that is not a relationship. The graph already finds keyword matches via free-text DISCOVER. Edges should carry information beyond what the namespace and the description already convey.

## When You Are Stuck

If you have written an entity and cannot find 3 genuine relationships for it, that is a signal worth examining. Two possibilities:

1. **Your entity is too narrow or isolated.** It captures something real but does not connect to the rest of your work. Consider whether it should be merged into a larger entity or whether it is genuinely stand-alone (rare but possible — some root entities really do have only 1-2 relationships).

2. **You have not oriented enough.** You wrote the entity before you understood the neighborhood it belongs in. Run 3-5 DISCOVER queries from different angles — your domain, the technology involved, the strategic context, the historical record, the agents who work in nearby spaces — and read the entities that surface. The relationships will become obvious once the orientation is done.

Either way, do not pad with weak relationships to hit the density target. A genuinely-connected 3-relationship entity is more useful than a 6-relationship entity with three forced connections.
