# Relevance benchmark: cqr_discover free-text search with vs without `near`.
#
# This is NOT a latency benchmark. The BFS that powers `near` is bounded at
# depth 4, so latency is a free win; the open question is whether biasing
# free-text results toward graph-adjacent entities makes the top-N list more
# useful.
#
# Methodological caveat: ground truth here is hand-labeled. There is no
# algorithm that produces "the five entities that should be at the top of
# this query" for free; a human (or another agent) reads the live graph and
# asserts a defensible-but-biased reference. The labels below were sourced
# from a reading of the actual graph state at chunk-C bench time. The bench's
# job is to compare with-near vs without-near against THE SAME labels and
# report whether `near` moves results in the labeled direction. If you
# disagree with a label, replace it; the methodology survives.
#
# Run:
#
#     CQR_BENCH_ENDPOINT=http://localhost:4001/message \
#       mix run --no-start bench/discover_hybrid_near_bench.exs
#
# `--no-start` keeps this script from booting its own application (which
# would contend for the daemon's Grafeo file lock). It only needs `:inets`
# for `:httpc`.
#
# If a ground-truth entity does not exist in the live graph at bench time the
# script prints a warning and excludes it from the denominator -- the bench
# never fails on a missing label, only on transport failure.

endpoint =
  System.get_env("CQR_BENCH_ENDPOINT", "http://localhost:4001/message")
  |> String.to_charlist()

{:ok, _} = Application.ensure_all_started(:inets)

defmodule Bench do
  def jsonrpc(endpoint, id, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      })

    request = {endpoint, [], ~c"application/json", body}

    case :httpc.request(:post, request, [], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, resp}} -> {:ok, resp}
      other -> {:error, other}
    end
  end

  def discover(endpoint, id, topic, near, max_results) do
    args = %{"topic" => topic, "max_results" => max_results}
    args = if near, do: Map.put(args, "near", near), else: args

    jsonrpc(endpoint, id, "tools/call", %{
      "name" => "cqr_discover",
      "arguments" => args
    })
  end

  def addresses_from_response(body) do
    case Jason.decode!(body) do
      %{"result" => %{"content" => [%{"text" => text} | _]}} ->
        case Jason.decode(text) do
          {:ok, %{"data" => rows}} when is_list(rows) -> {:ok, extract_addresses(rows)}
          {:ok, decoded} -> {:error, {:unexpected_payload, decoded}}
          {:error, _} -> {:error, {:non_json_text, text}}
        end

      %{"result" => %{"data" => rows}} when is_list(rows) ->
        {:ok, extract_addresses(rows)}

      %{"error" => err} ->
        {:error, {:rpc_error, err}}

      other ->
        {:error, {:unexpected_envelope, other}}
    end
  end

  defp extract_addresses(rows) do
    Enum.flat_map(rows, fn row ->
      case row do
        %{"namespace" => ns, "name" => name} -> ["entity:#{ns}:#{name}"]
        %{"entity" => addr} when is_binary(addr) -> [addr]
        _ -> []
      end
    end)
  end

  def precision_at_k(results, truth, k) do
    truth_set = MapSet.new(truth)
    top_k = Enum.take(results, k)
    hits = Enum.count(top_k, &MapSet.member?(truth_set, &1))
    {hits / k, hits, length(top_k)}
  end

  # Mean reciprocal rank over the full result list. Captures rank shifts that
  # p@5 misses (an entity moving from rank 4 to rank 3 changes MRR but not
  # p@5). Returns 0.0 if no ground-truth entity appears anywhere.
  def mrr(results, truth) do
    truth_set = MapSet.new(truth)

    ranks =
      results
      |> Enum.with_index(1)
      |> Enum.filter(fn {addr, _} -> MapSet.member?(truth_set, addr) end)
      |> Enum.map(fn {_, rank} -> 1.0 / rank end)

    case ranks do
      [] -> 0.0
      vs -> Enum.sum(vs) / length(vs)
    end
  end

  def ranks_of_truth(results, truth) do
    truth_set = MapSet.new(truth)

    results
    |> Enum.with_index(1)
    |> Enum.filter(fn {addr, _} -> MapSet.member?(truth_set, addr) end)
    |> Enum.map(fn {addr, rank} -> {rank, addr} end)
  end

  def existence_check(endpoint, truth, id_base) do
    Enum.with_index(truth, id_base)
    |> Enum.flat_map(fn {addr, id} ->
      case jsonrpc(endpoint, id, "tools/call", %{
             "name" => "cqr_resolve",
             "arguments" => %{"entity" => addr}
           }) do
        {:ok, body} ->
          case Jason.decode!(body) do
            %{"result" => _} -> [addr]
            %{"error" => _} -> []
          end

        {:error, _} ->
          []
      end
    end)
  end

  def fmt(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 2)
  def fmt(other), do: to_string(other)

  def mark(addr, truth) do
    if addr in truth, do: "[+]", else: "[ ]"
  end

  def hit_summary(hits, k) do
    "#{hits}/#{k} ground-truth in top #{k}"
  end

  def format_ranks([]), do: "(none in top 25)"

  def format_ranks(ranks) do
    ranks
    |> Enum.map(fn {rank, addr} -> "##{rank} #{addr}" end)
    |> Enum.join(", ")
  end
