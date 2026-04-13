defmodule Mix.Tasks.Cqr.Populate do
  @moduledoc """
  Populate the persistent Grafeo database with the cognitive-test entity set.

  The task opens the persistent database directly (bypassing the MCP
  transport) and runs ~180 ASSERTs through `Cqr.Engine.execute/2` so the
  full governance pipeline fires: parser, scope validation, adapter
  writes, embedding computation.

      mix cqr.populate [PATH]

  PATH defaults to `~/.cqr/grafeo.grafeo`.

  The MCP server must be stopped before running this task — only one
  process can hold the Grafeo file lock. On completion the task sends a
  normal stop to `Cqr.Grafeo.Server`, which triggers the Grafeo close
  path and checkpoints the data to disk.
  """

  use Mix.Task

  alias Cqr.Engine
  alias Cqr.Grafeo.Server, as: GrafeoServer
  alias Cqr.Populate.Entities
  alias Cqr.Repo.ScopeTree

  @shortdoc "Populate the persistent Grafeo DB with cognitive-test entities"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadpaths")
    Mix.Task.run("compile")

    Application.ensure_all_started(:logger)

    path =
      case args do
        [explicit | _] -> Path.expand(explicit)
        [] -> Path.expand("~/.cqr/grafeo.grafeo")
      end

    Mix.shell().info("Opening persistent Grafeo at #{path}")

    {:ok, _} =
      GrafeoServer.start_link(
        storage: {:path, path},
        seed: false,
        reset: false
      )

    {:ok, _} = ScopeTree.start_link([])

    ctx = %{scope: ["company"], agent_id: "twin:michael"}

    totals =
      Enum.reduce(Entities.sections(), %{created: 0, skipped: 0, failed: 0}, fn
        {label, entries}, acc ->
          Mix.shell().info("\n== #{label} (#{length(entries)}) ==")
          section_totals = run_section(entries, ctx)
          print_section_summary(label, section_totals)
          merge_totals(acc, section_totals)
      end)

    Mix.shell().info("""

    == TOTAL ==
      created: #{totals.created}
      skipped: #{totals.skipped}
      failed:  #{totals.failed}
    """)

    Mix.shell().info("Flushing and closing Grafeo...")
    GenServer.stop(GrafeoServer, :normal, 30_000)
    Mix.shell().info("Done. Data checkpointed to #{path}")
  end

  defp run_section(entries, ctx) do
    Enum.reduce(entries, %{created: 0, skipped: 0, failed: 0}, fn entry, acc ->
      case assert_entity(entry, ctx) do
        :created -> %{acc | created: acc.created + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
        :failed -> %{acc | failed: acc.failed + 1}
      end
    end)
  end

  defp assert_entity({ns, name, type, description, derived_from}, ctx) do
    expr =
      "ASSERT entity:#{ns}:#{name} TYPE #{type} " <>
        ~s(DESCRIPTION "#{description}" ) <>
        ~s(INTENT "cognitive-test population" ) <>
        "DERIVED_FROM " <> Enum.join(derived_from, ", ")

    case Engine.execute(expr, ctx) do
      {:ok, _} ->
        Mix.shell().info("  + #{ns}:#{name}")
        :created

      {:error, %Cqr.Error{code: :entity_exists}} ->
        Mix.shell().info("  . #{ns}:#{name} (exists)")
        :skipped

      {:error, err} ->
        Mix.shell().error("  ! #{ns}:#{name}: #{err.code} #{err.message}")
        :failed
    end
  end

  defp merge_totals(a, b) do
    %{
      created: a.created + b.created,
      skipped: a.skipped + b.skipped,
      failed: a.failed + b.failed
    }
  end

  defp print_section_summary(label, t) do
    Mix.shell().info(
      "  -- #{label}: created=#{t.created} skipped=#{t.skipped} failed=#{t.failed}"
    )
  end
end
