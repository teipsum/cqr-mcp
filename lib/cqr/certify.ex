defmodule Cqr.Certify do
  @moduledoc """
  AST struct for the CERTIFY primitive.

  Manages definition lifecycle through proposal, review, and
  certification phases.

  ## Example

      %Cqr.Certify{
        entity: {"finance", "arr"},
        status: :proposed,
        authority: "cfo",
        supersedes: {"finance", "arr_legacy"},
        evidence: "Validated against Q4 actuals"
      }
  """

  @type t :: %__MODULE__{
          entity: {String.t(), String.t()},
          status: :proposed | :under_review | :certified | :superseded,
          authority: String.t() | nil,
          supersedes: {String.t(), String.t()} | nil,
          evidence: String.t() | nil
        }

  defstruct [:entity, :status, :authority, :supersedes, :evidence]
end
