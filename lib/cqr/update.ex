defmodule Cqr.Update do
  @moduledoc """
  AST struct for the UPDATE primitive.

  UPDATE evolves an existing entity's content while preserving the prior
  state as a `VersionRecord` node linked via `PREVIOUS_VERSION`. The
  governance matrix gates which `change_type` values are permitted for
  a given certification status:

    * `:correction`      — fix a factual error. Always permitted except
                           when contested.
    * `:refresh`         — update to current values without semantic
                           change. Always permitted except when contested.
    * `:scope_change`    — re-scope without redefinition. Permitted on
                           uncertified, under_review, certified, and
                           superseded (revival) entities.
    * `:redefinition`    — change the entity's meaning. Blocked on
                           under_review (finish the review first). On
                           certified entities, triggers contest: the
                           entity transitions to `:contested` and a
                           pending `UpdateRecord` is written; changes
                           are not applied until governance approves.
    * `:reclassification` — change the entity's type. Same governance
                            flow as redefinition.

  Contested entities reject all updates until the contest is resolved.
  """

  @type entity_ref :: {String.t(), String.t()}

  @type change_type ::
          :correction
          | :refresh
          | :redefinition
          | :scope_change
          | :reclassification

  @type t :: %__MODULE__{
          entity: entity_ref(),
          description: String.t() | nil,
          type: String.t() | nil,
          change_type: change_type() | nil,
          evidence: String.t() | nil,
          confidence: float() | nil
        }

  defstruct [:entity, :description, :type, :change_type, :evidence, :confidence]
end
