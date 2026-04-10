defmodule Cqr.Adapter.Grafeo do
  @moduledoc """
  Grafeo adapter — implements the adapter behaviour contract
  using the embedded Grafeo NIF.

  This is the primary adapter for V1. It handles RESOLVE and DISCOVER
  by constructing GQL queries against the embedded database.
  Scope constraints are part of the query, not a post-filter.
  """

  @behaviour Cqr.Adapter.Behaviour

  alias Cqr.Repo.Semantic

  @impl true
  def capabilities, do: [:resolve, :discover]

  @impl true
  def resolve(%Cqr.Resolve{entity: entity} = expression, scope_context, _opts) do
    visible = scope_context[:visible_scopes] || []

    case Semantic.get_entity(entity, visible) do
      {:ok, entity_data} ->
        result = normalize_entity(entity_data, expression)
        {:ok, result}

      {:error, :not_found} ->
        similar = Semantic.search_entities(elem(entity, 1), visible)

        {:error,
         Cqr.Error.entity_not_found(Cqr.Types.format_entity(entity), similar: similar)}

      {:error, :not_visible} ->
        {:error,
         Cqr.Error.entity_not_found(Cqr.Types.format_entity(entity),
           similar: Semantic.search_entities(elem(entity, 1), visible)
         )}

      {:error, reason} ->
        {:error, %Cqr.Error{code: :adapter_error, message: "Grafeo error: #{inspect(reason)}"}}
    end
  end

  @impl true
  def discover(%Cqr.Discover{related_to: related_to} = expression, scope_context, _opts) do
    visible = scope_context[:visible_scopes] || []
    depth = expression.depth || 2

    case related_to do
      {:entity, entity} ->
        case Semantic.related_entities(entity, depth, visible) do
          {:ok, related} ->
            result = normalize_discovery(related, entity, expression)
            {:ok, result}

          {:error, reason} ->
            {:error,
             %Cqr.Error{code: :adapter_error, message: "Grafeo error: #{inspect(reason)}"}}
        end

      {:search, _term} ->
        # Search-based discovery not yet implemented in V1
        {:ok, %Cqr.Result{data: [], sources: ["grafeo"]}}
    end
  end

  @impl true
  def normalize(raw_results, _metadata) do
    %Cqr.Result{
      data: raw_results,
      sources: ["grafeo"],
      quality: %Cqr.Quality{}
    }
  end

  @impl true
  def health_check do
    case Cqr.Grafeo.Server.health() do
      {:ok, version} -> {:ok, %{adapter: "grafeo", version: version, status: :healthy}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Private ---

  defp normalize_entity(entity_data, _expression) do
    quality = %Cqr.Quality{
      reputation: entity_data[:reputation],
      owner: entity_data[:owner],
      certified_by: if(entity_data[:certified], do: entity_data[:owner], else: nil)
    }

    %Cqr.Result{
      data: [entity_data],
      sources: ["grafeo"],
      quality: quality
    }
  end

  defp normalize_discovery(related, anchor_entity, _expression) do
    quality =
      case related do
        [] ->
          %Cqr.Quality{}

        [first | _] ->
          %Cqr.Quality{
            reputation: first[:reputation],
            owner: first[:owner]
          }
      end

    %Cqr.Result{
      data: related,
      sources: ["grafeo"],
      quality: quality,
      conflicts:
        related
        |> Enum.group_by(& &1.entity)
        |> Enum.filter(fn {_k, v} -> length(v) > 1 end)
        |> Enum.map(fn {entity, entries} ->
          %{entity: entity, conflicting_values: entries}
        end)
    }
  end
end
