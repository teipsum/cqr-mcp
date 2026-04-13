defmodule Cqr.Adapter.Behaviour do
  @moduledoc """
  Adapter behaviour contract for CQR storage backends.

  Every storage backend (Grafeo, PostgreSQL, Neo4j, Elasticsearch, etc.)
  implements this behaviour. The engine routes expressions to adapters
  based on their declared capabilities.

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

  @callback normalize(raw_results :: term(), metadata :: term()) :: term()

  @callback health_check() :: :ok | {:error, term()}

  @callback capabilities() :: [atom()]

  @optional_callbacks [
    assert: 3,
    trace: 3,
    signal: 3,
    refresh_check: 3,
    awareness: 3,
    hypothesize: 3,
    compare: 3
  ]
end
