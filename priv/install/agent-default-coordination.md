---
entity: entity:agent:default:coordination
type: definition
scope: scope:company
owner: cqr-mcp
certified: false
relationships:
  - PART_OF:entity:agent:default:0.9
  - CONTRIBUTES_TO:entity:agent:default:0.6
  - DEPENDS_ON:entity:install:setup:0.5
---

# Agent Coordination Roster

This entity is the canonical roster of specialist agents in this CQR knowledge graph. Every agent reads it during the orient-act protocol to discover who else operates here, what their domain namespaces are, and how to file work for them via their intake conventions.

## Current State: Empty

No specialist agents are configured yet. This graph is in its initial state — only the universal protocols and the installer entity exist.

To set up specialist agents, RESOLVE `entity:install:setup` and follow the guided setup. The installer will ask 4-5 questions about your organization and the roles you need, then assert agent identities, specialist bootstraps, and structural reference nodes for each role you choose. When setup completes, this entity will be UPDATEd with the agent roster.

If you are an agent that has just bootstrapped and you find this roster empty, you are likely the first agent in this graph. Either the user is testing CQR before running the installer, or they intend you to operate as a generic agent. Proceed with the user's request; do not assume specialist agents exist that have not been declared here.

## Roster Format (After Setup)

Once the installer runs, this entity's description will be UPDATEd to a roster section listing each configured agent with:

- **Identity address** — `entity:agent:{role}` — the agent's identity entity
- **Bootstrap address** — `entity:agent:{role}:bootstrap` — the agent's specialist bootstrap
- **Domain namespace** — `entity:{domain}:*` — where the agent's own work lives
- **Intake namespace** — `entity:{domain}:intake:*` — where other agents file work for this agent
- **Brief description** — what the agent focuses on, drawn from the installer conversation

Agents reading this roster after setup should use it for outbound coordination. If your work could benefit another agent, file an intake entity in their namespace using their conventions, rather than asserting into your own domain and hoping they find it.
