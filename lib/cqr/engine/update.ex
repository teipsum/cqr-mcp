defmodule Cqr.Engine.Update do
  @moduledoc """
  UPDATE execution path.

  Validates the request, fetches the target entity, applies the governance
  matrix to decide whether the update is permitted, blocked, or deferred
  to a pending-review contest, and dispatches to the adapter.

  ## Governance matrix

    * **superseded** — any change_type allowed; applies and revives the
      entity (certification -> nil, reputation -> 0.5).
    * **nil / proposed** — any change_type allowed. For `:redefinition`
      and `:reclassification`, certification is reset to nil.
    * **under_review** — `:redefinition` and `:reclassification` are
      blocked ("complete review first"). Others apply without touching
      certification.
    * **certified** — behavior is governed by the
      `:certification_preservation_policy` application config
      (`:cqr_mcp, :certification_preservation_policy`):
        * `:strict` — every change_type transitions the entity to
          `:contested` (pending human review). No exceptions.
        * `:standard` (default) — `:correction`, `:refresh`,
          `:scope_change` apply and preserve certification;
          `:redefinition` and `:reclassification` transition to
          `:contested` via a pending `UpdateRecord`.
        * `:permissive` — every change_type applies immediately and
          preserves certification.
    * **contested** — all updates blocked until the contest is resolved.
  """

  alias Cqr.Engine.Planner
  alias Cqr.Repo.Semantic

  @valid_change_types [
    :correction,
    :refresh,
    :redefinition,
    :scope_change,
    :reclassification
  ]

  @doc """
  Execute an UPDATE operation.

  Returns `{:ok, %Cqr.Result{}}` with the updated entity snapshot on
  successful apply, a pending-review envelope when governance deferred
  the change, or `{:error, %Cqr.Error{}}` when validation or the
  governance matrix rejects the update.
  """
  def execute(%Cqr.Update{} = ast, context) do
    agent_id = Map.get(context, :agent_id, "anonymous")
    visible = resolve_visible_scopes(context)
    scope_context = %{visible_scopes: visible}

    with {:ok, adapter} <- Planner.resolve_adapter(context, :update),
         :ok <- validate_required_fields(ast),
         :ok <- validate_confidence(ast.confidence),
         {:ok, entity_data} <- fetch_visible_entity(ast.entity, visible),
         current <- atomize_status(entity_data[:certification_status]),
         {:ok, mode} <- governance_decision(current, ast.change_type) do
      adapter.update(ast, scope_context,
        agent_id: agent_id,
        previous: entity_data,
        previous_status: current,
        mode: mode
      )
    end
  end

  # --- Governance matrix ---

  # Certified: dispatch to the configured preservation policy. The policy
  # is read at runtime so operators can tune the strictness without a
  # recompile.
  defp governance_decision(:certified, change_type)
       when change_type in @valid_change_types do
    policy = Application.get_env(:cqr_mcp, :certification_preservation_policy, :standard)
    certified_decision(policy, change_type)
  end

  # Under review + semantic change: finish the review first.
  defp governance_decision(:under_review, change_type)
       when change_type in [:redefinition, :reclassification] do
    {:error,
     %Cqr.Error{
       code: :invalid_transition,
       message:
         "UPDATE blocked: entity is under review and #{change_type} cannot " <>
           "proceed until the review completes.",
       retry_guidance:
         "Complete the under_review governance cycle (CERTIFY to certified " <>
           "or back to proposed) before requesting a #{change_type} update."
     }}
  end

  # Under review + non-semantic change: apply, leave certification alone.
  defp governance_decision(:under_review, change_type)
       when change_type in [:correction, :refresh, :scope_change] do
    {:ok, {:apply, reset_cert: false, reset_reputation: false}}
  end

  # Contested: governance contest in flight, no updates allowed.
  defp governance_decision(:contested, _change_type) do
    {:error,
     %Cqr.Error{
       code: :invalid_transition,
       message: "UPDATE blocked: a governance contest is in progress, awaiting review.",
       retry_guidance:
         "Wait for the contest on this entity to be resolved (CERTIFY back to " <>
           "certified or to superseded) before issuing another UPDATE."
     }}
  end

  # Superseded: revival. Any change_type applies and resets certification.
  defp governance_decision(:superseded, _change_type) do
    {:ok, {:apply, reset_cert: true, reset_reputation: true}}
  end

  # Uncertified / proposed: semantic changes reset certification to nil.
  defp governance_decision(status, change_type)
       when status in [nil, :proposed] and
              change_type in [:redefinition, :reclassification] do
    {:ok, {:apply, reset_cert: true, reset_reputation: false}}
  end

  defp governance_decision(status, _change_type) when status in [nil, :proposed] do
    {:ok, {:apply, reset_cert: false, reset_reputation: false}}
  end

  defp certified_decision(:strict, _change_type), do: {:ok, :pending_review}

  defp certified_decision(:permissive, _change_type),
    do: {:ok, {:apply, reset_cert: false, reset_reputation: false}}

  defp certified_decision(:standard, change_type)
       when change_type in [:redefinition, :reclassification],
       do: {:ok, :pending_review}

  defp certified_decision(:standard, _change_type),
    do: {:ok, {:apply, reset_cert: false, reset_reputation: false}}

  # --- Validation ---

  defp validate_required_fields(%Cqr.Update{entity: nil}) do
    {:error,
     %Cqr.Error{
       code: :missing_required_field,
       message: "UPDATE is missing required field: entity",
       retry_guidance:
         "UPDATE requires an entity reference (entity:namespace:name) as the first token"
     }}
  end

  defp validate_required_fields(%Cqr.Update{change_type: nil}) do
    {:error,
     %Cqr.Error{
       code: :missing_required_field,
       message: "UPDATE is missing required field: CHANGE_TYPE",
       retry_guidance:
         "UPDATE requires CHANGE_TYPE with one of: " <>
           "correction, refresh, redefinition, scope_change, reclassification"
     }}
  end

  defp validate_required_fields(%Cqr.Update{change_type: ct}) when ct in @valid_change_types,
    do: :ok

  defp validate_required_fields(%Cqr.Update{change_type: ct}) do
    {:error,
     %Cqr.Error{
       code: :validation_error,
       message: "Invalid CHANGE_TYPE: #{inspect(ct)}",
       retry_guidance:
         "CHANGE_TYPE must be one of: correction, refresh, redefinition, " <>
           "scope_change, reclassification"
     }}
  end

  defp validate_confidence(nil), do: :ok

  defp validate_confidence(score) when is_float(score) and score >= 0.0 and score <= 1.0,
    do: :ok

  defp validate_confidence(score) do
    {:error,
     %Cqr.Error{
       code: :validation_error,
       message: "CONFIDENCE must be between 0.0 and 1.0 (got #{inspect(score)})",
       retry_guidance: "Use a decimal value like 0.5, 0.65, 0.9"
     }}
  end

  # --- Helpers ---

  defp resolve_visible_scopes(context) do
    Map.get_lazy(context, :visible_scopes, fn ->
      agent_scope = Map.get(context, :scope) || raise "Agent scope is required"
      Cqr.Scope.visible_scopes(agent_scope)
    end)
  end

  defp fetch_visible_entity(entity, visible) do
    case Semantic.get_entity(entity, visible) do
      {:ok, data} ->
        {:ok, data}

      {:error, :not_found} ->
        {:error,
         Cqr.Error.entity_not_found(Cqr.Types.format_entity(entity),
           similar: Semantic.search_entities(elem(entity, 1), visible)
         )}

      {:error, :not_visible} ->
        {:error,
         Cqr.Error.entity_not_found(Cqr.Types.format_entity(entity),
           similar: Semantic.search_entities(elem(entity, 1), visible)
         )}

      {:error, reason} ->
        {:error, %Cqr.Error{code: :adapter_error, message: "Grafeo error: #{inspect(reason)}"}}
    end
  end

  # Entity node stores certification_status as a string; atomize for the
  # governance matrix. Safe because writers are constrained to the known
  # statuses by the CERTIFY engine.
  defp atomize_status(nil), do: nil
  defp atomize_status(status) when is_atom(status), do: status

  defp atomize_status(status) when is_binary(status) do
    String.to_existing_atom(status)
  end
end
