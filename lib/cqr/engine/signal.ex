defmodule Cqr.Engine.Signal do
  @moduledoc """
  SIGNAL execution path.

  Validates required fields, checks the score range, confirms the target
  entity is visible to the agent, then delegates to the adapter's
  `signal/3` to update the reputation and write a SignalRecord audit node.
  """

  alias Cqr.Engine.Planner
  alias Cqr.Repo.Semantic

  @doc """
  Execute a SIGNAL operation.

  Returns `{:ok, %Cqr.Result{}}` with the previous and new reputation in
  `data`, or `{:error, %Cqr.Error{}}` on missing fields, out-of-range
  score, or an invisible / non-existent target entity.
  """
  def execute(%Cqr.Signal{} = ast, context) do
    agent_id = Map.get(context, :agent_id, "anonymous")
    visible = resolve_visible_scopes(context)
    scope_context = %{visible_scopes: visible}

    with {:ok, adapter} <- Planner.resolve_adapter(context, :signal),
         :ok <- validate_required_fields(ast),
         :ok <- validate_score(ast.score),
         {:ok, entity_data} <- fetch_visible_entity(ast.entity, visible) do
      effective_agent = ast.agent || agent_id

      adapter.signal(ast, scope_context,
        agent_id: effective_agent,
        previous_reputation: entity_data[:reputation]
      )
    end
  end

  defp resolve_visible_scopes(context) do
    Map.get_lazy(context, :visible_scopes, fn ->
      agent_scope = Map.get(context, :scope) || raise "Agent scope is required"
      Cqr.Scope.visible_scopes(agent_scope)
    end)
  end

  # --- Validation ---

  defp validate_required_fields(%Cqr.Signal{} = ast) do
    missing =
      []
      |> check_field(ast.entity, "entity (ON clause)")
      |> check_field(ast.score, "SCORE")
      |> check_field(ast.evidence, "EVIDENCE")
      |> Enum.reverse()

    case missing do
      [] ->
        :ok

      fields ->
        {:error,
         %Cqr.Error{
           code: :missing_required_field,
           message: "SIGNAL is missing required fields: #{Enum.join(fields, ", ")}",
           details: %{missing: fields},
           retry_guidance:
             "SIGNAL requires an ON entity, a SCORE in [0.0, 1.0], and an EVIDENCE rationale"
         }}
    end
  end

  defp check_field(acc, nil, field), do: [field | acc]
  defp check_field(acc, "", field), do: [field | acc]
  defp check_field(acc, _, _), do: acc

  defp validate_score(nil), do: :ok

  defp validate_score(score) when is_float(score) and score >= 0.0 and score <= 1.0,
    do: :ok

  defp validate_score(score) do
    {:error,
     %Cqr.Error{
       code: :validation_error,
       message: "SCORE must be between 0.0 and 1.0 (got #{inspect(score)})",
       retry_guidance: "Use a decimal value like 0.0, 0.5, 0.85, 1.0"
     }}
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
end
