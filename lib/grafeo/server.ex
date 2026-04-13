defmodule Cqr.Grafeo.Server do
  @moduledoc """
  GenServer that owns the embedded Grafeo database handle.

  Starts in the supervision tree, opens the database on init,
  and provides `query/1` as the public API for serialized access
  to the NIF.

  ## Configuration

      config :cqr_mcp, Cqr.Grafeo.Server,
        storage: :memory          # or {:path, "/var/data/cqr.db"}
  """

  use GenServer

  alias Cqr.Grafeo.Native
  alias Cqr.Repo.Seed

  require Logger

  @default_name __MODULE__

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Execute a GQL/Cypher query against the embedded Grafeo database."
  def query(query_string, name \\ @default_name) do
    GenServer.call(name, {:query, query_string})
  end

  @doc "Check database health. Returns `{:ok, version}` or `{:error, reason}`."
  def health(name \\ @default_name) do
    GenServer.call(name, :health)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    storage = Keyword.get(opts, :storage, :memory)
    seed = Keyword.get(opts, :seed, true)
    reset = Keyword.get(opts, :reset, false)

    prepare_storage(storage, reset)

    case open_database(storage) do
      {:ok, db} ->
        Logger.info("Grafeo embedded database started (#{storage_label(storage)})")

        cond do
          seed ->
            Seed.seed_if_empty_direct(db)

          match?({:path, _}, storage) ->
            Seed.bootstrap_if_empty_direct(db)

          true ->
            :ok
        end

        {:ok, %{db: db, storage: storage}}

      {:error, reason} ->
        {:stop, {:grafeo_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:query, query_string}, _from, %{db: db} = state) do
    result = Native.execute(db, query_string)
    {:reply, result, state}
  end

  def handle_call(:health, _from, %{db: db} = state) do
    result = Native.health_check(db)
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, %{db: db}) do
    Native.close(db)
    :ok
  end

  # --- Private ---

  defp prepare_storage({:path, path}, reset) do
    File.mkdir_p!(Path.dirname(path))

    if reset do
      File.rm(path)
      Logger.info("Reset: deleted existing database at #{path}")
    end

    :ok
  end

  defp prepare_storage(:memory, _reset), do: :ok

  defp open_database(:memory) do
    {:ok, _db} = Native.new(:memory)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp open_database({:path, path}) do
    {:ok, _db} = Native.new(path)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp storage_label(:memory), do: "in-memory"
  defp storage_label({:path, p}), do: "persistent: #{p}"
end
