# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] — 2026-04-15

Phase 0: hierarchical entity addressing. Entity addresses become full paths through container entities, and scope governance applies at every level of the path.

### Added

- **Hierarchical entity addressing.** Entity references now accept paths of unlimited depth. `entity:finance:arr` (3 segments), `entity:product:retention:cohort:q4` (5 segments), and deeper are all valid. The leaf is the entity name; every preceding segment after `entity:` is part of the namespace path. The grammar terminal in `lib/cqr/parser/terminals.ex` accepts `entity:<segment>(:<segment>)*` and reduces to `{namespace_path, name}` where `namespace_path` joins the interior segments with `:`.
- **`CONTAINS` edges and container auto-creation.** ASSERT against a deep address auto-creates whichever interior containers are missing as ordinary `Entity` nodes and writes a `CONTAINS` edge from each parent to its child. Containers are created in the asserting agent's active scope, so a `scope:company:product` agent that asserts `entity:product:retention:cohort:q4:weekly` produces four containers (`retention`, `cohort`, `q4`, `weekly`) all in `scope:company:product`.
- **Scope inheritance for auto-created containers.** Containers do not widen with depth. The asserting agent's scope is propagated to every interior node created during the assertion, so containment never leaks an entity into a scope outside the writer's authority.
- **Containment-aware visibility resolution.** Every primitive that resolves an address (RESOLVE, DISCOVER, ASSERT, CERTIFY, SIGNAL, TRACE, UPDATE) now walks the `CONTAINS` chain from root to leaf and checks scope authorization at every level. **A denial at any ancestor returns `entity_not_found`, never `scope_access`.** Agents cannot infer the existence or shape of subtrees in scopes they cannot see.
- **DISCOVER `:*` prefix mode.** When the `RELATED TO` target ends in the literal `:*` sentinel (e.g. `entity:product:retention:*`), DISCOVER switches from typed-relationship neighborhood scan to depth-first `CONTAINS` enumeration. Branch-level scope pruning omits subtrees the agent cannot see and **does not descend into them**, so a blocked subtree is structurally indistinguishable from a missing one. The new `entity_prefix` parser terminal in `lib/cqr/parser/terminals.ex` recognizes the sentinel; routing happens in `lib/cqr/discover.ex`.
- **Post-assert integrity verification.** After every ASSERT the engine verifies that the leaf's full `CONTAINS` chain back to the root is intact and that every interior container exists. A failed integrity check rolls the assertion back rather than leaving the graph in a partial state.
- **Hierarchical relationship parsing.** The CQR `RELATIONSHIPS` clause and the `cqr_assert` MCP shorthand both accept hierarchical target addresses. Shorthand format is now `REL:entity:seg1:seg2(:segN)*:strength` with hierarchical-aware splitting in `lib/cqr_mcp/tools.ex`.
- **Validation suite for hierarchical addressing** (`test/integration/hierarchical_addressing_test.exs`). Ten intents cover RESOLVE / ASSERT / DISCOVER prefix / hierarchical relationships / hierarchical `DERIVED_FROM` / UPDATE / CERTIFY / SIGNAL / TRACE on hierarchical addresses at depths 3, 4, and 5.
- **Integration test suites** for containment-aware visibility (`test/integration/visibility_resolution_test.exs`) and DISCOVER prefix mode (`test/integration/discover_prefix_test.exs`).

### Changed

- MCP tool descriptions for every primitive that accepts an entity reference now document hierarchical addressing with explicit 3, 4, and 5-segment examples. `cqr_discover` documents all three target modes (anchor, prefix, free-text).
- Protocol specification (`docs/cqr-protocol-specification.md`) Section 4 type system entries for `Entity` and the new `Entity Prefix`; Section 5 DISCOVER documents prefix mode; Section 6 adds a "Hierarchical Containment and Scope" subsection.
- Architecture documentation (`docs/architecture.md`) Section 4 ASSERT and DISCOVER entries describe container auto-creation, post-assert integrity verification, and prefix mode; Section 6 adds containment-aware visibility enforcement.
- README adds a "Hierarchical Entity Addressing" section covering depth examples, container auto-creation, scope governance at containment depth, DISCOVER prefix mode, and post-assert integrity verification.
- `mix.exs` version bumped to `0.4.0`.

### Notes for adapter implementers

Hierarchical addresses are transparent to the adapter behaviour contract. The `resolve/3`, `discover/3`, `assert/3`, `update/3`, `signal/3`, `trace/3`, and `certify/3` callbacks continue to receive a parsed expression with the same `{namespace, name}` tuple shape as before — the namespace string may now contain `:` separators when the address is hierarchical, but no callback signatures change. `CONTAINS` edge management, container auto-creation, post-assert integrity verification, and the containment walk for visibility resolution are all engine-layer concerns implemented in the Grafeo reference adapter; new adapters that want feature parity should mirror those behaviors but the contract does not require it.

## [0.3.0]

- UPDATE primitive with version history, governance matrix, and TRACE integration.
- `contested` certification status; `superseded` becomes non-terminal.
- SSE transport routes MCP responses through the SSE stream for external clients.
- GitHub Actions pipeline (test, credo, format check).

## [0.2.0]

- Initial public preview: 12 cognitive primitives, 13 MCP tools, stdio + SSE transports, embedded Grafeo backend.
