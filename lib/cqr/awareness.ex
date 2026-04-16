defmodule Cqr.Awareness do
  @moduledoc """
  AST struct for the AWARENESS primitive.

  AWARENESS returns ambient information about the agent ecosystem visible
  to the calling agent: which agents have been operating in the visible
  scopes recently, what entities they touched, and what their declared
  intents were. The data is reconstructed from audit nodes already
  written by ASSERT, CERTIFY, and SIGNAL -- `AssertionRecord`,
  `CertificationRecord`, and `SignalRecord` -- so AWARENESS is a pure
  read against governance state and never mutates the graph.

  The point is coordination without explicit messaging: an agent can
  "look around" before starting work and avoid duplicating an in-flight
  investigation, see who owns nearby entities, and surface fresh intents
  for the area.

  ## Modes

    * `:active_agents` -- (scan) returns all agent activity in visible
      scopes. The original V1 behaviour.
    * `:search` -- filters audit rows by one or more composable
      predicates: namespace prefix, primitive type, free-text intent
      match, and agent ID. All non-nil filters are AND-composed.

  ## Example

      # Scan (V1)
      %Cqr.Awareness{mode: :active_agents, limit: 20}

      # Search -- all assertions by a specific agent in a namespace
      %Cqr.Awareness{
        mode: :search,
        namespace_prefix: "product",
        primitive_filter: :assert,
        agent_filter: "twin:investigator"
      }

  ## Fields

    * `:mode`             -- `:active_agents` (scan) or `:search`.
    * `:within`           -- optional scope narrowing. When nil the scan
                            covers every scope visible to the calling agent.
    * `:time_window`      -- optional `{amount, unit}` duration; when set,
                            only audit events newer than `now - window` are
                            summarised. When nil the entire history is in scope.
    * `:limit`            -- maximum number of agents to return. Defaults to 20.
    * `:namespace_prefix` -- (search) filter audit rows where the entity
                            namespace starts with this string.
    * `:primitive_filter` -- (search) filter by operation kind: `:assert`,
                            `:certify`, or `:signal`.
    * `:intent_search`    -- (search) free-text substring match against the
                            intent field (case-insensitive).
    * `:agent_filter`     -- (search) exact match on agent_id.
  """

  @type mode :: :active_agents | :search
  @type primitive :: :assert | :certify | :signal

  @type t :: %__MODULE__{
          mode: mode(),
          within: [String.t()] | nil,
          time_window: {pos_integer(), atom()} | nil,
          limit: pos_integer() | nil,
          namespace_prefix: String.t() | nil,
          primitive_filter: primitive() | nil,
          intent_search: String.t() | nil,
          agent_filter: String.t() | nil
        }

  defstruct mode: :active_agents,
            within: nil,
            time_window: nil,
            limit: 20,
            namespace_prefix: nil,
            primitive_filter: nil,
            intent_search: nil,
            agent_filter: nil
end
