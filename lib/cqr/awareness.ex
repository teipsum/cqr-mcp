defmodule Cqr.Awareness do
  @moduledoc """
  AST struct for the AWARENESS primitive.

  AWARENESS returns ambient information about the agent ecosystem visible
  to the calling agent: which agents have been operating in the visible
  scopes recently, what entities they touched, and what their declared
  intents were. The data is reconstructed from audit nodes already
  written by ASSERT, CERTIFY, and SIGNAL — `AssertionRecord`,
  `CertificationRecord`, and `SignalRecord` — so AWARENESS is a pure
  read against governance state and never mutates the graph.

  The point is coordination without explicit messaging: an agent can
  "look around" before starting work and avoid duplicating an in-flight
  investigation, see who owns nearby entities, and surface fresh intents
  for the area.

  ## Example

      %Cqr.Awareness{
        mode: :active_agents,
        within: nil,
        time_window: {24, :h},
        limit: 20
      }

  ## Fields

    * `:mode`        — V1 is always `:active_agents`.
    * `:within`      — optional scope narrowing. When nil the scan covers
                       every scope visible to the calling agent.
    * `:time_window` — optional `{amount, unit}` duration; when set, only
                       audit events newer than `now - window` are
                       summarised. When nil the entire history is in scope.
    * `:limit`       — maximum number of agents to return. Defaults to 20.
                       Agents are ranked by recent activity volume.
  """

  @type t :: %__MODULE__{
          mode: :active_agents,
          within: [String.t()] | nil,
          time_window: {pos_integer(), atom()} | nil,
          limit: pos_integer() | nil
        }

  defstruct mode: :active_agents,
            within: nil,
            time_window: nil,
            limit: 20
end
