defmodule Mix.Tasks.Cqr.GenInstallFixture do
  @moduledoc """
  Generates `lib/repo/install_seed.ex` from the markdown files in `priv/install/`.

  The seed module embeds the universal protocols (entity:agent:default,
  entity:governance:relationship_guide, entity:governance:assertion_protocol,
  entity:agent:default:coordination) and the installer entry point
  (entity:install) as Elixir data. Boot loads it via direct Cypher INSERTs
  in the same style as `Cqr.Repo.Seed`.

  ## Usage

      mix cqr.gen_install_fixture

  Reads every `*.md` in `priv/install/`, parses the YAML frontmatter for
  entity metadata, captures the markdown body as the description, and
  writes `lib/repo/install_seed.ex`. Commit the generated file alongside
  the markdown changes — boot reads the compiled module, not the markdown.

  ## Frontmatter format

  Each markdown file must begin with a YAML-style frontmatter block:

      ---
      entity: entity:agent:default
      type: policy
      scope: scope:company
      owner: cqr-mcp
      certified: true
      relationships:
        - PART_OF:entity:governance:relationship_guide:0.7
        - DEPENDS_ON:entity:governance:assertion_protocol:0.6
      ---

      # Markdown body becomes the description...

  Required fields: `entity`, `type`, `scope`, `owner`, `certified`.
  Optional: `relationships` (list of `REL_TYPE:entity:address:strength` strings).
  """

  use Mix.Task

  @shortdoc "Generate lib/repo/install_seed.ex from priv/install/*.md"

  @install_dir "priv/install"
  @output_path "lib/repo/install_seed.ex"

  @impl Mix.Task
  def run(_args) do
    files = Path.wildcard(Path.join(@install_dir, "*.md"))

    if files == [] do
      Mix.raise("No markdown files found in #{@install_dir}")
    end

    entities = Enum.map(files, &parse_file/1)

    output = render_module(entities)

    File.write!(@output_path, output)

    Mix.shell().info("Generated #{@output_path} from #{length(entities)} markdown files")

    Enum.each(entities, fn e ->
      Mix.shell().info("  - #{e.entity} (#{byte_size(e.description)} bytes)")
    end)
  end

  # Parse a single markdown file into an entity map.
  defp parse_file(path) do
    content = File.read!(path)

    case String.split(content, ~r/^---\s*$/m, parts: 3) do
      ["", frontmatter, body] ->
        meta = parse_frontmatter(frontmatter)
        Map.put(meta, :description, String.trim(body))

      _ ->
        Mix.raise(
          "#{path}: missing or malformed frontmatter (expected --- delimited block at top)"
        )
    end
  end

  # Parse YAML-style frontmatter into a map. Supports scalar values and
  # the `relationships:` list (one entry per dash-prefixed line).
  defp parse_frontmatter(yaml) do
    yaml
    |> String.split("\n", trim: true)
    |> parse_frontmatter_lines(%{}, nil)
  end

  defp parse_frontmatter_lines([], acc, _list_key), do: acc

  defp parse_frontmatter_lines([line | rest], acc, list_key) do
    cond do
      # List item under the most recent list key
      list_key != nil and String.starts_with?(line, "  - ") ->
        item = line |> String.replace_prefix("  - ", "") |> String.trim()
        existing = Map.get(acc, list_key, [])
        parse_frontmatter_lines(rest, Map.put(acc, list_key, existing ++ [item]), list_key)

      # `key:` with no value -> opens a list
      String.match?(line, ~r/^[a-z_]+:\s*$/) ->
        [key, _] = String.split(line, ":", parts: 2)
        key_atom = String.to_atom(String.trim(key))
        parse_frontmatter_lines(rest, Map.put(acc, key_atom, []), key_atom)

      # `key: value` scalar
      String.match?(line, ~r/^[a-z_]+:\s+.+/) ->
        [key, value] = String.split(line, ":", parts: 2)
        key_atom = String.to_atom(String.trim(key))
        coerced = coerce_scalar(String.trim(value))
        parse_frontmatter_lines(rest, Map.put(acc, key_atom, coerced), nil)

      # Otherwise skip (blank line, comment, etc.)
      true ->
        parse_frontmatter_lines(rest, acc, list_key)
    end
  end

  defp coerce_scalar("true"), do: true
  defp coerce_scalar("false"), do: false
  defp coerce_scalar(s), do: s

  # Render the parsed entities as an Elixir module source file.
  defp render_module(entities) do
    entities_literal =
      entities
      |> Enum.map(&render_entity/1)
      |> Enum.join(",\n")

    """
    # GENERATED FILE — do not edit by hand.
    # Source: priv/install/*.md
    # Regenerate with: mix cqr.gen_install_fixture
    defmodule Cqr.Repo.InstallSeed do
      @moduledoc \"\"\"
      Boot-time seeder for the CQR universal protocols and installer entity.

      Generated from `priv/install/*.md` by `mix cqr.gen_install_fixture`.
      Loaded by `Cqr.Grafeo.Server` on first boot of an empty database to
      establish the minimum graph state required for the installer flow:

        * `entity:agent:default` — universal bootstrap
        * `entity:governance:relationship_guide` — typed relationship guide
        * `entity:governance:assertion_protocol` — write protocol
        * `entity:agent:default:coordination` — empty agent roster
        * `entity:install` — guided setup entry point

      The user resolves `entity:install` in their MCP client and walks
      through a 4-question conversation that asserts their organization,
      agents, and structural anchor entities.
      \"\"\"

      alias Cqr.Grafeo.Codec
      alias Cqr.Grafeo.Native
      alias Cqr.Repo.Seed

      require Logger

      @entities #{(entities_literal == "" && "[]") || ""}#{if entities_literal == "", do: "", else: "[\n" <> entities_literal <> "\n  ]"}

      @doc \"\"\"
      Returns the list of entities embedded by this seeder.

      Each entity is a map with keys: `:entity`, `:type`, `:scope`, `:owner`,
      `:certified`, `:relationships` (list of strings), and `:description`.
      \"\"\"
      def entities, do: @entities

      @doc \"\"\"
      Seed the universal protocols and installer entity if the database is
      empty. Idempotent — checks for existing entities before inserting.

      Replaces the legacy `Cqr.Repo.Seed.bootstrap_if_empty_direct/1` call
      that planted only a scope tree and a single bootstrap entity.
      \"\"\"
      def seed_if_empty_direct(db) do
        case Native.execute(db, "MATCH (s:Scope) RETURN count(s)") do
          {:ok, [row]} when map_size(row) > 0 ->
            maybe_seed_empty(db, row)

          {:ok, _} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end

      defp maybe_seed_empty(db, row) do
        case Map.values(row) do
          [0] ->
            Logger.info(
              "Empty persistent database — seeding scope tree and \#{length(@entities)} install entities"
            )

            with :ok <- seed_scopes(db),
                 :ok <- seed_entities(db),
                 :ok <- seed_relationships(db) do
              :ok
            end

          _ ->
            :ok
        end
      end

      # Reuse the canonical scope tree from Cqr.Repo.Seed so we have one
      # source of truth for scope hierarchy.
      defp seed_scopes(db) do
        q!(db, "INSERT (:Scope {name: 'company', path: 'company', level: 0})")

        for {name, path, level, parent_name} <- child_scopes() do
          q!(
            db,
            "MATCH (parent:Scope {name: '\#{parent_name}'}) " <>
              "INSERT (:Scope {name: '\#{name}', path: '\#{path}', level: \#{level}})" <>
              "-[:CHILD_OF]->(parent)"
          )
        end

        :ok
      end

      defp child_scopes do
        [
          {"finance", "company:finance", 1, "company"},
          {"product", "company:product", 1, "company"},
          {"engineering", "company:engineering", 1, "company"},
          {"hr", "company:hr", 1, "company"},
          {"customer_success", "company:customer_success", 1, "company"}
        ]
      end

      defp seed_entities(db) do
        for entity <- @entities do
          {namespace, name} = parse_entity_address(entity.entity)
          embedding = Cqr.Embedding.embed("\#{name} \#{entity.description}")
          embedding_literal = Seed.format_embedding(embedding)

          # Initial reputation higher than user-asserted entities (0.5)
          # because these are shipped, certified protocols.
          reputation = if entity.certified, do: 0.95, else: 0.85

          q!(
            db,
            "INSERT (:Entity {" <>
              "namespace: '\#{namespace}', name: '\#{name}', type: '\#{entity.type}', " <>
              "description: '\#{Codec.encode(entity.description)}', owner: '\#{entity.owner}', " <>
              "reputation: \#{reputation}, freshness_hours_ago: 0, " <>
              "certified: \#{entity.certified}, embedding: \#{embedding_literal}})"
          )

          # IN_SCOPE relationship to the company scope (root).
          # All install entities live in the root scope by default; agents
          # asserted by the installer can target deeper scopes as needed.
          q!(
            db,
            "MATCH (e:Entity {namespace: '\#{namespace}', name: '\#{name}'}), " <>
              "(s:Scope {path: 'company'}) " <>
              "INSERT (e)-[:IN_SCOPE {primary: true}]->(s)"
          )
        end

        :ok
      end

      defp seed_relationships(db) do
        for entity <- @entities, rel <- entity.relationships do
          {rel_type, target_address, strength} = parse_relationship(rel)
          {from_ns, from_name} = parse_entity_address(entity.entity)
          {to_ns, to_name} = parse_entity_address(target_address)

          # Relationships to entities outside the install seed (e.g.,
          # forward references that will be created by the installer)
          # are skipped here. The MATCH will simply find no rows and
          # the INSERT will be a no-op without raising.
          case Native.execute(
                 db,
                 "MATCH (a:Entity {namespace: '\#{from_ns}', name: '\#{from_name}'}), " <>
                   "(b:Entity {namespace: '\#{to_ns}', name: '\#{to_name}'}) " <>
                   "INSERT (a)-[:\#{rel_type} {strength: \#{strength}}]->(b)"
               ) do
            {:ok, _} -> :ok
            # Tolerate failure on forward references — these resolve
            # later when the installer or other seed runs assert the
            # missing endpoints.
            {:error, _} -> :ok
          end
        end

        :ok
      end

      # Split "entity:namespace:name" into {namespace, name}.
      # For deeper addresses like "entity:agent:default:coordination",
      # everything after the first segment becomes namespace ("agent:default")
      # and the leaf is "coordination". This matches the CQR addressing
      # convention used elsewhere.
      defp parse_entity_address("entity:" <> rest) do
        segments = String.split(rest, ":")
        {namespace_segments, [name]} = Enum.split(segments, -1)
        namespace = Enum.join(namespace_segments, ":")
        {namespace, name}
      end

      # Parse "REL_TYPE:entity:address:strength" into a tuple.
      # The address portion may have any number of colons; strength is
      # always the trailing decimal segment.
      defp parse_relationship(rel) do
        # Split on colons. The first segment is the relationship type,
        # the last is the strength, everything else is the entity address.
        segments = String.split(rel, ":")
        rel_type = hd(segments)
        strength = segments |> List.last() |> String.to_float()
        address_segments = segments |> Enum.drop(1) |> Enum.drop(-1)
        address = Enum.join(address_segments, ":")
        {rel_type, address, strength}
      end

      defp q!(db, query) do
        case Native.execute(db, query) do
          {:ok, _} -> :ok
          {:error, reason} -> raise "InstallSeed query failed: \#{reason}\\nQuery: \#{query}"
        end
      end
    end
    """
  end

  # Render a single entity as an Elixir map literal.
  defp render_entity(e) do
    rels =
      Map.get(e, :relationships, [])
      |> Enum.map(&inspect/1)
      |> Enum.join(",\n        ")

    """
        %{
          entity: #{inspect(e.entity)},
          type: #{inspect(e.type)},
          scope: #{inspect(e.scope)},
          owner: #{inspect(e.owner)},
          certified: #{inspect(e.certified)},
          relationships: [#{if rels == "", do: "", else: "\n        " <> rels <> "\n      "}],
          description: #{inspect(e.description, limit: :infinity, printable_limit: :infinity)}
        }\
    """
  end
end
