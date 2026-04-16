defmodule Cqr.Engine.Planner do
  @moduledoc """
  Query planner — determines which adapters to query for a given AST.

  Routing has two axes:

    * Capability — the adapter must declare support for the primitive
      (`:resolve`, `:discover`, ...). Adapters that do not declare the
      capability are filtered out.

    * Namespace — the adapter must handle the top-level namespace of
      the target entity address. The top-level namespace is the part
      of the entity's namespace string before the first `:` — for
      `{"agent:product_strategy", "orientation"}` it is `"agent"`; for
      `{"github", "issues"}` it is `"github"`.

  Adapters declare the namespaces they handle via
  `namespace_prefix/0`. A specific prefix (or list of prefixes) means
  the adapter only receives traffic for those namespaces. `nil` means
  the adapter is a universal fallback — it receives traffic for any
  namespace that has no matching prefixed adapter.

  Free-text DISCOVER (`DISCOVER "search term"`) has no entity address
  and therefore no namespace. In that case namespace routing is
  skipped and every capable adapter sees the call.
  """

  @doc """
  The fallback adapter list used when the engine context does not
  supply an `:adapters` override. Exposed so the non-planned engine
  paths (ASSERT, TRACE, SIGNAL, etc.) can share the same default.

  Reads from `Application.get_env(:cqr_mcp, :adapters)` at call time
  so runtime config and per-environment overrides are respected.
  Falls back to `[Cqr.Adapter.Grafeo]` when no config is set.

  Each module in the list is validated: it must be loaded and must
  declare `@behaviour Cqr.Adapter.Behaviour`. If any module fails
  validation, an `{:error, %Cqr.Error{}}` is returned instead.
  """
  def default_adapters do
    adapters = Application.get_env(:cqr_mcp, :adapters, [Cqr.Adapter.Grafeo])
    validate_adapters(adapters)
  end

  @doc """
  Resolve a single adapter for a given capability from the engine
  context. Returns `{:ok, adapter}` for the first adapter declaring
  `capability`, or `{:error, %Cqr.Error{}}` if none is applicable.

  Backward-compatible wrapper that performs no namespace routing —
  equivalent to `resolve_adapter(context, capability, nil)`.
  """
  def resolve_adapter(context, capability) when is_atom(capability) do
    resolve_adapter(context, capability, nil)
  end

  @doc """
  Resolve a single adapter for a given capability and target entity
  address. `entity_address` is either a `{namespace, name}` tuple or
  `nil` when the call has no entity (free-text DISCOVER). When an
  address is supplied, the adapter pool is first narrowed by the
  top-level namespace; a universal (nil-prefix) adapter is used only
  if no prefixed adapter matches.
  """
  def resolve_adapter(context, capability, entity_address) when is_atom(capability) do
    adapters =
      Map.get(context, :adapters) ||
        Application.get_env(:cqr_mcp, :adapters, [Cqr.Adapter.Grafeo])

    capable = Enum.filter(adapters, fn adapter -> capability in adapter.capabilities() end)
    routed = filter_by_namespace(capable, top_namespace(entity_address))

    case routed do
      [] ->
        {:error,
         %Cqr.Error{
           code: :no_adapter,
           message: "No adapter supports the #{capability} primitive",
           suggestions: ["Check adapter configuration"]
         }}

      [adapter | _] ->
        {:ok, adapter}
    end
  end

  @doc """
  Plan execution for a parsed AST. Returns a list of
  `{adapter_module, primitive}` tuples to execute.

  ## Parameters
    - ast: parsed CQR expression struct
    - opts: keyword list, may include `:adapters` override
  """
  def plan(ast, opts \\ []) do
    adapters =
      Keyword.get(
        opts,
        :adapters,
        Application.get_env(:cqr_mcp, :adapters, [Cqr.Adapter.Grafeo])
      )

    primitive = primitive_type(ast)

    capable =
      Enum.filter(adapters, fn adapter ->
        primitive in adapter.capabilities()
      end)

    routed = filter_by_namespace(capable, extract_top_namespace(ast))

    case routed do
      [] ->
        {:error,
         %Cqr.Error{
           code: :no_adapter,
           message: "No adapter supports the #{primitive} primitive",
           suggestions: ["Check adapter configuration"]
         }}

      adapters ->
        {:ok, Enum.map(adapters, fn adapter -> {adapter, primitive} end)}
    end
  end

  defp primitive_type(%Cqr.Resolve{}), do: :resolve
  defp primitive_type(%Cqr.Discover{}), do: :discover
  defp primitive_type(%Cqr.Certify{}), do: :certify

  # --- Namespace extraction ---

  defp extract_top_namespace(%Cqr.Resolve{entity: entity}), do: top_namespace(entity)

  defp extract_top_namespace(%Cqr.Discover{related_to: {:entity, entity}}),
    do: top_namespace(entity)

  defp extract_top_namespace(%Cqr.Discover{related_to: {:prefix, [seg | _]}})
       when is_binary(seg),
       do: seg

  defp extract_top_namespace(%Cqr.Discover{related_to: {:search, _}}), do: nil

  defp extract_top_namespace(_ast), do: nil

  defp top_namespace({ns, _name}) when is_binary(ns) do
    ns |> String.split(":", parts: 2) |> List.first()
  end

  defp top_namespace(_), do: nil

  # --- Namespace-based filtering ---
  #
  # A nil `top_ns` means the caller has no entity address to route by
  # (e.g. free-text DISCOVER), so every capable adapter sees the call.
  # Otherwise prefer adapters whose `namespace_prefix/0` matches the
  # top-level namespace, and fall back to universal (nil-prefix)
  # adapters if no prefixed adapter claims the namespace.

  defp filter_by_namespace(adapters, nil), do: adapters

  defp filter_by_namespace(adapters, top_ns) do
    case Enum.filter(adapters, &adapter_matches?(&1, top_ns)) do
      [] -> Enum.filter(adapters, &adapter_universal?/1)
      prefixed -> prefixed
    end
  end

  defp adapter_matches?(adapter, top_ns) do
    case adapter.namespace_prefix() do
      nil -> false
      prefix when is_binary(prefix) -> prefix == top_ns
      prefixes when is_list(prefixes) -> top_ns in prefixes
    end
  end

  defp adapter_universal?(adapter), do: adapter.namespace_prefix() == nil

  # --- Adapter validation ---
  #
  # Checks each configured module is loaded and declares the behaviour.
  # Returns the list on success or `{:error, %Cqr.Error{}}` on failure.

  defp validate_adapters(adapters) when is_list(adapters) do
    case Enum.find(adapters, &(!valid_adapter?(&1))) do
      nil ->
        adapters

      bad ->
        {:error, adapter_validation_error(bad)}
    end
  end

  defp valid_adapter?(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        behaviours =
          module.module_info(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        Cqr.Adapter.Behaviour in behaviours

      {:error, _} ->
        false
    end
  end

  defp valid_adapter?(_), do: false

  defp adapter_validation_error(module) do
    reason =
      case Code.ensure_loaded(module) do
        {:module, _} ->
          "module #{inspect(module)} does not implement Cqr.Adapter.Behaviour"

        {:error, _} ->
          "module #{inspect(module)} could not be loaded " <>
            "(not compiled or not in the code path)"
      end

    %Cqr.Error{
      code: :adapter_not_loaded,
      message: "Invalid adapter configuration: #{reason}",
      suggestions: [
        "Check :adapters in config :cqr_mcp",
        "Ensure the adapter dependency is included in mix.exs"
      ]
    }
  end
end
