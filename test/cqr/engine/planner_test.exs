defmodule Cqr.Engine.PlannerTest do
  use ExUnit.Case, async: true

  alias Cqr.Engine.Planner

  defmodule MockGithub do
    @behaviour Cqr.Adapter.Behaviour

    @impl true
    def capabilities, do: [:resolve, :discover]

    @impl true
    def namespace_prefix, do: "github"

    @impl true
    def resolve(_expression, _scope_context, _opts), do: {:ok, %Cqr.Result{data: []}}

    @impl true
    def discover(_expression, _scope_context, _opts), do: {:ok, %Cqr.Result{data: []}}

    @impl true
    def normalize(raw, _metadata), do: raw

    @impl true
    def health_check, do: :ok
  end

  defmodule MockMulti do
    @behaviour Cqr.Adapter.Behaviour

    @impl true
    def capabilities, do: [:resolve]

    @impl true
    def namespace_prefix, do: ["jira", "linear"]

    @impl true
    def resolve(_expression, _scope_context, _opts), do: {:ok, %Cqr.Result{data: []}}

    @impl true
    def discover(_expression, _scope_context, _opts), do: {:ok, %Cqr.Result{data: []}}

    @impl true
    def normalize(raw, _metadata), do: raw

    @impl true
    def health_check, do: :ok
  end

  @adapters [MockGithub, MockMulti, Cqr.Adapter.Grafeo]

  describe "plan/2 — namespace routing" do
    test "github entity routes to github adapter only" do
      ast = %Cqr.Resolve{entity: {"github", "issues"}}

      {:ok, plan} = Planner.plan(ast, adapters: @adapters)

      assert [{MockGithub, :resolve}] = plan
    end

    test "non-github entity does not reach github adapter" do
      ast = %Cqr.Resolve{entity: {"agent:product_strategy", "orientation"}}

      {:ok, plan} = Planner.plan(ast, adapters: @adapters)

      refute Enum.any?(plan, fn {adapter, _} -> adapter == MockGithub end)
    end

    test "agent entity falls back to nil-prefix adapter (Grafeo)" do
      ast = %Cqr.Resolve{entity: {"agent:product_strategy", "orientation"}}

      {:ok, plan} = Planner.plan(ast, adapters: @adapters)

      assert [{Cqr.Adapter.Grafeo, :resolve}] = plan
    end

    test "finance entity (no matching prefix) falls back to Grafeo" do
      ast = %Cqr.Resolve{entity: {"finance", "arr"}}

      {:ok, plan} = Planner.plan(ast, adapters: @adapters)

      assert [{Cqr.Adapter.Grafeo, :resolve}] = plan
    end

    test "adapter declaring list of prefixes matches any listed namespace" do
      jira_ast = %Cqr.Resolve{entity: {"jira", "ticket"}}
      linear_ast = %Cqr.Resolve{entity: {"linear", "issue"}}

      {:ok, jira_plan} = Planner.plan(jira_ast, adapters: @adapters)
      {:ok, linear_plan} = Planner.plan(linear_ast, adapters: @adapters)

      assert [{MockMulti, :resolve}] = jira_plan
      assert [{MockMulti, :resolve}] = linear_plan
    end

    test "DISCOVER with entity anchor routes by namespace" do
      ast = %Cqr.Discover{related_to: {:entity, {"github", "issues"}}}

      {:ok, plan} = Planner.plan(ast, adapters: @adapters)

      assert [{MockGithub, :discover}] = plan
    end

    test "DISCOVER prefix mode routes by first segment" do
      ast = %Cqr.Discover{related_to: {:prefix, ["github", "issues"]}}

      {:ok, plan} = Planner.plan(ast, adapters: @adapters)

      assert [{MockGithub, :discover}] = plan
    end

    test "free-text DISCOVER reaches all capable adapters" do
      ast = %Cqr.Discover{related_to: {:search, "churn patterns"}}

      {:ok, plan} = Planner.plan(ast, adapters: @adapters)

      adapter_modules = Enum.map(plan, fn {adapter, _} -> adapter end)

      assert MockGithub in adapter_modules
      assert Cqr.Adapter.Grafeo in adapter_modules
      refute MockMulti in adapter_modules
    end
  end

  describe "resolve_adapter/3 — namespace routing" do
    test "routes to namespace-matching adapter" do
      context = %{adapters: @adapters}

      assert {:ok, MockGithub} =
               Planner.resolve_adapter(context, :resolve, {"github", "issues"})
    end

    test "falls back to nil-prefix adapter when no match" do
      context = %{adapters: @adapters}

      assert {:ok, Cqr.Adapter.Grafeo} =
               Planner.resolve_adapter(context, :resolve, {"finance", "arr"})
    end

    test "splits hierarchical namespace and matches on top-level segment" do
      context = %{adapters: @adapters}

      assert {:ok, MockGithub} =
               Planner.resolve_adapter(context, :resolve, {"github:org:repo", "pr"})
    end

    test "nil entity_address behaves like resolve_adapter/2" do
      context = %{adapters: @adapters}

      {:ok, via3} = Planner.resolve_adapter(context, :resolve, nil)
      {:ok, via2} = Planner.resolve_adapter(context, :resolve)

      assert via3 == via2
    end

    test "no capable adapter returns :no_adapter error" do
      context = %{adapters: [MockGithub]}

      assert {:error, %Cqr.Error{code: :no_adapter}} =
               Planner.resolve_adapter(context, :assert, {"github", "issues"})
    end
  end

  describe "resolve_adapter/2 — backward compatibility" do
    test "returns first capable adapter regardless of namespace" do
      context = %{adapters: @adapters}

      assert {:ok, adapter} = Planner.resolve_adapter(context, :resolve)
      assert adapter in @adapters
    end

    test "uses default adapters when context omits :adapters" do
      assert {:ok, Cqr.Adapter.Grafeo} = Planner.resolve_adapter(%{}, :resolve)
    end

    test "returns :no_adapter when no adapter supports the capability" do
      context = %{adapters: [MockGithub]}

      assert {:error, %Cqr.Error{code: :no_adapter}} =
               Planner.resolve_adapter(context, :assert)
    end
  end
end
