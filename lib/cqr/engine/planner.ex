defmodule Cqr.Engine.Planner do
  @moduledoc """
  Query planner — determines which adapters to query for a given AST.

  In V1 there is only one adapter (Grafeo), but the planner supports
  multiple adapters architecturally. Adding PostgreSQL or Neo4j is a
  configuration change, not a code change.
  """

  @default_adapters [Cqr.Adapter.Grafeo]

  @doc """
  The fallback adapter list used when the engine context does not
  supply an `:adapters` override. Exposed so the non-planned engine
  paths (ASSERT, TRACE, SIGNAL, etc.) can share the same default.
  """
  def default_adapters, do: @default_adapters

  @doc """
  Resolve a single adapter for a given capability from the engine
  context. Returns `{:ok, adapter}` for the first adapter declaring
  `capability`, or `{:error, %Cqr.Error{}}` if none is applicable.

  Checks `context[:adapters]` first and falls back to
  `default_adapters/0`. Used by the engine modules whose primitives
  are not routed through `plan/2` (ASSERT, TRACE, SIGNAL, REFRESH,
  AWARENESS, HYPOTHESIZE, COMPARE, ANCHOR).
  """
  def resolve_adapter(context, capability) when is_atom(capability) do
    adapters = Map.get(context, :adapters) || @default_adapters

    case Enum.find(adapters, fn adapter -> capability in adapter.capabilities() end) do
      nil ->
        {:error,
         %Cqr.Error{
           code: :no_adapter,
           message: "No adapter supports the #{capability} primitive",
           suggestions: ["Check adapter configuration"]
         }}

      adapter ->
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
    adapters = Keyword.get(opts, :adapters, @default_adapters)
    primitive = primitive_type(ast)

    applicable =
      Enum.filter(adapters, fn adapter ->
        primitive in adapter.capabilities()
      end)

    case applicable do
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
end
