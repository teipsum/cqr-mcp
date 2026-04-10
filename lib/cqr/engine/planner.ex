defmodule Cqr.Engine.Planner do
  @moduledoc """
  Query planner — determines which adapters to query for a given AST.

  In V1 there is only one adapter (Grafeo), but the planner supports
  multiple adapters architecturally. Adding PostgreSQL or Neo4j is a
  configuration change, not a code change.
  """

  @default_adapters [Cqr.Adapter.Grafeo]

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
