defmodule Cqr.Adapter.Behaviour do
  @moduledoc """
  Adapter behaviour contract for CQR storage backends.

  Every storage backend (Grafeo, PostgreSQL, Neo4j, Elasticsearch, etc.)
  implements this behaviour. The engine routes expressions to adapters
  based on their declared capabilities.

  ## Hierarchical entity addressing (v0.4.0)

  Hierarchical addresses are transparent to this contract. The grammar's
  `entity:<segment>(:<segment>)*` terminal reduces to the same
  `{namespace, name}` tuple shape callbacks already receive — the
  `namespace` string may contain `:` separators when the address is
  deeper than three segments, but no callback signatures change.

  Engine-layer concerns that adapters do not need to re-implement:

    * `CONTAINS` edge management and container auto-creation on ASSERT
      (handled by `Cqr.Engine.Assert` against the Grafeo reference
      adapter; non-Grafeo adapters can opt in by implementing the same
      semantics or mark `assert/3` unsupported via `capabilities/0`).
    * Post-assert integrity verification of the container chain.
    * Containment-aware visibility resolution — the engine walks the
      `CONTAINS` chain root-to-leaf and returns `entity_not_found` on
      any ancestor denial, never `scope_access`.
    * DISCOVER's `:*` prefix mode — recognized by the parser and
      dispatched in `Cqr.Discover`; adapters see only the resolved
      anchor or candidate set.

  In short: read-only adapters require no changes for hierarchical
  addresses; write-capable adapters that want feature parity with
  Grafeo should mirror its `CONTAINS` semantics, but the contract
  does not require it.

  See PROJECT_KNOWLEDGE.md Section 3.4.
  """

  @callback resolve(expression :: term(), scope_context :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback discover(expression :: term(), scope_context :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback assert(expression :: term(), scope_context :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback trace(expression :: term(), scope_context :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback signal(expression :: term(), scope_context :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback refresh_check(expression :: term(), scope_context :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback awareness(expression :: term(), scope_context :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback hypothesize(expression :: term(), scope_context :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback compare(expression :: term(), scope_context :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback anchor(expression :: term(), scope_context :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback update(expression :: term(), scope_context :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback normalize(raw_results :: term(), metadata :: term()) :: term()

  @callback health_check() :: :ok | {:error, term()}

  @callback capabilities() :: [atom()]

  @callback namespace_prefix() :: nil | String.t() | [String.t()]

  @optional_callbacks [
    assert: 3,
    trace: 3,
    signal: 3,
    refresh_check: 3,
    awareness: 3,
    hypothesize: 3,
    compare: 3,
    anchor: 3,
    update: 3
  ]
end
