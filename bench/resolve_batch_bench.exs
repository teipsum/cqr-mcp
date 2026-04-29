# Benchmark: cqr_resolve_batch vs sequential cqr_resolve, end-to-end
# through the MCP HTTP transport.
#
# An in-process bench that calls `CqrMcp.Tools.call/3` directly under-
# measures the batch path because it skips JSON-RPC encoding, the HTTP
# round trip, and the agent-boundary cost that cqr_resolve_batch was
# designed to collapse. This bench drives a running cqr daemon over its
# `/message` POST endpoint to measure what an MCP client actually pays.
#
# Run:
#
#     CQR_BENCH_ENDPOINT=http://localhost:4001/message \
#       mix run --no-start bench/resolve_batch_bench.exs
#
# `--no-start` keeps this script from booting its own application
# (which would contend for the daemon's Grafeo file lock). It only
# needs `:inets` for `:httpc`.
#
# The fixed address pool is the engineering:proposals namespace
# populated in the persistent DB the daemon serves. The 50-call run
# cycles through 10 addresses (5 cycles); repeats are intentional --
# the point is round-trip overhead, and Semantic.get_entity has no
# per-call cache that would mask the comparison.

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

  def resolve(endpoint, id, address) do
    jsonrpc(endpoint, id, "tools/call", %{
      "name" => "cqr_resolve",
      "arguments" => %{"entity" => address}
    })
  end

  def resolve_batch(endpoint, id, addresses) do
    jsonrpc(endpoint, id, "tools/call", %{
      "name" => "cqr_resolve_batch",
      "arguments" => %{"entities" => addresses}
    })
  end

  def time_ms(fun) do
    {us, _} = :timer.tc(fun)
    us / 1000.0
  end

  def median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    case rem(n, 2) do
      1 -> Enum.at(sorted, mid)
      0 -> (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0
    end
  end

  def sequential(endpoint, addrs) do
    Enum.reduce(addrs, 1000, fn addr, id ->
      {:ok, _} = resolve(endpoint, id, addr)
      id + 1
    end)
  end

  def batch(endpoint, addrs, id) do
    {:ok, _} = resolve_batch(endpoint, id, addrs)
  end
end

addresses = [
  "entity:engineering:proposals:primitive_improvements_umbrella",
  "entity:engineering:proposals:resolve_batch",
  "entity:engineering:proposals:assert_shacl",
  "entity:engineering:proposals:discover_hybrid_near",
  "entity:engineering:proposals:awareness_cdc",
  "entity:engineering:proposals:session_primitive",
  "entity:engineering:proposals:assert_block_stm",
  "entity:engineering:proposals:certify_shacl_rbac",
  "entity:engineering:proposals:subscribe_primitive",
  "entity:engineering:proposals:real_embeddings"
]

pool = Stream.cycle(addresses) |> Enum.take(50)

# Connectivity + data sanity check.
case Bench.resolve(endpoint, 1, hd(addresses)) do
  {:ok, body} ->
    case Jason.decode!(body) do
      %{"result" => _} ->
        :ok

      %{"error" => err} ->
        IO.puts("FATAL: daemon returned error for #{hd(addresses)}")
        IO.inspect(err)
        System.halt(1)
    end

  {:error, reason} ->
    IO.puts("FATAL: cannot reach daemon at #{endpoint}")
    IO.inspect(reason)
    System.halt(1)
end

Bench.sequential(endpoint, Enum.take(pool, 50))
Bench.batch(endpoint, Enum.take(pool, 50), 9000)

trials = 5

rows =
  for n <- [5, 10, 20, 50] do
    addrs = Enum.take(pool, n)

    seq_samples =
      for _ <- 1..trials, do: Bench.time_ms(fn -> Bench.sequential(endpoint, addrs) end)

    batch_samples =
      for i <- 1..trials,
          do: Bench.time_ms(fn -> Bench.batch(endpoint, addrs, 5000 + n + i) end)

    seq_med = Bench.median(seq_samples)
    batch_med = Bench.median(batch_samples)
    speedup = if batch_med > 0, do: seq_med / batch_med, else: 0.0
    {n, seq_med, batch_med, speedup}
  end

IO.puts("")
IO.puts("cqr_resolve_batch performance (HTTP transport via #{endpoint})")
IO.puts(String.duplicate("=", 64))
IO.puts("  N    seq (ms)   batch (ms)   speedup")

Enum.each(rows, fn {n, seq, batch, speedup} ->
  IO.puts(
    "  #{String.pad_leading(Integer.to_string(n), 2)}  " <>
      "#{:io_lib.format(~c"~8.2f", [seq]) |> IO.iodata_to_binary()}    " <>
      "#{:io_lib.format(~c"~8.2f", [batch]) |> IO.iodata_to_binary()}    " <>
      "#{:io_lib.format(~c"~5.2f", [speedup]) |> IO.iodata_to_binary()}x"
  )
end)

{_, _, _, n20_speedup} = Enum.find(rows, fn {n, _, _, _} -> n == 20 end)

IO.puts("")
IO.puts("Target at N=20: spec promised 5-8x; design conversation expected 3-5x.")

verdict =
  cond do
    n20_speedup >= 3.0 and n20_speedup <= 8.0 -> "Within expected range."
    n20_speedup > 8.0 -> "Above expected range -- better than predicted."
    n20_speedup >= 2.0 -> "Below expected range -- still a real win."
    true -> "WARN: speedup under 2x at N=20 -- investigate."
  end

IO.puts(
  "Observed at N=20: #{:io_lib.format(~c"~4.2f", [n20_speedup]) |> IO.iodata_to_binary()}x. #{verdict}"
)

if n20_speedup < 2.0 or n20_speedup > 10.0 do
  IO.puts("WARN: N=20 speedup outside the 2x-10x sanity band; result may be misleading.")
end

System.halt(0)
