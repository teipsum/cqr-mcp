defmodule Cqr.Embedding do
  @moduledoc """
  Semantic text embeddings backed by `BAAI/bge-small-en-v1.5`.

  The model is loaded once at application boot via `Bumblebee` and exposed
  as an `Nx.Serving` registered under `#{inspect(__MODULE__)}.Serving`.
  Callers use `embed/1` to map a string to a 384-dim unit vector. The
  serving handles request batching and concurrent execution; we do not
  wrap it in a `GenServer` (that would serialize calls and defeat the
  point of the serving).

  Output shape and normalization match the bge-small-en-v1.5 model card:
  CLS-token pooling on the raw hidden state followed by L2 normalization.
  Returned vectors are plain lists of floats so callers (and persistence
  paths) can treat them like the existing `Cqr.Repo.Seed.pseudo_embedding/1`
  output.
  """

  @serving __MODULE__.Serving
  @repo {:hf, "BAAI/bge-small-en-v1.5"}
  @embedding_dims 384

  @doc "Dimensionality of vectors returned by `embed/1`."
  @spec embedding_dims() :: 384
  def embedding_dims, do: @embedding_dims

  @doc """
  Embed `text` into a 384-dim L2-normalized vector.

  Blocks until the serving has produced a result. The serving batches
  concurrent calls automatically; callers do not need to batch manually.
  """
  @spec embed(String.t()) :: [float()]
  def embed(text) when is_binary(text) do
    %{embedding: tensor} = Nx.Serving.batched_run(@serving, text)
    Nx.to_flat_list(tensor)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc false
  def start_link(_opts) do
    {:ok, model_info} = Bumblebee.load_model(@repo)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(@repo)

    serving =
      Bumblebee.Text.text_embedding(model_info, tokenizer,
        output_attribute: :hidden_state,
        output_pool: :cls_token_pooling,
        embedding_processor: :l2_norm,
        compile: [batch_size: 1, sequence_length: 512],
        defn_options: [compiler: EXLA]
      )

    Nx.Serving.start_link(name: @serving, serving: serving)
  end
end
