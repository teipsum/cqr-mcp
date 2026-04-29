defmodule Cqr.Repo.SnapshotTest do
  use ExUnit.Case

  alias Cqr.Grafeo.Server, as: Grafeo
  alias Cqr.Repo.Snapshot

  @grafeo_cli "/tmp/grafeo-cli-sandbox/grafeo-v0.5.40-aarch64-apple-darwin/grafeo"

  describe "dump shape" do
    setup do
      name = :"snap_grafeo_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Grafeo.start_link(storage: :memory, name: name)
      %{grafeo: name}
    end

    test "dump_to_iolist produces NDJSON nodes and edges with typed properties",
         %{grafeo: name} do
      assert {:ok, iolist} = Snapshot.dump_to_iolist(name)
      bin = IO.iodata_to_binary(iolist)

      lines =
        bin
        |> String.split("\n", trim: true)

      assert length(lines) > 0

      decoded = Enum.map(lines, &Jason.decode!/1)

      Enum.each(decoded, fn obj ->
        assert obj["type"] in ["node", "edge"]
        assert is_integer(obj["id"])
        assert is_map(obj["properties"])
      end)

      nodes = Enum.filter(decoded, &(&1["type"] == "node"))
      edges = Enum.filter(decoded, &(&1["type"] == "edge"))

      assert nodes != []
      assert edges != []

      Enum.each(nodes, fn n ->
        assert is_list(n["labels"])
        assert Enum.all?(n["labels"], &is_binary/1)
        assert_typed_properties(n["properties"])
      end)

      Enum.each(edges, fn e ->
        assert is_integer(e["source"])
        assert is_integer(e["target"])
        assert is_binary(e["edge_type"])
        assert_typed_properties(e["properties"])
      end)
    end
  end

  describe "atomic file write" do
    test "dump_to_file writes a parseable NDJSON file" do
      name = :"snap_grafeo_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Grafeo.start_link(storage: :memory, name: name)

      path =
        Path.join(System.tmp_dir!(), "cqr_snap_test_#{System.unique_integer([:positive])}.json")

      on_exit(fn -> File.rm(path) end)

      assert :ok = Snapshot.dump_to_file(path, name)
      assert File.exists?(path)
      assert byte_size(File.read!(path)) > 0

      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.each(&Jason.decode!/1)
    end
  end

  describe "corruption detection" do
    test "grafeo_corrupt_error?/1 trips on GRAFEO-X001 and the canonical message" do
      assert Snapshot.grafeo_corrupt_error?(
               "open failed: GRAFEO-X001 snapshot checksum mismatch: expected 0xDEAD, got 0x0000"
             )

      assert Snapshot.grafeo_corrupt_error?("snapshot checksum mismatch")
      refute Snapshot.grafeo_corrupt_error?("file not found")
      refute Snapshot.grafeo_corrupt_error?(nil)
      refute Snapshot.grafeo_corrupt_error?(:something_else)
    end

    test "Grafeo.Server.classify_open_result/2 routes corruption to {:stop, :grafeo_corrupt} and logs banner" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          assert {:stop, :grafeo_corrupt} =
                   Grafeo.classify_open_result(
                     {:error,
                      "GRAFEO-X001 snapshot checksum mismatch: expected 0xABCD, got 0x00000000"},
                     {:path, "/tmp/fake.grafeo"}
                   )
        end)

      assert log =~ "GRAFEO DATABASE CORRUPT"
      assert log =~ "~/bin/cqr-recover"
      assert log =~ "/tmp/fake.grafeo"
    end

    test "non-corruption errors pass through unchanged" do
      assert {:error, "some other error"} =
               Grafeo.classify_open_result({:error, "some other error"}, :memory)

      assert {:ok, :fake_db} = Grafeo.classify_open_result({:ok, :fake_db}, :memory)
    end
  end

  describe "roundtrip via grafeo CLI" do
    @describetag :slow
    @describetag :grafeo_cli

    setup do
      unless File.exists?(@grafeo_cli) do
        {:skip, "grafeo CLI not present at #{@grafeo_cli}"}
      else
        :ok
      end
    end

    test "dump → grafeo data load → matching node/edge counts" do
      name = :"snap_grafeo_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Grafeo.start_link(storage: :memory, name: name)

      base = Path.join(System.tmp_dir!(), "cqr_snap_rt_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf!(base) end)

      dump_path = Path.join(base, "snapshot.json")
      target_db = Path.join(base, "loaded.grafeo")

      assert :ok = Snapshot.dump_to_file(dump_path, name)

      {_, 0} =
        System.cmd(@grafeo_cli, ["init", target_db, "--mode", "lpg"], stderr_to_stdout: true)

      {_, 0} =
        System.cmd(@grafeo_cli, ["data", "load", dump_path, target_db], stderr_to_stdout: true)

      # Verify counts via the grafeo CLI's `info --format json`.
      # Re-opening a freshly-loaded .grafeo via Native.new/1 trips the
      # X001 corruption pattern (the very bug this safety net wraps), so
      # the recovery path's own verification has to stay outside the NIF.
      {info_json, 0} =
        System.cmd(@grafeo_cli, ["info", target_db, "--format", "json"], stderr_to_stdout: true)

      info = Jason.decode!(info_json)

      {:ok, source_node_count} = source_count(name, "MATCH (n) RETURN count(n)")
      {:ok, source_edge_count} = source_count(name, "MATCH ()-[r]->() RETURN count(r)")

      assert info["node_count"] == source_node_count
      assert info["edge_count"] == source_edge_count
    end

    defp source_count(name, query) do
      {:ok, [%{"countnonnull(...)" => n}]} = Grafeo.query(query, name)
      {:ok, n}
    end
  end

  defp assert_typed_properties(props) do
    Enum.each(props, fn {_k, v} ->
      assert_typed_value(v)
    end)
  end

  defp assert_typed_value(%{"String" => v}), do: assert(is_binary(v))
  defp assert_typed_value(%{"Int64" => v}), do: assert(is_integer(v))
  defp assert_typed_value(%{"Float64" => v}), do: assert(is_float(v))
  defp assert_typed_value(%{"Bool" => v}), do: assert(is_boolean(v))

  defp assert_typed_value(%{"List" => xs}) when is_list(xs),
    do: Enum.each(xs, &assert_typed_value/1)

  defp assert_typed_value(other), do: flunk("untyped property value: #{inspect(other)}")
end
