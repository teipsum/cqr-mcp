defmodule Cqr.EngineTest do
  use ExUnit.Case

  alias Cqr.Engine

  @finance_context %{scope: ["company", "finance"]}
  @engineering_context %{scope: ["company", "engineering"]}
  @company_context %{scope: ["company"]}

  describe "execute/2 — RESOLVE from string" do
    test "resolves entity within scope" do
      {:ok, result} =
        Engine.execute("RESOLVE entity:finance:arr", @finance_context)

      assert %Cqr.Result{} = result
      assert length(result.data) > 0
      assert hd(result.data).name == "arr"
    end

    test "returns quality envelope" do
      {:ok, result} =
        Engine.execute("RESOLVE entity:finance:arr", @finance_context)

      assert %Cqr.Quality{} = result.quality
      assert result.quality.owner == "finance_team"
    end

    test "returns cost accounting" do
      {:ok, result} =
        Engine.execute("RESOLVE entity:finance:arr", @finance_context)

      assert %Cqr.Cost{} = result.cost
      assert result.cost.adapters_queried >= 1
      assert result.cost.operations >= 1
      assert result.cost.execution_ms >= 0
    end

    test "entity in sibling scope returns error" do
      {:error, error} =
        Engine.execute("RESOLVE entity:finance:arr", @engineering_context)

      assert error.code == :entity_not_found
    end

    test "entity not found returns informative error" do
      {:error, error} =
        Engine.execute("RESOLVE entity:finance:nonexistent", @finance_context)

      assert error.code == :entity_not_found
      assert error.retry_guidance != nil
    end

    test "invalid CQR expression returns parse error" do
      {:error, error} = Engine.execute("INVALID STUFF", @finance_context)
      assert error.code == :parse_error
    end

    test "scope constraint validation — accessible scope" do
      {:ok, result} =
        Engine.execute(
          "RESOLVE entity:finance:arr FROM scope:company:finance",
          @finance_context
        )

      assert length(result.data) > 0
    end

    test "scope constraint validation — inaccessible scope" do
      {:error, error} =
        Engine.execute(
          "RESOLVE entity:finance:arr FROM scope:company:engineering",
          @finance_context
        )

      assert error.code == :scope_access
    end
  end

  describe "execute/2 — RESOLVE from AST" do
    test "accepts pre-parsed AST" do
      ast = %Cqr.Resolve{entity: {"finance", "arr"}}
      {:ok, result} = Engine.execute(ast, @finance_context)
      assert hd(result.data).name == "arr"
    end
  end

  describe "execute/2 — DISCOVER" do
    test "discovers related entities" do
      {:ok, result} =
        Engine.execute(
          "DISCOVER concepts RELATED TO entity:product:churn_rate",
          %{scope: ["company", "product"]}
        )

      assert %Cqr.Result{} = result
      assert result.cost.execution_ms >= 0
    end

    test "returns quality envelope on discovery" do
      {:ok, result} =
        Engine.execute(
          "DISCOVER concepts RELATED TO entity:product:churn_rate",
          %{scope: ["company", "product"]}
        )

      assert %Cqr.Quality{} = result.quality
    end

    test "discovery with depth" do
      {:ok, result} =
        Engine.execute(
          "DISCOVER concepts RELATED TO entity:product:churn_rate DEPTH 2",
          %{scope: ["company", "product"]}
        )

      assert %Cqr.Result{} = result
    end
  end

  describe "execute/2 — CERTIFY" do
    test "propose certification" do
      {:ok, result} =
        Engine.execute(
          "CERTIFY entity:finance:arr STATUS proposed AUTHORITY cfo",
          @finance_context
        )

      assert %Cqr.Result{} = result
      assert hd(result.data).new_status == :proposed
      assert hd(result.data).authority == "cfo"
    end

    test "full certification workflow" do
      # Use a specific entity for this workflow test
      ctx = Map.put(@finance_context, :agent_id, "test_agent")

      # Step 1: Propose
      {:ok, r1} =
        Engine.execute(
          "CERTIFY entity:finance:mrr STATUS proposed AUTHORITY finance_team",
          ctx
        )

      assert hd(r1.data).new_status == :proposed

      # Step 2: Move to review
      {:ok, r2} =
        Engine.execute(
          "CERTIFY entity:finance:mrr STATUS under_review AUTHORITY finance_team",
          ctx
        )

      assert hd(r2.data).new_status == :under_review

      # Step 3: Certify
      {:ok, r3} =
        Engine.execute(
          ~s(CERTIFY entity:finance:mrr STATUS certified AUTHORITY cfo EVIDENCE "Validated against Q4 actuals"),
          ctx
        )

      assert hd(r3.data).new_status == :certified
      assert r3.quality.certified_by == "cfo"
    end

    test "invalid transition returns error" do
      # First propose
      Engine.execute(
        "CERTIFY entity:finance:burn_rate STATUS proposed AUTHORITY finance_team",
        @finance_context
      )

      # Try to jump to certified (skipping under_review)
      {:error, error} =
        Engine.execute(
          "CERTIFY entity:finance:burn_rate STATUS certified AUTHORITY cfo",
          @finance_context
        )

      assert error.code == :invalid_transition
      assert error.retry_guidance != nil
    end

    test "certify records audit trail in Grafeo" do
      Engine.execute(
        "CERTIFY entity:finance:ltv STATUS proposed AUTHORITY finance_team",
        @finance_context
      )

      # CERTIFY writes an immutable CertificationRecord per phase transition.
      {:ok, rows} =
        Cqr.Grafeo.Server.query(
          "MATCH (r:CertificationRecord {entity_name: 'ltv'}) " <>
            "RETURN r.new_status, r.authority"
        )

      assert length(rows) > 0
      assert Enum.any?(rows, fn row -> row["r.new_status"] == "proposed" end)
    end
  end

  describe "execute/2 — error handling" do
    test "nil input returns error" do
      {:error, error} = Engine.execute(nil, @finance_context)
      assert error.code == :invalid_input
    end

    test "integer input returns error" do
      {:error, error} = Engine.execute(123, @finance_context)
      assert error.code == :invalid_input
    end
  end

  describe "Planner" do
    test "plans resolve to Grafeo adapter" do
      ast = %Cqr.Resolve{entity: {"finance", "arr"}}
      {:ok, plan} = Cqr.Engine.Planner.plan(ast)
      assert [{Cqr.Adapter.Grafeo, :resolve}] = plan
    end

    test "plans discover to Grafeo adapter" do
      ast = %Cqr.Discover{related_to: {:entity, {"product", "churn_rate"}}}
      {:ok, plan} = Cqr.Engine.Planner.plan(ast)
      assert [{Cqr.Adapter.Grafeo, :discover}] = plan
    end

    test "no adapter for certify returns error" do
      ast = %Cqr.Certify{entity: {"finance", "arr"}, status: :proposed}
      {:error, error} = Cqr.Engine.Planner.plan(ast)
      assert error.code == :no_adapter
    end

    test "multi-adapter planning with mock" do
      defmodule MockAdapter do
        @behaviour Cqr.Adapter.Behaviour
        def capabilities, do: [:resolve]

        def resolve(_, _, _),
          do: {:ok, %Cqr.Result{data: [%{source: "mock"}], sources: ["mock"]}}

        def discover(_, _, _), do: {:error, :not_supported}
        def normalize(r, _), do: r
        def health_check, do: :ok
      end

      ast = %Cqr.Resolve{entity: {"finance", "arr"}}
      {:ok, plan} = Cqr.Engine.Planner.plan(ast, adapters: [Cqr.Adapter.Grafeo, MockAdapter])
      assert length(plan) == 2
    end
  end

  describe "result merging — conflict preservation" do
    test "multi-adapter results are merged with conflict detection" do
      defmodule ConflictMockAdapter do
        @behaviour Cqr.Adapter.Behaviour
        def capabilities, do: [:resolve]

        def resolve(_, _, _) do
          {:ok,
           %Cqr.Result{
             data: [%{namespace: "finance", name: "arr", value: 999}],
             sources: ["mock_db"]
           }}
        end

        def discover(_, _, _), do: {:error, :not_supported}
        def normalize(r, _), do: r
        def health_check, do: :ok
      end

      ast = %Cqr.Resolve{entity: {"finance", "arr"}}

      {:ok, result} =
        Engine.execute(ast, %{
          scope: ["company", "finance"],
          adapters: [Cqr.Adapter.Grafeo, ConflictMockAdapter]
        })

      # Both sources should be represented
      assert "grafeo" in result.sources
      assert "mock_db" in result.sources
      assert length(result.data) >= 2
    end
  end
end
