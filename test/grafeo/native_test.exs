defmodule Cqr.Grafeo.NativeTest do
  use ExUnit.Case, async: true

  alias Cqr.Grafeo.Native

  describe "new/1" do
    test "opens an in-memory database" do
      assert {:ok, db} = Native.new(:memory)
      assert is_reference(db)
    end
  end

  describe "execute/2" do
    setup do
      {:ok, db} = Native.new(:memory)
      %{db: db}
    end

    test "inserts and queries a node", %{db: db} do
      assert {:ok, _} = Native.execute(db, "INSERT (:Test {name: 'hello'})")
      assert {:ok, rows} = Native.execute(db, "MATCH (t:Test) RETURN t.name")
      assert rows == [%{"t.name" => "hello"}]
    end

    test "inserts and queries multiple nodes", %{db: db} do
      Native.execute(db, "INSERT (:Person {name: 'Alice', age: 30})")
      Native.execute(db, "INSERT (:Person {name: 'Bob', age: 25})")

      {:ok, rows} = Native.execute(db, "MATCH (p:Person) RETURN p.name, p.age ORDER BY p.name")

      assert length(rows) == 2
      assert Enum.at(rows, 0)["p.name"] == "Alice"
      assert Enum.at(rows, 0)["p.age"] == 30
      assert Enum.at(rows, 1)["p.name"] == "Bob"
      assert Enum.at(rows, 1)["p.age"] == 25
    end

    test "handles relationships", %{db: db} do
      Native.execute(db, """
      INSERT (:Metric {name: 'arr', value: 1000000})-[:CORRELATES_WITH]->(:Metric {name: 'churn_rate', value: 0.05})
      """)

      {:ok, rows} =
        Native.execute(db, """
        MATCH (a:Metric)-[r:CORRELATES_WITH]->(b:Metric) RETURN a.name, b.name
        """)

      assert length(rows) == 1
      assert hd(rows)["a.name"] == "arr"
      assert hd(rows)["b.name"] == "churn_rate"
    end

    test "returns error for invalid query", %{db: db} do
      assert {:error, _reason} = Native.execute(db, "INVALID QUERY SYNTAX HERE")
    end

    test "returns empty list for no matches", %{db: db} do
      {:ok, rows} = Native.execute(db, "MATCH (n:NonExistent) RETURN n.name")
      assert rows == []
    end
  end

  describe "health_check/1" do
    test "reports healthy for open database" do
      {:ok, db} = Native.new(:memory)
      assert {:ok, version} = Native.health_check(db)
      assert is_binary(version)
      assert version =~ "grafeo"
    end
  end

  describe "close/1" do
    test "closes database successfully" do
      {:ok, db} = Native.new(:memory)
      assert :ok = Native.close(db)
    end
  end
end