end

queries = [
  %{
    name: "primitive_improvements",
    topic: "primitive improvements",
    near: "entity:engineering:proposals:resolve_batch",
    truth: [
      "entity:engineering:state:resolve_batch_landed_apr29",
      "entity:engineering:proposals:grafeo_resolve_batch_index_in",
      "entity:engineering:state:discover_hybrid_near_chunk_a_landed_apr29",
      "entity:engineering:state:discover_hybrid_near_chunk_b_landed_apr29",
      "entity:engineering:proposals:primitive_improvements_umbrella"
    ]
  },
  %{
    name: "patent_strategy",
    topic: "patent strategy",
    near: "entity:patent:workflow:patent_3_drafting_state_april22",
    truth: [
      "entity:patent:decision:patent_3_focused_scope_april21",
      "entity:patent:decision:patent_3_scope_final_april21",
      "entity:patent:intake:c:patent_3_draft_narrowing_review",
      "entity:patent:strategy:multi_provisional_filing_plan_april21",
      "entity:engineering:intake:architecture:librarian_bypass_governance_clarification"
    ]
  },
  %{
    name: "agent_feedback",
    topic: "agent feedback",
    near: "entity:engineering:intake:feedback:cqr_self_evaluation",
    truth: [
      "entity:engineering:intake:feedback:cqr_self_evaluation_response_apr29",
      "entity:strategy:intake:feedback:pr_cqr_self_evaluation_response_0423",
      "entity:strategy:cqr_self_evaluation_consolidation_april23",
      "entity:patent:intake:c:cqr_self_evaluation",
      "entity:adapter:intake:feedback:cqr_self_evaluation"
    ]
  }
]

# Connectivity sanity check.
case Bench.jsonrpc(endpoint, 1, "tools/list", %{}) do
  {:ok, body} ->
    case Jason.decode!(body) do
      %{"result" => _} ->
        :ok

      %{"error" => err} ->
        IO.puts("FATAL: daemon returned error for tools/list")
        IO.inspect(err)
        System.halt(1)
    end

  {:error, reason} ->
    IO.puts("FATAL: cannot reach daemon at #{endpoint}")
    IO.inspect(reason)
    System.halt(1)
end

IO.puts("")
IO.puts("cqr_discover near vs without-near relevance bench (HTTP transport via #{endpoint})")
IO.puts(String.duplicate("=", 78))
IO.puts("")

IO.puts(
  "Methodology: precision-at-5 against hand-labeled ground truth. The labels are\n" <>
    "defensible but biased -- written by the same agent that designed the formula.\n" <>
    "The bench measures how far `near` moves results toward those labels, not\n" <>
    "whether the labels are absolutely correct.\n"
)

