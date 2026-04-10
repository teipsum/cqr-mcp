defmodule CqrMcpTest do
  use ExUnit.Case

  test "application starts successfully" do
    assert Process.whereis(CqrMcp.Supervisor) != nil
  end

  test "grafeo server is running in supervision tree" do
    assert Process.whereis(Cqr.Grafeo.Server) != nil
  end
end
