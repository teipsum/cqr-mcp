defmodule Cqr.Repo.Backfill do
  @moduledoc """
  Re-embed every entity in Grafeo with `Cqr.Embedding.embed/1`.

  Chunk B replaces the live ASSERT and DISCOVER paths with real semantic
  embeddings via bge-small-en-v1.5. Entities asserted before that switch
  still have hash-based pseudo-embeddings on disk, so free-text DISCOVER
  scores them against a different vector space than freshly-asserted ones.

  This module exists to be called once, manually, via remote shell after
  Chunk B merges:

      iex --sname remote --remsh cqr@$(hostname -s)
      iex> Cqr.Repo.Backfill.count()
      %{total: 1331, with_v2: 0}
      iex> Cqr.Repo.Backfill.run()
      {:ok, %{processed: 1331, errors: []}}

  It is intentionally NOT in the supervision tree, NOT auto-invoked from
  any test, and NOT called from any production code path.
  """

  alias Cqr.Grafeo.Codec
  alias Cqr.Grafeo.Server, as: GrafeoServer
  alias Cqr.Repo.Seed

  require Logger

  @progress_every 100

  @doc """
  Recompute and write a real embedding for every Entity in the graph.

  Streams the entity list, calls `Cqr.Embedding.embed/1` per row, and
  issues a `MATCH ... SET e.embedding = [...]` update. Errors are
  collected per-entity rather than aborting the whole run; the caller
  gets a summary.

  Returns `{:ok, %{processed: integer, errors: [{ns, name, reason}, ...]}}`
  or `{:error, reason}` if the initial fetch fails.
  """
  def run do
    case fetch_all_entities() do
      {:ok, rows} ->
        Logger.info("Backfill: re-embedding #{length(rows)} entities")
        {processed, errors} = backfill_rows(rows)
        Logger.info("Backfill: done — processed=#{processed} errors=#{length(errors)}")
        {:ok, %{processed: processed, errors: errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Status snapshot of how many entities currently hold a real (bge-small)
  embedding versus a pseudo-embedding.

  Heuristic: pseudo-embeddings are non-negative everywhere (hashed counts
  then L2-normalized), so any vector with at least one negative component
  is a real embedding. Empty or missing vectors count as `with_v2: 0`.

  Returns `%{total: integer, with_v2: integer}`.
  """
  def count do
    case fetch_all_embeddings() do
      {:ok, rows} ->
        vecs = Enum.map(rows, & &1["e.embedding"])
        with_v2 = Enum.count(vecs, &has_negative_component?/1)
        %{total: length(vecs), with_v2: with_v2}

      {:error, reason} ->
        Logger.error("Backfill.count failed: #{inspect(reason)}")
        %{total: 0, with_v2: 0}
    end
  end

  defp fetch_all_entities do
    query =
      "MATCH (e:Entity) " <>
        "RETURN e.namespace, e.name, e.description"

    GrafeoServer.query(query)
  end

  defp fetch_all_embeddings do
    GrafeoServer.query("MATCH (e:Entity) RETURN e.embedding")
  end

  defp backfill_rows(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce({0, []}, fn {row, idx}, {ok_count, errs} ->
      ns = row["e.namespace"]
      name = row["e.name"]
      desc = row["e.description"] |> Codec.decode() |> to_string()

      case write_embedding(ns, name, desc) do
        :ok ->
          if rem(idx, @progress_every) == 0 do
            Logger.info("Backfill: #{idx} entities processed")
          end

          {ok_count + 1, errs}

        {:error, reason} ->
          {ok_count, [{ns, name, reason} | errs]}
      end
    end)
    |> then(fn {ok_count, errs} -> {ok_count, Enum.reverse(errs)} end)
  end

  defp write_embedding(ns, name, description) do
    embedding_literal =
      "#{name} #{description}"
      |> Cqr.Embedding.embed()
      |> Seed.format_embedding()

    query =
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{escape(name)}'}) " <>
        "SET e.embedding = #{embedding_literal}"

    case GrafeoServer.query(query) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp has_negative_component?(vec) when is_list(vec),
    do: Enum.any?(vec, fn x -> is_number(x) and x < 0 end)

  defp has_negative_component?(_), do: false

  defp escape(s) when is_binary(s), do: String.replace(s, "'", "\\'")
  defp escape(s), do: s
end