results =
  Enum.with_index(queries, 1)
  |> Enum.map(fn {q, qi} ->
    base = qi * 1000

    present_truth = Bench.existence_check(endpoint, q.truth, base + 100)
    missing = q.truth -- present_truth

    if missing != [] do
      IO.puts("WARN [#{q.name}] ground-truth entities missing from live graph (excluded):")
      Enum.each(missing, fn m -> IO.puts("        - #{m}") end)
    end

    {:ok, with_body} = Bench.discover(endpoint, base + 1, q.topic, q.near, 25)
    {:ok, without_body} = Bench.discover(endpoint, base + 2, q.topic, nil, 25)

    {:ok, with_addrs} = Bench.addresses_from_response(with_body)
    {:ok, without_addrs} = Bench.addresses_from_response(without_body)

    {with_p5, with_hits, with_k} = Bench.precision_at_k(with_addrs, present_truth, 5)
    {without_p5, without_hits, without_k} = Bench.precision_at_k(without_addrs, present_truth, 5)

    with_mrr = Bench.mrr(with_addrs, present_truth)
    without_mrr = Bench.mrr(without_addrs, present_truth)

    with_ranks = Bench.ranks_of_truth(with_addrs, present_truth)
    without_ranks = Bench.ranks_of_truth(without_addrs, present_truth)

    IO.puts("Query: #{q.name}")
    IO.puts("  topic=#{inspect(q.topic)}  near=#{q.near}")

    IO.puts(
      "  ground-truth entities present in graph: #{length(present_truth)}/#{length(q.truth)}"
    )

    IO.puts(
      "  Without near: #{Bench.hit_summary(without_hits, without_k)} -> p@5 = #{Bench.fmt(without_p5)}, MRR(top25) = #{Bench.fmt(without_mrr)}"
    )

    IO.puts(
      "  With near:    #{Bench.hit_summary(with_hits, with_k)} -> p@5 = #{Bench.fmt(with_p5)}, MRR(top25) = #{Bench.fmt(with_mrr)}"
    )

    IO.puts(
      "  Improvement:  p@5 absolute=#{Bench.fmt(with_p5 - without_p5)}  MRR absolute=#{Bench.fmt(with_mrr - without_mrr)}"
    )

    IO.puts("  Ground-truth ranks (in top 25):")
    IO.puts("    without near: #{Bench.format_ranks(without_ranks)}")
    IO.puts("    with near:    #{Bench.format_ranks(with_ranks)}")

    IO.puts("  Top 5 with near:")

    Enum.take(with_addrs, 5)
    |> Enum.each(fn a -> IO.puts("    #{Bench.mark(a, present_truth)} #{a}") end)

    IO.puts("  Top 5 without near:")

    Enum.take(without_addrs, 5)
    |> Enum.each(fn a -> IO.puts("    #{Bench.mark(a, present_truth)} #{a}") end)

    IO.puts("  Ground truth (present subset):")
    Enum.each(present_truth, fn a -> IO.puts("    - #{a}") end)
    IO.puts("")

    %{
      name: q.name,
      with_p5: with_p5,
      without_p5: without_p5,
      with_mrr: with_mrr,
      without_mrr: without_mrr
    }
  end)

p5_improvements = Enum.map(results, fn r -> r.with_p5 - r.without_p5 end)
mrr_improvements = Enum.map(results, fn r -> r.with_mrr - r.without_mrr end)

p5_positive = Enum.count(p5_improvements, &(&1 > 0))
p5_non_negative = Enum.count(p5_improvements, &(&1 >= 0))
mrr_positive = Enum.count(mrr_improvements, &(&1 > 0))
mrr_non_negative = Enum.count(mrr_improvements, &(&1 >= 0))
high_p5 = Enum.count(results, fn r -> r.with_p5 >= 0.6 end)

# Verdict combines two signals:
#   p@5 — does near put ground-truth into the top 5? (the user-facing metric)
#   MRR(top 25) — does near move ground-truth UP within the candidate pool,
#     even if not into the top 5? Captures the rank-shift signal that p@5
#     alone cannot see (an entity moving from rank 4 to rank 3 changes MRR
#     but not p@5).
#
# Either signal positive on majority is "directional"; both flat is "flat";
# either signal regressing on majority is "negative".

verdict =
  cond do
    high_p5 >= 2 and p5_positive >= 2 ->
      "VALIDATED: p@5 with near >= 0.6 on #{high_p5}/3 queries; p@5 positive on #{p5_positive}/3."

    p5_positive >= 2 or mrr_positive >= 2 ->
      "DIRECTIONAL: p@5 positive on #{p5_positive}/3, MRR positive on #{mrr_positive}/3.\n" <>
        "  Near is moving results toward ground truth but the candidate pool\n" <>
        "  and/or weights are too narrow to lift entities into the top 5 on\n" <>
        "  every query. Recommend follow-up tuning task."

    p5_non_negative >= 2 and mrr_non_negative >= 2 ->
      "FLAT: neither p@5 nor MRR improves on majority of queries; no regression.\n" <>
        "  Either the ground-truth labels are unreachable from these topics\n" <>
        "  (text/vector match for them is too weak to bring them into the\n" <>
        "  candidate pool), or near's weight is too small to be visible.\n" <>
        "  Review labels and formula before shipping."

    true ->
      regressing = max(3 - p5_non_negative, 3 - mrr_non_negative)

      "NEGATIVE: near regresses on #{regressing}/3 queries.\n" <>
        "  DO NOT MERGE chunk C as-is. Pause for review of labels and formula."
  end

IO.puts(String.duplicate("-", 78))
IO.puts("Verdict: #{verdict}")
IO.puts("")

System.halt(0)
