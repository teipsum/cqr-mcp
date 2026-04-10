defmodule Cqr.Grafeo.ServerTest do
  use ExUnit.Case

  alias Cqr.Grafeo.Server

  setup do
    # Start a named server for each test to avoid conflicts with the app supervisor
    name = :"test_grafeo_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Server.start_link(storage: :memory, name: name)
    %{name: name}
  end

  test "query/2 inserts and retrieves data", %{name: name} do
    assert {:ok, _} = Server.query("INSERT (:Test {name: 'smoke'})", name)
    assert {:ok, rows} = Server.query("MATCH (t:Test) RETURN t.name", name)
    assert rows == [%{"t.name" => "smoke"}]
  end

  test "health/1 reports healthy", %{name: name} do
    assert {:ok, version} = Server.health(name)
    assert version =~ "grafeo"
  end
end
