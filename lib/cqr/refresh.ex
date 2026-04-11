defmodule Cqr.Refresh do
  @moduledoc """
  AST struct for the REFRESH primitive.

  REFRESH CHECK scans entities for staleness and returns items that need
  attention. V1 implements CHECK mode only (the lightweight scan);
  EXPAND mode is V2.

  ## Example

      %Cqr.Refresh{
        mode: :check,
        threshold: {24, :h},
        scope: nil
      }

  ## Fields

    * `:mode`      — V1 is always `:check`.
    * `:threshold` — `{amount, unit}` staleness threshold. Entities whose
                     `freshness_hours_ago` exceeds this value are returned.
                     Defaults to `{24, :h}`.
    * `:scope`     — optional scope narrowing. When nil the scan covers
                     every scope visible to the calling agent.
  """

  @type t :: %__MODULE__{
          mode: :check,
          threshold: {pos_integer(), atom()},
          scope: [String.t()] | nil
        }

  defstruct mode: :check,
            threshold: {24, :h},
            scope: nil
end
