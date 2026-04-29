defmodule Mix.Tasks.Cqr.ReplaySnapshot do
  @shortdoc "Replay a JSON snapshot into a running cqr graph"

  @moduledoc """
  Reconstruct a cqr graph from `grafeo.snapshot.json` (NDJSON) by issuing
  Cypher `INSERT` statements through `Cqr.Grafeo.Server.query/1`.

  ## When to use this

  After Chunk E patched grafeo-storage to boot past `GRAFEO-X001`, cqr
  starts cleanly but with an empty graph: `read_section_directory`
  silently returns `None` on the v2-format `grafeo.grafeo`, so the
  engine's section-load path is skipped. The on-disk file cannot be
  read back as data even by patched grafeo-storage.

  The canonical persistence is now `~/.cqr/grafeo.snapshot.json` (NDJSON
  produced by `Cqr.Repo.Snapshot`). This task reads that file and
  reconstructs the graph in a *running* cqr.

  ## Usage

      mix cqr.replay_snapshot                                  # default path, default node
      mix cqr.replay_snapshot --dry-run                        # parse + report, no writes
      mix cqr.replay_snapshot --path /alt/path/snap.json
      mix cqr.replay_snapshot --node cqr@somehost
      mix cqr.replay_snapshot --skip-edges                     # node-only restore (debugging)
      mix cqr.replay_snapshot --verbose                        # log every Nth query

  ## Wire-up

  `~/bin/cqr` boots cqr with `--sname cqr`, so the live node is
  `cqr@<short_hostname>`. This Mix task starts Erlang distribution and
  uses `:rpc.call/4` to issue queries on that node — opening the
  on-disk file in this BEAM would fail on the file lock the running
  cqr already holds.

  Dry-run does not connect to any node.

  ## Phase ordering

    1. Scope (6) — first because Phase 5 edges reference them.
    2. Entity (1331) — `IN_SCOPE`/`DERIVED_FROM`/etc. need them.
    3. Audit nodes — AssertionRecord, SignalRecord, CertificationRecord,
       VersionRecord. Edge phase references these by `record_id`.
    4. Other — abort if any node label outside the four above appears.
    5. Edges (8776) — every edge resolves source and target by business
       key in a `MATCH ... INSERT` form.

  ## Idempotency

  Refuses to run against a non-empty graph. There is no `--force`
  flag. If the live graph already has data, stop the task and decide
  manually how to merge — automatic union is out of scope.
  """

  use Mix.Task

  alias Cqr.Grafeo.Gql
  alias Cqr.Repo.Seed

  @default_path "~/.cqr/grafeo.snapshot.json"
  @audit_labels ~w(AssertionRecord SignalRecord CertificationRecord VersionRecord)
  @progress_every 250

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _invalid} =
      OptionParser.parse(argv,
        strict: [
          path: :string,
          dry_run: :boolean,
          batch: :integer,
          skip_edges: :boolean,
          verbose: :boolean,
          node: :string
        ]
      )

    path = Path.expand(opts[:path] || @default_path)

    case File.read(path) do
      {:ok, body} ->
        do_run(body, path, opts)

      {:error, reason} ->
        Mix.shell().error("Cannot read #{path}: #{:file.format_error(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp do_run(body, path, opts) do
    case parse_records(body) do
      {:ok, %{by_phase: by_phase, total: total} = parsed} ->
        Mix.shell().info(
          "Parsed #{total} records from #{path}: " <>
            "#{count(by_phase, :scope)} scopes, " <>
            "#{count(by_phase, :entity)} entities, " <>
            "#{audit_count(by_phase)} audit records, " <>
            "#{count(by_phase, :edges)} edges"
        )

        if opts[:dry_run] do
          dry_run(parsed)
        else
          live_run(parsed, opts)
        end

      {:error, {line_no, reason}} ->
        Mix.shell().error("Parse error at line #{line_no}: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # --- Phase parsing ---

  @doc false
  # Public for tests. Returns
  #   {:ok, %{by_phase: %{scope: [...], entity: [...], audit: [...], edges: [...]}, total: int}}
  # or {:error, {line_no, reason}}.
  def parse_records(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, empty_phase_acc()}, fn {line, line_no}, {:ok, acc} ->
      case classify_line(line) do
        {:ok, phase, record} ->
          {:cont, {:ok, push(acc, phase, record)}}

        {:error, reason} ->
          {:halt, {:error, {line_no, reason}}}
      end
    end)
    |> case do
      {:ok, acc} ->
        sanity_check(acc)

      {:error, _} = err ->
        err
    end
  end

  defp empty_phase_acc do
    %{by_phase: %{scope: [], entity: [], audit: [], edges: []}, total: 0, other_labels: []}
  end

  defp push(acc, :other, record) do
    label = record |> Map.get("labels", []) |> List.first() || "?"
    %{acc | other_labels: [label | acc.other_labels], total: acc.total + 1}
  end

  defp push(acc, phase, record) do
    %{
      acc
      | by_phase: Map.update!(acc.by_phase, phase, &[record | &1]),
        total: acc.total + 1
    }
  end

  defp classify_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "node", "labels" => labels} = rec} ->
        {:ok, node_phase(labels), rec}

      {:ok, %{"type" => "edge"} = rec} ->
        {:ok, :edges, rec}

      {:ok, other} ->
        {:error, {:unknown_record_shape, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp node_phase(labels) do
    cond do
      "Scope" in labels -> :scope
      "Entity" in labels -> :entity
      Enum.any?(@audit_labels, &(&1 in labels)) -> :audit
      true -> :other
    end
  end

  defp sanity_check(%{other_labels: []} = acc) do
    %{by_phase: by_phase, total: total} = acc
    by_phase = Map.new(by_phase, fn {k, v} -> {k, Enum.reverse(v)} end)
    {:ok, %{by_phase: by_phase, total: total}}
  end

  defp sanity_check(%{other_labels: extra}) do
    {:error, {:unsupported_node_labels, Enum.uniq(extra)}}
  end

  # --- Dry run ---

  defp dry_run(%{by_phase: by_phase}) do
    Mix.shell().info("--- DRY RUN: sample Cypher per phase ---")

    [:scope, :entity, :audit, :edges]
    |> Enum.each(fn phase ->
      records = Map.get(by_phase, phase, [])

      sample =
        case records do
          [first | _] ->
            id_map = build_id_map(by_phase)
            cypher_for(phase, first, id_map)

          [] ->
            "(no records in phase)"
        end

      Mix.shell().info("\n[#{phase}] sample:\n  #{truncate(sample, 240)}")
    end)

    Mix.shell().info("\nDry run complete. No queries executed.")
    :ok
  end

  defp truncate(s, max) do
    if byte_size(s) > max,
      do: binary_part(s, 0, max) <> "... (truncated)",
      else: s
  end

  # --- Live run ---

  defp live_run(parsed, opts) do
    executor = build_executor(opts)

    case replay(parsed, executor, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.shell().error("Replay aborted: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  @doc false
  # Public for tests. Drives the actual phased insertion + verification
  # against an arbitrary executor function `(cypher) -> {:ok, _} | {:error, _}`.
  # The Mix task's `live_run/2` builds an RPC-backed executor; tests pass a
  # closure that calls `Cqr.Grafeo.Server.query/2` against an in-memory
  # server they own.
  def replay(%{by_phase: by_phase, total: total}, executor, opts \\ []) do
    verbose? = !!Keyword.get(opts, :verbose)
    skip_edges? = !!Keyword.get(opts, :skip_edges)

    with :ok <- ensure_empty(executor),
         id_map = build_id_map(by_phase),
         :ok <- run_phase("scope", by_phase.scope, &node_cypher/2, id_map, executor, verbose?),
         :ok <- run_phase("entity", by_phase.entity, &node_cypher/2, id_map, executor, verbose?),
         :ok <- run_phase("audit", by_phase.audit, &node_cypher/2, id_map, executor, verbose?),
         :ok <- maybe_run_edges(skip_edges?, by_phase.edges, id_map, executor, verbose?),
         :ok <- verify(executor, total, by_phase, skip_edges?) do
      :ok
    end
  end

  defp maybe_run_edges(true, _edges, _id_map, _exec, _verbose?) do
    Mix.shell().info("--skip-edges set: not inserting edges")
    :ok
  end

  defp maybe_run_edges(false, edges, id_map, executor, verbose?) do
    run_phase("edges", edges, &edge_cypher/2, id_map, executor, verbose?)
  end

  defp run_phase(label, records, cypher_fn, id_map, executor, verbose?) do
    started = System.monotonic_time(:millisecond)
    total = length(records)
    Mix.shell().info("Phase #{label}: inserting #{total} records")

    records
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {record, idx}, _ ->
      cypher = cypher_fn.(record, id_map)

      case executor.(cypher) do
        {:ok, _} ->
          if verbose? and rem(idx, @progress_every) == 0,
            do: Mix.shell().info("  #{label}: #{idx}/#{total}")

          {:cont, :ok}

        {:error, reason} ->
          Mix.shell().error(
            "Phase #{label} failed at record #{idx}/#{total}: #{inspect(reason)}\n" <>
              "Cypher: #{truncate(cypher, 400)}"
          )

          {:halt, {:error, {label, idx, reason}}}
      end
    end)
    |> case do
      :ok ->
        elapsed = System.monotonic_time(:millisecond) - started
        Mix.shell().info("Phase #{label}: #{total} records in #{elapsed}ms")
        :ok

      err ->
        err
    end
  end

  # --- Verification ---

  defp verify(executor, _total, by_phase, skip_edges?) do
    expected_nodes =
      length(by_phase.scope) + length(by_phase.entity) + length(by_phase.audit)

    expected_edges = if skip_edges?, do: 0, else: length(by_phase.edges)

    with {:ok, node_count} <- count_query(executor, "MATCH (n) RETURN count(n)"),
         {:ok, edge_count} <- count_query(executor, "MATCH ()-[r]->() RETURN count(r)") do
      Mix.shell().info(
        "Verification: nodes=#{node_count}/#{expected_nodes}, " <>
          "edges=#{edge_count}/#{expected_edges}"
      )

      if node_count == expected_nodes and edge_count == expected_edges do
        Mix.shell().info(
          "Replay complete: #{node_count} nodes, #{edge_count} edges restored. Verification: PASS"
        )

        :ok
      else
        {:error,
         {:verification_mismatch,
          %{nodes: {node_count, expected_nodes}, edges: {edge_count, expected_edges}}}}
      end
    end
  end

  defp count_query(executor, q) do
    case executor.(q) do
      {:ok, [row | _]} when is_map(row) ->
        case Map.values(row) do
          [n | _] when is_integer(n) -> {:ok, n}
          other -> {:error, {:unexpected_count_row, other}}
        end

      {:ok, []} ->
        {:ok, 0}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_count_result, other}}
    end
  end

  # --- Empty-graph guard ---

  defp ensure_empty(executor) do
    case count_query(executor, "MATCH (n) RETURN count(n)") do
      {:ok, 0} ->
        :ok

      {:ok, n} ->
        {:error, {:graph_not_empty, n}}

      {:error, _} = err ->
        err
    end
  end

  # --- Cypher generators ---

  defp cypher_for(:scope, rec, id_map), do: node_cypher(rec, id_map)
  defp cypher_for(:entity, rec, id_map), do: node_cypher(rec, id_map)
  defp cypher_for(:audit, rec, id_map), do: node_cypher(rec, id_map)
  defp cypher_for(:edges, rec, id_map), do: edge_cypher(rec, id_map)

  @doc false
  # Public for tests.
  def node_cypher(%{"labels" => labels, "properties" => props}, _id_map) do
    label = primary_label(labels)
    "INSERT (:#{label} {#{render_props(props)}})"
  end

  @doc false
  # Public for tests.
  def edge_cypher(%{"source" => src, "target" => tgt, "edge_type" => et} = rec, id_map) do
    {s_label, s_key} = Map.fetch!(id_map, src)
    {t_label, t_key} = Map.fetch!(id_map, tgt)
    props = Map.get(rec, "properties", %{})

    rel_part =
      case render_props(props) do
        "" -> ":#{et}"
        rendered -> ":#{et} {#{rendered}}"
      end

    "MATCH (s:#{s_label} #{s_key}), (t:#{t_label} #{t_key}) " <>
      "INSERT (s)-[#{rel_part}]->(t)"
  end

  defp primary_label([first | _]), do: first
  defp primary_label([]), do: raise(ArgumentError, "node has no labels")

  # --- id_map: json_id -> {label, "{key:'value', ...}"} ---

  @doc false
  # Public for tests.
  def build_id_map(%{scope: scopes, entity: entities, audit: audit}) do
    Map.new(
      Enum.map(scopes, &id_map_entry/1) ++
        Enum.map(entities, &id_map_entry/1) ++
        Enum.map(audit, &id_map_entry/1)
    )
  end

  defp id_map_entry(%{"id" => id, "labels" => labels, "properties" => props}) do
    label = primary_label(labels)
    {id, {label, business_key(label, props)}}
  end

  defp business_key("Scope", %{"path" => %{"String" => path}}) do
    "{path: '#{Gql.escape(path)}'}"
  end

  defp business_key("Entity", %{
         "namespace" => %{"String" => ns},
         "name" => %{"String" => name}
       }) do
    "{namespace: '#{Gql.escape(ns)}', name: '#{Gql.escape(name)}'}"
  end

  defp business_key(label, %{"record_id" => %{"String" => rid}})
       when label in @audit_labels do
    "{record_id: '#{Gql.escape(rid)}'}"
  end

  defp business_key(label, props) do
    raise ArgumentError,
          "no business key for label #{label}; props: #{inspect(Map.keys(props))}"
  end

  # --- Property rendering ---

  defp render_props(props) when is_map(props) do
    props
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{serialize_value(v)}" end)
  end

  @doc false
  # Public for tests. Renders a typed-tag value (`{"String": ...}`,
  # `{"Int64": ...}`, `{"Float64": ...}`, `{"Bool": ...}`, `{"List": [...]}`)
  # as a Cypher literal.
  def serialize_value(%{"String" => s}) when is_binary(s),
    do: "'#{Gql.escape(s)}'"

  def serialize_value(%{"Int64" => n}) when is_integer(n), do: Integer.to_string(n)

  def serialize_value(%{"Float64" => f}) when is_float(f) do
    # Match Seed.format_embedding's precision so embeddings round-trip
    # byte-for-byte against freshly-seeded vectors.
    :erlang.float_to_binary(f, decimals: 6)
  end

  def serialize_value(%{"Bool" => true}), do: "true"
  def serialize_value(%{"Bool" => false}), do: "false"

  def serialize_value(%{"List" => items}) when is_list(items) do
    case all_floats?(items) do
      true ->
        items
        |> Enum.map(fn %{"Float64" => f} -> f end)
        |> Seed.format_embedding()

      false ->
        "[" <> Enum.map_join(items, ", ", &serialize_value/1) <> "]"
    end
  end

  def serialize_value(other),
    do: raise(ArgumentError, "unknown typed-value shape: #{inspect(other)}")

  defp all_floats?([]), do: false
  defp all_floats?(items), do: Enum.all?(items, &match?(%{"Float64" => f} when is_float(f), &1))

  # --- Counters / display helpers ---

  defp count(%{} = by_phase, key), do: length(Map.get(by_phase, key, []))

  defp audit_count(%{audit: a}), do: length(a)

  # --- Executor ---

  defp build_executor(opts) do
    node_name = opts[:node] || default_node_name()
    target = String.to_atom(node_name)

    ensure_distribution!()

    case Node.connect(target) do
      true ->
        Mix.shell().info("Connected to #{node_name}")
        rpc_executor(target)

      reason ->
        Mix.shell().error(
          "Cannot connect to #{node_name} (#{inspect(reason)}). " <>
            "Is `~/bin/cqr --persist` running with --sname cqr?"
        )

        exit({:shutdown, 1})
    end
  end

  defp rpc_executor(target) do
    fn cypher ->
      case :rpc.call(target, Cqr.Grafeo.Server, :query, [cypher], 60_000) do
        {:badrpc, reason} -> {:error, {:badrpc, reason}}
        other -> other
      end
    end
  end

  defp ensure_distribution! do
    case Node.alive?() do
      true ->
        :ok

      false ->
        # Use a unique short-name so concurrent invocations don't collide.
        suffix = :erlang.unique_integer([:positive])
        name = String.to_atom("cqr_replay_#{suffix}")

        case Node.start(name, :shortnames) do
          {:ok, _} -> :ok
          {:error, reason} -> raise "Could not start distribution: #{inspect(reason)}"
        end
    end
  end

  defp default_node_name do
    {:ok, host} = :inet.gethostname()
    "cqr@#{host}"
  end
end
