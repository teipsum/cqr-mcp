defmodule Cqr.Repo.ScopeTree do
  @moduledoc """
  Scope hierarchy management.

  Loads the scope tree from Grafeo on startup and caches in ETS
  for sub-millisecond lookups. Provides scope visibility, ancestry,
  and existence queries.

  The ETS table stores:
  - `{:scope, path}` → `%{name: _, path: _, level: _, parent: _}`
  - `{:children, path}` → list of child paths
  """

  use GenServer

  require Logger

  @table :cqr_scope_tree
  @default_name __MODULE__

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Check if a scope path exists."
  def scope_exists?(path) when is_list(path) do
    key = Enum.join(path, ":")
    :ets.member(@table, {:scope, key})
  end

  @doc "Get all scope paths."
  def all_scopes do
    :ets.match(@table, {{:scope, :"$1"}, :_})
    |> Enum.map(fn [path] -> String.split(path, ":") end)
    |> Enum.sort()
  end

  @doc """
  Return all scopes visible from the given scope.

  Visibility is bidirectional along the hierarchy:

    * **self**         — the agent's own scope
    * **ancestors**    — for fallback resolution (a `company:finance` agent can
                         fall back to `company`-wide definitions)
    * **descendants**  — a parent scope owns its children, so e.g. a `company`
                         agent can see entities in `company:finance`,
                         `company:product`, etc.

  Siblings are not visible: `company:finance` cannot see `company:engineering`.
  """
  def visible_scopes(path) when is_list(path) do
    key = Enum.join(path, ":")

    case :ets.lookup(@table, {:scope, key}) do
      [{_, _scope_data}] ->
        ancestors = build_ancestors(path)
        descendants = build_descendants(path)
        [path | ancestors] ++ descendants

      [] ->
        []
    end
  end

  @doc "Get direct children of a scope."
  def children(path) when is_list(path) do
    key = Enum.join(path, ":")

    case :ets.lookup(@table, {:children, key}) do
      [{_, child_paths}] -> child_paths
      [] -> []
    end
  end

  @doc "Invalidate and reload the scope tree from Grafeo."
  def reload(name \\ @default_name) do
    GenServer.call(name, :reload)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    load_from_grafeo()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    :ets.delete_all_objects(@table)
    load_from_grafeo()
    {:reply, :ok, state}
  end

  # --- Private ---

  defp load_from_grafeo do
    # Load all scopes
    case Cqr.Grafeo.Server.query(
           "MATCH (s:Scope) RETURN s.name, s.path, s.level ORDER BY s.level"
         ) do
      {:ok, rows} ->
        for row <- rows do
          path = row["s.path"]

          :ets.insert(
            @table,
            {{:scope, path},
             %{
               name: row["s.name"],
               path: path,
               level: row["s.level"]
             }}
          )
        end

      {:error, reason} ->
        Logger.warning("Failed to load scopes: #{inspect(reason)}")
    end

    # Load parent-child relationships
    case Cqr.Grafeo.Server.query(
           "MATCH (child:Scope)-[:CHILD_OF]->(parent:Scope) RETURN child.path, parent.path"
         ) do
      {:ok, rows} ->
        # Group children by parent
        children_map =
          Enum.group_by(rows, fn r -> r["parent.path"] end, fn r ->
            String.split(r["child.path"], ":")
          end)

        for {parent_path, child_list} <- children_map do
          :ets.insert(@table, {{:children, parent_path}, child_list})
        end

      {:error, reason} ->
        Logger.warning("Failed to load scope relationships: #{inspect(reason)}")
    end

    Logger.info("Scope tree loaded into ETS (#{:ets.info(@table, :size)} entries)")
  end

  defp build_ancestors(path) when length(path) <= 1, do: []

  defp build_ancestors(path) do
    parent = Enum.slice(path, 0..-2//1)
    [parent | build_ancestors(parent)]
  end

  defp build_descendants(path) do
    direct = children(path)
    direct ++ Enum.flat_map(direct, &build_descendants/1)
  end
end
