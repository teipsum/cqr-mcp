defmodule Cqr.EmbeddingTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Smoke test for the bge-small-en-v1.5 serving wired up in `Cqr.Embedding`.

  Tagged `:slow` because the first run downloads ~130MB of model weights and
  JIT-compiles the EXLA graph (10-30s on Apple Silicon Metal, longer on
  pure CPU). Excluded from the default `mix test`; run with
  `mix test --include slow` to validate end-to-end.
  """

  @moduletag :slow

  setup_all do
    case Process.whereis(Cqr.Embedding.Serving) do
      nil -> start_supervised!(Cqr.Embedding)
      _pid -> :ok
    end

    :ok
  end

  test "embed/1 returns a 384-dim list of floats" do
    vec = Cqr.Embedding.embed("quarterly revenue forecast")

    assert is_list(vec)
    assert length(vec) == Cqr.Embedding.embedding_dims()
    assert Enum.all?(vec, &is_float/1)
  end

  test "output is L2-normalized to unit length" do
    vec = Cqr.Embedding.embed("the cat sat on the mat")
    norm = :math.sqrt(Enum.reduce(vec, 0.0, fn x, acc -> acc + x * x end))

    assert_in_delta norm, 1.0, 1.0e-3
  end

  test "paraphrases score higher than unrelated text" do
    forecast = Cqr.Embedding.embed("quarterly revenue forecast")
    projection = Cqr.Embedding.embed("Q4 sales projection")
    cat = Cqr.Embedding.embed("the cat sat on the mat")

    paraphrase_sim = cosine(forecast, projection)
    forecast_vs_cat = cosine(forecast, cat)
    projection_vs_cat = cosine(projection, cat)

    assert paraphrase_sim > 0.6,
           "paraphrase similarity #{paraphrase_sim} should exceed 0.6"

    assert forecast_vs_cat < 0.55,
           "unrelated similarity #{forecast_vs_cat} should be below 0.55"

    assert projection_vs_cat < 0.55,
           "unrelated similarity #{projection_vs_cat} should be below 0.55"
  end

  defp cosine(a, b) do
    Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)
  end
end
