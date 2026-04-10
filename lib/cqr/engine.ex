defmodule Cqr.Engine do
  @moduledoc """
  Context Assembly Engine — THE governance invariance boundary.

  `execute/2` is the single entry point for all CQR expression execution.
  Everything above this (MCP server, REST API, LiveView UI) goes through here.
  Scope resolution, quality metadata, conflict preservation, and cost accounting
  happen at this level. No delivery interface can bypass them.

  ## Pipeline

      parse → validate scope → plan → execute → merge → annotate quality → cost → return

  See PROJECT_KNOWLEDGE.md Section 3.3 for the data flow.
  """

  alias Cqr.Engine.{Planner, Certify}

  @doc """
  Execute a CQR expression within an agent context.

  ## Parameters
    - expression: String CQR expression or pre-parsed AST struct
    - context: Map with agent context
      - `:scope` — agent's active scope (list of segments), required
      - `:agent_id` — agent identifier (string), optional
      - `:adapters` — override adapter list, optional

  ## Returns
    - `{:ok, %Cqr.Result{}}` with quality metadata envelope and cost
    - `{:error, %Cqr.Error{}}` with informative error semantics
  """
  def execute(expression, context) when is_binary(expression) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, ast} <- Cqr.Parser.parse(expression) do
      execute_ast(ast, context, start_time)
    end
  end

  def execute(%{__struct__: _} = ast, context) do
    start_time = System.monotonic_time(:millisecond)
    execute_ast(ast, context, start_time)
  end

  def execute(_, _) do
    {:error,
     %Cqr.Error{
       code: :invalid_input,
       message: "Expression must be a string or parsed AST struct"
     }}
  end

  # --- Internal pipeline ---

  defp execute_ast(ast, context, start_time) do
    agent_scope = Map.get(context, :scope) || raise "Agent scope is required"
    visible = Cqr.Scope.visible_scopes(agent_scope)
    scope_context = %{visible_scopes: visible}

    enriched_context = Map.put(context, :visible_scopes, visible)

    with {:ok, _} <- validate_scope(ast, agent_scope),
         result <- dispatch(ast, scope_context, enriched_context) do
      case result do
        {:ok, %Cqr.Result{} = r} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          {:ok, annotate_cost(r, elapsed)}

        {:error, _} = err ->
          err
      end
    end
  end

  defp validate_scope(%Cqr.Resolve{scope: nil}, _agent_scope), do: {:ok, :no_scope_constraint}

  defp validate_scope(%Cqr.Resolve{scope: scope}, agent_scope) do
    if Cqr.Scope.accessible?(agent_scope, scope) do
      {:ok, :scope_valid}
    else
      {:error,
       Cqr.Error.scope_access(Cqr.Types.format_scope(scope),
         suggestions:
           Enum.map(Cqr.Scope.visible_scopes(agent_scope), &Cqr.Types.format_scope/1)
       )}
    end
  end

  defp validate_scope(_, _agent_scope), do: {:ok, :no_scope_constraint}

  # --- Dispatch to adapter(s) ---

  defp dispatch(%Cqr.Certify{} = ast, _scope_context, context) do
    Certify.execute(ast, context)
  end

  defp dispatch(ast, scope_context, context) do
    adapters = Map.get(context, :adapters)
    plan_opts = if adapters, do: [adapters: adapters], else: []

    with {:ok, plan} <- Planner.plan(ast, plan_opts) do
      results = execute_plan(plan, ast, scope_context)
      merge_results(results)
    end
  end

  defp execute_plan(plan, ast, scope_context) do
    plan
    |> Task.async_stream(
      fn {adapter, primitive} ->
        case primitive do
          :resolve -> adapter.resolve(ast, scope_context, [])
          :discover -> adapter.discover(ast, scope_context, [])
        end
      end,
      timeout: :timer.seconds(30),
      ordered: false
    )
    |> Enum.map(fn
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, %Cqr.Error{code: :adapter_timeout, message: "#{inspect(reason)}"}}
    end)
  end

  # --- Result merging ---

  defp merge_results([single]), do: single

  defp merge_results(results) do
    {oks, errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    case oks do
      [] ->
        # All failed — return first error
        List.first(errors) ||
          {:error, %Cqr.Error{code: :no_results, message: "No adapter returned results"}}

      _ ->
        merged_data = Enum.flat_map(oks, fn {:ok, r} -> r.data end)
        merged_sources = oks |> Enum.flat_map(fn {:ok, r} -> r.sources end) |> Enum.uniq()

        # Detect conflicts — same entity from different sources
        conflicts =
          merged_data
          |> Enum.group_by(fn
            %{namespace: ns, name: n} -> {ns, n}
            %{entity: e} -> e
            _ -> :ungrouped
          end)
          |> Enum.filter(fn {k, v} -> k != :ungrouped and length(v) > 1 end)
          |> Enum.map(fn {entity, entries} ->
            %{entity: entity, conflicting_values: entries}
          end)

        # Use quality from first successful result
        quality =
          case oks do
            [{:ok, r} | _] -> r.quality
            _ -> %Cqr.Quality{}
          end

        {:ok,
         %Cqr.Result{
           data: merged_data,
           sources: merged_sources,
           conflicts: conflicts,
           quality: quality
         }}
    end
  end

  # --- Cost annotation ---

  defp annotate_cost(%Cqr.Result{} = result, elapsed_ms) do
    cost = %Cqr.Cost{
      adapters_queried: length(result.sources),
      operations: length(result.data),
      execution_ms: elapsed_ms
    }

    %{result | cost: cost}
  end
end
