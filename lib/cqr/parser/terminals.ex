defmodule Cqr.Parser.Terminals do
  @moduledoc """
  Shared terminal combinators for the CQR grammar.

  These are the building blocks used by RESOLVE, DISCOVER, and CERTIFY parsers.
  """

  import NimbleParsec

  # --- Whitespace ---

  def sp do
    ascii_string([?\s, ?\t], min: 1)
    |> label("whitespace")
  end

  def optional_sp do
    ascii_string([?\s, ?\t], min: 0)
  end

  # --- Identifier: [a-z_][a-z0-9_]* ---

  def identifier do
    ascii_char([?a..?z, ?_])
    |> concat(ascii_string([?a..?z, ?0..?9, ?_], min: 0))
    |> reduce({__MODULE__, :join_chars, []})
    |> label("identifier (lowercase letters, digits, underscores)")
  end

  def join_chars([first | rest]) when is_integer(first) do
    <<first>> <> Enum.join(rest, "")
  end

  def join_chars([str]) when is_binary(str), do: str

  def join_chars(parts) do
    Enum.map_join(parts, "", fn
      i when is_integer(i) -> <<i>>
      s -> s
    end)
  end

  # --- Entity: entity:namespace:name ---

  def entity do
    string("entity:")
    |> ignore()
    |> concat(identifier())
    |> ignore(string(":"))
    |> concat(identifier())
    |> reduce({__MODULE__, :to_entity, []})
    |> label("entity reference (entity:namespace:name)")
  end

  def to_entity([ns, name]), do: {ns, name}

  # --- Scope: scope:seg1:seg2:... ---

  def scope do
    string("scope:")
    |> ignore()
    |> concat(identifier())
    |> repeat(ignore(string(":")) |> concat(identifier()))
    |> reduce({__MODULE__, :to_scope, []})
    |> label("scope reference (scope:seg1:seg2:...)")
  end

  def to_scope(segments), do: segments

  # --- Duration: integer + unit (m/h/d/w) ---

  def duration do
    integer(min: 1)
    |> concat(
      choice([
        string("m") |> replace(:m),
        string("h") |> replace(:h),
        string("d") |> replace(:d),
        string("w") |> replace(:w)
      ])
    )
    |> reduce({__MODULE__, :to_duration, []})
    |> label("duration (e.g. 24h, 7d, 30m)")
  end

  def to_duration([amount, unit]), do: {amount, unit}

  # --- Score: 0.0 - 1.0 ---

  def score do
    ascii_string([?0..?9], min: 1)
    |> string(".")
    |> ascii_string([?0..?9], min: 1)
    |> reduce({__MODULE__, :to_score, []})
    |> label("score (e.g. 0.7, 0.85)")
  end

  def to_score([integer_part, ".", decimal_part]) do
    String.to_float("#{integer_part}.#{decimal_part}")
  end

  # --- String literal: "..." ---

  def string_literal do
    ignore(string("\""))
    |> concat(ascii_string([{:not, ?"}], min: 0))
    |> ignore(string("\""))
    |> label("quoted string")
  end

  # --- Annotation list: freshness, confidence, reputation, owner, lineage ---

  def annotation do
    choice([
      string("freshness") |> replace(:freshness),
      string("confidence") |> replace(:confidence),
      string("reputation") |> replace(:reputation),
      string("owner") |> replace(:owner),
      string("lineage") |> replace(:lineage)
    ])
    |> label("annotation (freshness, confidence, reputation, owner, lineage)")
  end

  def annotation_list do
    annotation()
    |> repeat(
      ignore(optional_sp())
      |> ignore(string(","))
      |> ignore(optional_sp())
      |> concat(annotation())
    )
    |> reduce({__MODULE__, :to_list, []})
    |> label("annotation list")
  end

  def to_list(items), do: items

  # --- Arrow: -> or → ---

  def arrow do
    choice([
      string("->"),
      string("→")
    ])
    |> label("arrow (-> or →)")
  end
end
