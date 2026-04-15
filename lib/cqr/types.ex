defmodule Cqr.Types do
  @moduledoc """
  Core types for CQR: Entity, Scope, Duration, Score.

  These types provide validation and helper functions used throughout
  the parser, engine, and adapter layers.
  """

  # --- Entity ---

  @doc """
  Validates an entity tuple `{namespace, name}`.

  Namespace is a colon-joined path of one or more identifier segments
  (e.g. `"agent"` or `"twin:michael:health"`); name is a single identifier.
  Each segment must match `[a-z_][a-z0-9_]*`.
  """
  def valid_entity?({ns, name}) when is_binary(ns) and is_binary(name) do
    valid_namespace_path?(ns) and valid_identifier?(name)
  end

  def valid_entity?(_), do: false

  defp valid_namespace_path?(ns) do
    case String.split(ns, ":") do
      [] -> false
      segments -> Enum.all?(segments, &valid_identifier?/1)
    end
  end

  @doc "Formats an entity tuple as `entity:namespace:name`."
  def format_entity({ns, name}), do: "entity:#{ns}:#{name}"

  # --- Scope ---

  @doc """
  Validates a scope (list of segments).

  Each segment must be a non-empty string matching `[a-z_][a-z0-9_]*`.
  """
  def valid_scope?([_ | _] = segments) do
    Enum.all?(segments, &valid_identifier?/1)
  end

  def valid_scope?(_), do: false

  @doc "Returns the parent scope (drops the last segment). Returns nil for root scopes."
  def parent([_single]), do: nil
  def parent(segments) when is_list(segments), do: Enum.slice(segments, 0..-2//1)

  @doc "Returns all ancestor scopes from immediate parent to root."
  def ancestors(segments) when is_list(segments) do
    segments
    |> Enum.scan([], fn seg, acc -> acc ++ [seg] end)
    |> Enum.slice(0..-2//1)
    |> Enum.reverse()
  end

  @doc "Returns true if `child` is a descendant of `parent_scope`."
  def child?(child, parent_scope) when is_list(child) and is_list(parent_scope) do
    length(child) > length(parent_scope) and
      List.starts_with?(child, parent_scope)
  end

  @doc "Formats a scope list as `scope:seg1:seg2:...`"
  def format_scope(segments), do: "scope:" <> Enum.join(segments, ":")

  # --- Duration ---

  @valid_units [:m, :h, :d, :w]

  @doc "Validates a duration tuple `{amount, unit}` where unit is :m, :h, :d, or :w."
  def valid_duration?({amount, unit})
      when is_integer(amount) and amount > 0 and unit in @valid_units,
      do: true

  def valid_duration?(_), do: false

  @doc "Converts a duration to minutes."
  def to_minutes({amount, :m}), do: amount
  def to_minutes({amount, :h}), do: amount * 60
  def to_minutes({amount, :d}), do: amount * 60 * 24
  def to_minutes({amount, :w}), do: amount * 60 * 24 * 7

  # --- Score ---

  @doc "Validates a score (float between 0.0 and 1.0 inclusive)."
  def valid_score?(score) when is_float(score), do: score >= 0.0 and score <= 1.0
  def valid_score?(_), do: false

  # --- Identifier ---

  @doc "Validates that a string matches the identifier pattern `[a-z_][a-z0-9_]*`."
  def valid_identifier?(str) when is_binary(str) do
    Regex.match?(~r/^[a-z_][a-z0-9_]*$/, str)
  end

  def valid_identifier?(_), do: false
end
