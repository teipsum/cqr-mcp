defmodule Mix.Tasks.Cqr.ReplaySnapshotTest do
  use ExUnit.Case, async: false

  alias Cqr.Grafeo.Server, as: Grafeo
  alias Mix.Tasks.Cqr.ReplaySnapshot

  describe "serialize_value/1" do
    test "renders String with escaping for the GQL parser" do
      assert ReplaySnapshot.serialize_value(%{"String" => "hello"}) == "'hello'"
      assert ReplaySnapshot.serialize_value(%{"String" => "it's"}) == "'it\\'s'"
      assert ReplaySnapshot.serialize_value(%{"String" => "back\\slash"}) == "'back\\\\slash'"
    end

    test "preserves an already-encoded b64: prefix verbatim" do
      # Codec.encode/1 produces b64:<base64>. The b64 alphabet has no
      # special chars, so escape is a no-op and the prefix round-trips.
      encoded = Cqr.Grafeo.Codec.encode("a description with 'quotes' and \\slashes")
      rendered = ReplaySnapshot.serialize_value(%{"String" => encoded})
      assert rendered == "'#{encoded}'"
      assert String.starts_with?(encoded, "b64:")
    end

    test "renders Int64 as a bare integer" do
      assert ReplaySnapshot.serialize_value(%{"Int64" => 0}) == "0"
      assert ReplaySnapshot.serialize_value(%{"Int64" => -42}) == "-42"
      assert ReplaySnapshot.serialize_value(%{"Int64" => 1_234_567}) == "1234567"
    end

    test "renders Float64 with 6 decimals to match Seed.format_embedding" do
      assert ReplaySnapshot.serialize_value(%{"Float64" => 0.5}) == "0.500000"
      assert ReplaySnapshot.serialize_value(%{"Float64" => -0.301511}) == "-0.301511"
      assert ReplaySnapshot.serialize_value(%{"Float64" => 0.0}) == "0.000000"
    end

    test "renders Bool as lowercase" do
      assert ReplaySnapshot.serialize_value(%{"Bool" => true}) == "true"
      assert ReplaySnapshot.serialize_value(%{"Bool" => false}) == "false"
    end

    test "renders List of Float64 via Seed.format_embedding" do
      input = %{"List" => [%{"Float64" => 0.0}, %{"Float64" => 0.5}, %{"Float64" => -0.25}]}
      assert ReplaySnapshot.serialize_value(input) == "[0.000000, 0.500000, -0.250000]"
    end

    test "renders mixed-type List inline" do
      input = %{"List" => [%{"String" => "a"}, %{"Int64" => 1}, %{"Bool" => true}]}
      assert ReplaySnapshot.serialize_value(input) == "['a', 1, true]"
    end

    test "raises on an unknown shape" do
      assert_raise ArgumentError, fn ->
        ReplaySnapshot.serialize_value(%{"Mystery" => :nope})
      end
    end
  end

  describe "parse_records/1 and id_map" do
    test "groups records by phase and rejects unsupported labels" do
      ndjson =
        Enum.map_join(
          [
            scope_record(0, "company"),
            entity_record(1, "ns", "thing"),
            audit_record(2, "AssertionRecord", "rec-1"),
            edge_record(3, 1, 0, "IN_SCOPE")
          ],
          "\n",
          &Jason.encode!/1
        )

      assert {:ok, %{by_phase: bp, total: 4}} = ReplaySnapshot.parse_records(ndjson)
      assert length(bp.scope) == 1
      assert length(bp.entity) == 1
      assert length(bp.audit) == 1
      assert length(bp.edges) == 1

      id_map = ReplaySnapshot.build_id_map(bp)
      assert Map.fetch!(id_map, 0) == {"Scope", "{path: 'company'}"}
      assert Map.fetch!(id_map, 1) == {"Entity", "{namespace: 'ns', name: 'thing'}"}
      assert Map.fetch!(id_map, 2) == {"AssertionRecord", "{record_id: 'rec-1'}"}
    end

    test "rejects unsupported node labels with a clear error" do
      ndjson =
        Jason.encode!(%{
          "type" => "node",
          "id" => 99,
          "labels" => ["WeirdLabel"],
          "properties" => %{"name" => %{"String" => "x"}}
        })

      assert {:error, {:unsupported_node_labels, ["WeirdLabel"]}} =
               ReplaySnapshot.parse_records(ndjson)
    end
  end

  describe "round-trip against in-memory Grafeo" do
    setup do
      name = :"replay_grafeo_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Grafeo.start_link(storage: :memory, name: name, seed: false)
      executor = fn cypher -> Grafeo.query(cypher, name) end
      %{grafeo: name, executor: executor}
    end

    test "replays a synthetic 3-node, 2-edge fixture and verifies counts",
         %{executor: executor, grafeo: name} do
      ndjson = synthetic_ndjson()

      {:ok, parsed} = ReplaySnapshot.parse_records(ndjson)
      assert :ok = ReplaySnapshot.replay(parsed, executor)

      assert {:ok, [%{} = node_row]} = Grafeo.query("MATCH (n) RETURN count(n)", name)
      assert [3] = Map.values(node_row)

      assert {:ok, [%{} = edge_row]} = Grafeo.query("MATCH ()-[r]->() RETURN count(r)", name)
      assert [2] = Map.values(edge_row)

      # Spot-check property fidelity on the Entity.
      assert {:ok, [entity]} =
               Grafeo.query(
                 "MATCH (e:Entity {namespace: 'ns', name: 'thing'}) RETURN e",
                 name
               )

      e = entity["e"]
      assert e["namespace"] == "ns"
      assert e["name"] == "thing"
      assert e["certified"] == true
      assert e["confidence"] == 0.75
      assert e["embedding"] == [0.1, 0.2, 0.3]
    end

    test "is idempotent-or-fail-fast: second run aborts on non-empty graph",
         %{executor: executor} do
      ndjson = synthetic_ndjson()
      {:ok, parsed} = ReplaySnapshot.parse_records(ndjson)

      assert :ok = ReplaySnapshot.replay(parsed, executor)
      assert {:error, {:graph_not_empty, n}} = ReplaySnapshot.replay(parsed, executor)
      assert n > 0
    end
  end

  # --- Synthetic fixture ---

  defp synthetic_ndjson do
    [
      scope_record(10, "company"),
      entity_record(11, "ns", "thing", %{
        "certified" => %{"Bool" => true},
        "confidence" => %{"Float64" => 0.75},
        "embedding" => %{
          "List" => [
            %{"Float64" => 0.1},
            %{"Float64" => 0.2},
            %{"Float64" => 0.3}
          ]
        }
      }),
      audit_record(12, "AssertionRecord", "rec-abc"),
      edge_record(20, 11, 10, "IN_SCOPE", %{"primary" => %{"Bool" => true}}),
      edge_record(21, 11, 12, "ASSERTED_BY")
    ]
    |> Enum.map_join("\n", &Jason.encode!/1)
  end

  defp scope_record(id, path) do
    %{
      "type" => "node",
      "id" => id,
      "labels" => ["Scope"],
      "properties" => %{
        "path" => %{"String" => path},
        "name" => %{"String" => path |> String.split(":") |> List.last()},
        "level" => %{"Int64" => length(String.split(path, ":")) - 1}
      }
    }
  end

  defp entity_record(id, ns, name, extra_props \\ %{}) do
    base = %{
      "namespace" => %{"String" => ns},
      "name" => %{"String" => name}
    }

    %{
      "type" => "node",
      "id" => id,
      "labels" => ["Entity"],
      "properties" => Map.merge(base, extra_props)
    }
  end

  defp audit_record(id, label, record_id) do
    %{
      "type" => "node",
      "id" => id,
      "labels" => [label],
      "properties" => %{
        "record_id" => %{"String" => record_id},
        "agent_id" => %{"String" => "twin:test"},
        "timestamp" => %{"String" => "2026-01-01T00:00:00Z"}
      }
    }
  end

  defp edge_record(id, source, target, type, props \\ %{}) do
    %{
      "type" => "edge",
      "id" => id,
      "source" => source,
      "target" => target,
      "edge_type" => type,
      "properties" => props
    }
  end
end
