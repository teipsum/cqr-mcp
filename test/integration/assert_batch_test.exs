defmodule Cqr.Integration.AssertBatchTest do
  @moduledoc """
  Integration tests for the cqr_assert_batch MCP tool.

  Exercises the happy path (all created), mixed success/skip/failure,
  and invalid-input cases. Each test uses a unique namespace suffix to
  avoid collisions in the shared in-process Grafeo.
  """

  use ExUnit.Case

  alias CqrMcp.Tools

  @product_context %{scope: ["company", "product"], agent_id: "twin:batch"}

  defp entity(name, opts \\ []) do
    %{
      "entity" => "entity:test_batch:#{name}",
      "type" => "derived_metric",
      "description" => "Batch test #{name}",
      "intent" => "Testing cqr_assert_batch",
      "derived_from" => Keyword.get(opts, :derived_from, "entity:product:churn_rate")
    }
  end

  describe "cqr_assert_batch — success" do
    test "asserts every entity in the batch and reports per-entity results" do
      args = %{
        "entities" => [
          entity("b1_first"),
          entity("b1_second"),
          entity("b1_third")
        ]
      }

      assert {:ok, summary} = Tools.call("cqr_assert_batch", args, @product_context)

      assert %{
               "total" => 3,
               "created" => 3,
               "skipped" => 0,
               "failed" => 0,
               "results" => results
             } = summary

      assert [
               %{"entity" => "entity:test_batch:b1_first", "status" => "created"},
               %{"entity" => "entity:test_batch:b1_second", "status" => "created"},
               %{"entity" => "entity:test_batch:b1_third", "status" => "created"}
             ] = results

      # Each created entry carries the formatted CQR result payload.
      assert %{"data" => [%{"name" => "b1_first"}]} = hd(results)["data"]
    end

    test "optional confidence is honored per entity" do
      args = %{
        "entities" => [
          Map.put(entity("b2_conf"), "confidence", 0.9)
        ]
      }

      assert {:ok, %{"created" => 1, "results" => [result]}} =
               Tools.call("cqr_assert_batch", args, @product_context)

      assert %{"data" => [%{"confidence" => 0.9}]} = result["data"]
    end
  end

  describe "cqr_assert_batch — partial failure" do
    test "one failure does not prevent others from being asserted" do
      # Pre-create one entity so the second item in the batch is a duplicate.
      assert {:ok, %{"created" => 1}} =
               Tools.call(
                 "cqr_assert_batch",
                 %{"entities" => [entity("b3_dup")]},
                 @product_context
               )

      args = %{
        "entities" => [
          # created
          entity("b3_fresh"),
          # skipped — entity_exists
          entity("b3_dup"),
          # failed — derived_from does not exist
          entity("b3_bad_lineage", derived_from: "entity:product:does_not_exist"),
          # failed — missing required field (no intent)
          Map.delete(entity("b3_no_intent"), "intent"),
          # created
          entity("b3_also_fresh")
        ]
      }

      assert {:ok, summary} = Tools.call("cqr_assert_batch", args, @product_context)

      assert %{
               "total" => 5,
               "created" => 2,
               "skipped" => 1,
               "failed" => 2,
               "results" => [
                 %{"entity" => "entity:test_batch:b3_fresh", "status" => "created"},
                 %{"entity" => "entity:test_batch:b3_dup", "status" => "skipped"},
                 %{
                   "entity" => "entity:test_batch:b3_bad_lineage",
                   "status" => "failed",
                   "error" => bad_lineage_err
                 },
                 %{
                   "entity" => "entity:test_batch:b3_no_intent",
                   "status" => "failed",
                   "error" => missing_intent_err
                 },
                 %{"entity" => "entity:test_batch:b3_also_fresh", "status" => "created"}
               ]
             } = summary

      assert bad_lineage_err =~ "does_not_exist"
      assert missing_intent_err =~ "intent"
    end
  end

  describe "cqr_assert_batch — invalid input" do
    test "missing entities key returns JSON-RPC error" do
      assert {:error, %{"code" => -32_602, "message" => msg}} =
               Tools.call("cqr_assert_batch", %{}, @product_context)

      assert msg =~ "entities"
    end

    test "empty entities array returns JSON-RPC error" do
      assert {:error, %{"code" => -32_602, "message" => msg}} =
               Tools.call("cqr_assert_batch", %{"entities" => []}, @product_context)

      assert msg =~ "non-empty"
    end

    test "non-object entity entry is recorded as failed without halting the batch" do
      args = %{
        "entities" => [
          entity("b4_ok"),
          "not-an-object",
          entity("b4_also_ok")
        ]
      }

      assert {:ok,
              %{
                "total" => 3,
                "created" => 2,
                "failed" => 1,
                "results" => [
                  %{"status" => "created"},
                  %{"entity" => "<invalid>", "status" => "failed"},
                  %{"status" => "created"}
                ]
              }} = Tools.call("cqr_assert_batch", args, @product_context)
    end
  end
end
