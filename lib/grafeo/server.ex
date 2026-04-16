defmodule Cqr.Grafeo.Server do
  @moduledoc """
  GenServer that owns the embedded Grafeo database handle.

  Starts in the supervision tree, opens the database on init,
  and provides `query/1` as the public API for serialized access
  to the NIF.

  ## Configuration

      config :cqr_mcp, Cqr.Grafeo.Server,
        storage: :memory          # or {:path, "/var/data/cqr.db"}

  In persistent mode, a periodic checkpoint is scheduled so that a SIGKILL
  bounds data loss to `checkpoint_interval_ms` (default 10s). The timer is
  skipped for `:memory` storage to keep tests deterministic.
  """

  use GenServer

  alias Cqr.Grafeo.Native
  alias Cqr.Repo.Seed

  require Logger

  @default_name __MODULE__
  @default_checkpoint_interval_ms 10_000

  # Every NIF call is bounded by this timeout. A well-formed GQL query
  # against an in-memory or on-disk Grafeo finishes in milliseconds; this
  # ceiling exists to contain the DirtyIo hang that malformed GQL used to
  # trigger. If a Native.execute/2 ever runs longer than this the
  # GenServer replies with `{:error, :nif_timeout}` and stays responsive
  # for the next caller. 30 s is deliberately generous — long enough to
  # not flap on a cold, multi-thousand-node traversal, tight enough that
  # a real hang becomes observable rather than fatal.
  @default_nif_timeout_ms 30_000
  # The GenServer.call must outlast the in-server NIF timeout, otherwise
  # the caller raises :timeout before the server can reply with its
  # bounded error. Padding keeps the two timeouts from racing.
  @call_timeout_pad_ms 2_000

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Execute a GQL/Cypher query against the embedded Grafeo database.

  The request is dispatched via a supervised Task inside the server so a
  hung NIF cannot wedge the mailbox. A timeout surfaces as
  `{:error, :nif_timeout}` instead of an `:exit` from GenServer.call.
  """
  def query(query_string, name \\ @default_name) do
    timeout = nif_timeout_ms() + @call_timeout_pad_ms
    GenServer.call(name, {:query, query_string}, timeout)
  end

  @doc "Check database health. Returns `{:ok, version}` or `{:error, reason}`."
  def health(name \\ @default_name) do
    GenServer.call(name, :health)
  end

  @doc """
  Force an immediate checkpoint. Primarily for tests; persistent-mode
  servers also checkpoint on a timer. Returns `:ok` or `{:error, reason}`.
  """
  def checkpoint(name \\ @default_name) do
    GenServer.call(name, :checkpoint)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    storage = Keyword.get(opts, :storage, :memory)
    seed = Keyword.get(opts, :seed, true)
    reset = Keyword.get(opts, :reset, false)

    checkpoint_interval_ms =
      Keyword.get(opts, :checkpoint_interval_ms, @default_checkpoint_interval_ms)

    nif_timeout_ms = Keyword.get(opts, :nif_timeout_ms, nif_timeout_ms())

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

        state = %{
          db: db,
          storage: storage,
          checkpoint_interval_ms: checkpoint_interval_ms,
          nif_timeout_ms: nif_timeout_ms
        }

        schedule_checkpoint(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:grafeo_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:query, query_string}, _from, %{db: db} = state) do
    result = execute_with_timeout(db, query_string, state.nif_timeout_ms)
    {:reply, result, state}
  end

  def handle_call(:health, _from, %{db: db} = state) do
    result = Native.health_check(db)
    {:reply, result, state}
  end

  def handle_call(:checkpoint, _from, %{db: db} = state) do
    {:reply, run_checkpoint(db, state.storage), state}
  end

  @impl true
  def handle_info(:checkpoint_tick, %{db: db, storage: storage} = state) do
    case run_checkpoint(db, storage) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Grafeo periodic checkpoint failed: #{inspect(reason)}")
    end

    schedule_checkpoint(state)
    {:noreply, state}
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

  # Periodic checkpoints only make sense for persistent storage; the
  # in-memory backend has nothing to flush.
  defp schedule_checkpoint(%{storage: {:path, _}, checkpoint_interval_ms: interval})
       when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :checkpoint_tick, interval)
    :ok
  end

  defp schedule_checkpoint(_state), do: :ok

  defp run_checkpoint(db, {:path, _}) do
    case Native.checkpoint(db) do
      :ok -> :ok
      other -> {:error, other}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp run_checkpoint(_db, :memory), do: :ok

  # Run Native.execute/2 inside a short-lived Task so a hung DirtyIo NIF
  # cannot park this GenServer forever. On timeout the Task is shut down
  # and an `{:error, :nif_timeout}` is returned; the BEAM cannot preempt
  # the NIF itself (it keeps running on the dirty-scheduler thread until
  # it chooses to yield), but the mailbox remains drainable so the next
  # caller is served. The root fix is to never produce malformed GQL
  # (see `Cqr.Adapter.Grafeo.escape/1`); this wrapper exists so a future
  # regression degrades into an observable error rather than a silent
  # process wedge.
  defp execute_with_timeout(db, query, timeout) do
    task = Task.async(fn -> Native.execute(db, query) end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.error(
          "Grafeo NIF timed out after #{timeout}ms; query prefix: #{inspect(binary_slice(query, 0, 200))}"
        )

        {:error, :nif_timeout}
    end
  end

  # Resolve the NIF timeout at call time so tests can tune it without a
  # recompile. Falls back to the module default when unset.
  defp nif_timeout_ms do
    Application.get_env(:cqr_mcp, :grafeo_nif_timeout_ms, @default_nif_timeout_ms)
  end
end
