defmodule Cqr.Repo.Snapshot do
  @moduledoc """
  JSON safety net for the embedded Grafeo database.

  Grafeo 0.5.40/0.5.41 corrupt the on-disk `.grafeo` file on graceful
  shutdown (snapshot_length=0 written against a stale checksum, observed
  twice in 24h). This GenServer is the parallel-track recovery path:
  every `snapshot_interval_ms` (default 5 min) and once on graceful
  shutdown via `terminate/2`, it dumps the live graph to NDJSON in a
  format that the 0.5.40 `grafeo data load` CLI accepts. After a
  corruption event the operator runs `~/bin/cqr-recover`, which moves
  the corrupt file aside and rebuilds from the most recent snapshot.

  ## File layout under `snapshot_dir`

      grafeo.snapshot.json              # canonical (latest) — what cqr-recover reads
      grafeo.snapshot.<unix_ts>.json    # rotated archives, last 3 kept

  ## Atomic write

  Every snapshot writes to `<final>.tmp.<rand>`, fsyncs the fd, closes,
  then `rename`s. A crash mid-write never leaves a half-written file
  visible at a stable name. The canonical pointer is updated by hardlinking
  the just-written timestamped archive to a tmp name and renaming over the
  canonical — also atomic.

  ## Cypher dump strategy: Path A

  Empirically verified against Grafeo 0.5.40 (probe in commit log):

    * `MATCH (n) RETURN n` returns full node objects shaped as
      `%{"_id" => int, "_labels" => [string], <prop> => <value>, ...}`.
    * Edges require aliased multi-projection — bare `id(s), id(t)` returns
      nil — but with `AS` the projection is reliable:
      `MATCH (s)-[r]->(t) RETURN id(s) AS sid, id(t) AS tid, id(r) AS rid,
       type(r) AS et, properties(r) AS p`.

  Property values come back as native Elixir types, which `encode_value/1`
  wraps in the typed-value envelope (`{"String": ...}`, `{"Int64": ...}`,
  `{"Float64": ...}`, `{"Bool": ...}`, `{"List": [...]}`) that the CLI's
  loader expects. b64-encoded descriptions round-trip verbatim — the dump
  must NOT decode them.

  ## Concurrency

  The dump funnels through `Cqr.Grafeo.Server.query/2`, the same serialised
  path every other reader uses. There is no second handle, no shared NIF
  state, and no risk of the Snapshot process and Grafeo.Server racing on
  the DB. `terminate/2` runs in the Snapshot process and calls into a
  *different* GenServer, so it cannot deadlock against itself; the
  supervision tree shuts Snapshot down before Grafeo.Server, so the
  destination is still alive when terminate fires.
  """

  use GenServer

  alias Cqr.Grafeo.Server, as: Grafeo

  require Logger

  @default_interval_ms 300_000
  @snapshot_filename "grafeo.snapshot.json"
  @rotation_keep 3
  @terminate_query_timeout 30_000
  @match_nodes "MATCH (n) RETURN n"
  @match_edges "MATCH (s)-[r]->(t) RETURN id(s) AS sid, id(t) AS tid, id(r) AS rid, type(r) AS et, properties(r) AS p"

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Force a snapshot now. Synchronous; blocks until the file is fsynced
  and the canonical hardlink is updated. Used by `terminate/2` and tests.
  """
  def snapshot_now(name \\ __MODULE__, timeout \\ @terminate_query_timeout) do
    GenServer.call(name, :snapshot_now, timeout)
  end

  @doc "Path of the canonical (latest) snapshot."
  def latest_snapshot_path(name \\ __MODULE__) do
    GenServer.call(name, :latest_snapshot_path)
  end

  @doc """
  Dump the current graph as an iolist of NDJSON via the Grafeo server.
  Each line is a JSON object — `{"type":"node",...}` or `{"type":"edge",...}`.
  """
  def dump_to_iolist(grafeo_server \\ Grafeo) do
    with {:ok, nodes} <- Grafeo.query(@match_nodes, grafeo_server),
         {:ok, edges} <- Grafeo.query(@match_edges, grafeo_server) do
      {:ok, build_iolist(nodes, edges)}
    end
  end

  @doc """
  Dump the current graph as an iolist of NDJSON using a NIF db handle
  directly. Bypasses the Grafeo server for harnesses that hold their own
  in-memory handle (probe scripts, the roundtrip test, the manual
  live-DB verification step).
  """
  def dump_to_iolist_from(db) do
    with {:ok, nodes} <- Cqr.Grafeo.Native.execute(db, @match_nodes),
         {:ok, edges} <- Cqr.Grafeo.Native.execute(db, @match_edges) do
      {:ok, build_iolist(nodes, edges)}
    end
  end

  @doc """
  Write a snapshot to `path` atomically. Used by tests and the live-DB
  manual verification step. The canonical-snapshot rotation logic only
  runs through the GenServer path.
  """
  def dump_to_file(path, grafeo_server \\ Grafeo) do
    with {:ok, iolist} <- dump_to_iolist(grafeo_server) do
      atomic_write(path, iolist)
    end
  end

  @doc false
  # Exposed for unit-testing the corruption detector without spinning up
  # the full server. See `Cqr.Grafeo.Server.classify_open_result/2`.
  def grafeo_corrupt_error?(reason) when is_binary(reason) do
    String.contains?(reason, "GRAFEO-X001") or
      String.contains?(reason, "snapshot checksum mismatch")
  end

  def grafeo_corrupt_error?(_), do: false

  # --- Callbacks ---

  @impl true
  def init(opts) do
    snapshot_dir = Keyword.get(opts, :snapshot_dir, default_snapshot_dir())
    interval_ms = Keyword.get(opts, :interval_ms, default_interval_ms())
    enabled? = Keyword.get(opts, :enabled, snapshot_enabled?())

    File.mkdir_p!(snapshot_dir)

    state = %{
      snapshot_dir: snapshot_dir,
      interval_ms: interval_ms,
      enabled: enabled?,
      last_snapshot_at: nil,
      grafeo_server: Keyword.get(opts, :grafeo_server, Grafeo)
    }

    if enabled? do
      Process.send_after(self(), :periodic_snapshot, interval_ms)
      Logger.info("Cqr.Repo.Snapshot started — #{snapshot_dir}, interval=#{interval_ms}ms")
    else
      Logger.info("Cqr.Repo.Snapshot started disabled (snapshot_in_test=false)")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot_now, _from, state) do
    {result, state} = do_snapshot(state)
    {:reply, result, state}
  end

  def handle_call(:latest_snapshot_path, _from, state) do
    {:reply, Path.join(state.snapshot_dir, @snapshot_filename), state}
  end

  @impl true
  def handle_info(:periodic_snapshot, %{enabled: true} = state) do
    {_result, state} = do_snapshot(state)
    Process.send_after(self(), :periodic_snapshot, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:periodic_snapshot, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{enabled: false}), do: :ok

  def terminate(_reason, state) do
    # Best-effort final snapshot. A raise here would block the supervisor
    # shutdown for the parent's terminate timeout; instead, log and let the
    # last periodic snapshot stand as the recovery point.
    try do
      case do_snapshot(state) do
        {:ok, _state} ->
          :ok

        {{:error, reason}, _state} ->
          Logger.error("Cqr.Repo.Snapshot final snapshot failed: #{inspect(reason)}")
          :ok
      end
    catch
      kind, reason ->
        Logger.error(
          "Cqr.Repo.Snapshot final snapshot crashed: #{inspect(kind)} #{inspect(reason)}"
        )

        :ok
    end
  end

  # --- Snapshot pipeline ---

  defp do_snapshot(state) do
    ts = System.system_time(:second)

    with {:ok, iolist} <- dump_to_iolist(state.grafeo_server),
         :ok <- write_snapshot(state.snapshot_dir, iolist, ts),
         :ok <- prune_archives(state.snapshot_dir) do
      {:ok, %{state | last_snapshot_at: ts}}
    else
      {:error, _} = err -> {err, state}
      other -> {{:error, other}, state}
    end
  end

  defp write_snapshot(dir, iolist, ts) do
    archive_path = Path.join(dir, "grafeo.snapshot.#{ts}.json")
    canonical = Path.join(dir, @snapshot_filename)

    with :ok <- atomic_write(archive_path, iolist),
         :ok <- atomic_link_canonical(canonical, archive_path) do
      :ok
    end
  end

  defp atomic_write(path, iolist) do
    tmp = path <> ".tmp." <> random_suffix()

    case :file.open(String.to_charlist(tmp), [:write, :raw, :binary]) do
      {:ok, fd} ->
        result =
          try do
            with :ok <- :file.write(fd, iolist),
                 :ok <- :file.sync(fd) do
              :ok
            end
          after
            :file.close(fd)
          end

        case result do
          :ok ->
            case File.rename(tmp, path) do
              :ok ->
                :ok

              err ->
                _ = File.rm(tmp)
                err
            end

          err ->
            _ = File.rm(tmp)
            err
        end

      err ->
        err
    end
  end

  # Replace the canonical snapshot pointer atomically by hardlinking the
  # archive to a fresh tmp name and renaming it over the canonical. POSIX
  # rename across a hardlink is atomic; an interrupted swap leaves either
  # the old canonical or the new one, never neither.
  defp atomic_link_canonical(canonical, archive) do
    tmp = canonical <> ".tmp." <> random_suffix()
    archive_cl = String.to_charlist(archive)
    tmp_cl = String.to_charlist(tmp)

    case :file.make_link(archive_cl, tmp_cl) do
      :ok ->
        case File.rename(tmp, canonical) do
          :ok ->
            :ok

          err ->
            _ = File.rm(tmp)
            err
        end

      {:error, :eexist} ->
        _ = File.rm(tmp)
        atomic_link_canonical(canonical, archive)

      err ->
        err
    end
  end

  defp prune_archives(dir) do
    pattern = Path.join(dir, "grafeo.snapshot.*.json")

    archived =
      pattern
      |> Path.wildcard()
      |> Enum.filter(&Regex.match?(~r/grafeo\.snapshot\.\d+\.json$/, &1))
      |> Enum.sort()

    archived
    |> Enum.drop(-@rotation_keep)
    |> Enum.each(&File.rm/1)

    :ok
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end

  # --- NDJSON encoding ---

  defp build_iolist(node_rows, edge_rows) do
    nodes_io = Enum.map(node_rows, &encode_node_line/1)
    edges_io = Enum.map(edge_rows, &encode_edge_line/1)
    [nodes_io, edges_io]
  end

  defp encode_node_line(%{"n" => node}) do
    {id, labels, props} = split_node(node)

    line = %{
      "type" => "node",
      "id" => id,
      "labels" => labels,
      "properties" => encode_props(props)
    }

    [Jason.encode_to_iodata!(line), ?\n]
  end

  defp split_node(node) when is_map(node) do
    id = Map.fetch!(node, "_id")
    labels = Map.fetch!(node, "_labels")
    props = Map.drop(node, ["_id", "_labels"])
    {id, labels, props}
  end

  defp encode_edge_line(%{"sid" => sid, "tid" => tid, "rid" => rid, "et" => et, "p" => p}) do
    line = %{
      "type" => "edge",
      "id" => rid,
      "source" => sid,
      "target" => tid,
      "edge_type" => et,
      "properties" => encode_props(p || %{})
    }

    [Jason.encode_to_iodata!(line), ?\n]
  end

  defp encode_props(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, encode_value(v)} end)
  end

  # Boolean clauses come first — `is_integer(true)` is false but
  # explicit clauses are easier to audit. Order otherwise irrelevant.
  defp encode_value(true), do: %{"Bool" => true}
  defp encode_value(false), do: %{"Bool" => false}
  defp encode_value(v) when is_integer(v), do: %{"Int64" => v}
  defp encode_value(v) when is_float(v), do: %{"Float64" => v}
  defp encode_value(v) when is_binary(v), do: %{"String" => v}
  defp encode_value(v) when is_list(v), do: %{"List" => Enum.map(v, &encode_value/1)}
  defp encode_value(nil), do: nil

  # --- Config helpers ---

  defp default_snapshot_dir do
    Application.get_env(:cqr_mcp, :snapshot_dir, Path.expand("~/.cqr"))
  end

  defp default_interval_ms do
    Application.get_env(:cqr_mcp, :snapshot_interval_ms, @default_interval_ms)
  end

  defp snapshot_enabled? do
    if Application.get_env(:cqr_mcp, :snapshot_in_test) == false do
      false
    else
      Application.get_env(:cqr_mcp, :snapshot_enabled, true)
    end
  end
end
