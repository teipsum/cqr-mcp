defmodule CqrMcp.ApplicationTest do
  use ExUnit.Case, async: false

  describe "children_for_mode/1" do
    test "standalone includes Cqr.Grafeo.Server" do
      children = CqrMcp.Application.children_for_mode(:standalone)
      modules = child_modules(children)

      assert Cqr.Grafeo.Server in modules
      assert Cqr.Repo.ScopeTree in modules
      assert CqrMcp.Server in modules
    end

    test "embedded excludes Cqr.Grafeo.Server" do
      children = CqrMcp.Application.children_for_mode(:embedded)
      modules = child_modules(children)

      refute Cqr.Grafeo.Server in modules
      assert Cqr.Repo.ScopeTree in modules
      assert CqrMcp.Server in modules
    end

    test "embedded is a strict subset of standalone" do
      embedded = CqrMcp.Application.children_for_mode(:embedded)
      standalone = CqrMcp.Application.children_for_mode(:standalone)

      embedded_modules = child_modules(embedded) |> MapSet.new()
      standalone_modules = child_modules(standalone) |> MapSet.new()

      assert MapSet.subset?(embedded_modules, standalone_modules)
    end

    test "both modes include SSE registry and Bandit" do
      for mode <- [:standalone, :embedded] do
        children = CqrMcp.Application.children_for_mode(mode)
        modules = child_modules(children)

        assert Registry in modules
        assert Bandit in modules
      end
    end
  end

  defp child_modules(children) do
    Enum.map(children, fn
      {module, _opts} -> module
      module when is_atom(module) -> module
    end)
  end
end
