defmodule Cqr.Parser.CertifyTest do
  use ExUnit.Case, async: true

  alias Cqr.Parser

  describe "CERTIFY — minimal" do
    test "entity with status proposed" do
      {:ok, result} =
        Parser.parse("CERTIFY entity:finance:arr STATUS proposed")

      assert result.entity == {"finance", "arr"}
      assert result.status == :proposed
    end

    test "status under_review" do
      {:ok, result} =
        Parser.parse("CERTIFY entity:finance:arr STATUS under_review")

      assert result.status == :under_review
    end

    test "status certified" do
      {:ok, result} =
        Parser.parse("CERTIFY entity:finance:arr STATUS certified")

      assert result.status == :certified
    end

    test "status superseded" do
      {:ok, result} =
        Parser.parse("CERTIFY entity:finance:arr STATUS superseded")

      assert result.status == :superseded
    end
  end

  describe "CERTIFY — AUTHORITY clause" do
    test "simple authority" do
      {:ok, result} =
        Parser.parse("CERTIFY entity:finance:arr STATUS proposed AUTHORITY cfo")

      assert result.authority == "cfo"
    end

    test "authority with underscores" do
      {:ok, result} =
        Parser.parse("CERTIFY entity:finance:arr STATUS proposed AUTHORITY finance_team")

      assert result.authority == "finance_team"
    end
  end

  describe "CERTIFY — SUPERSEDES clause" do
    test "supersedes another entity" do
      {:ok, result} =
        Parser.parse(
          "CERTIFY entity:finance:arr STATUS proposed SUPERSEDES entity:finance:arr_legacy"
        )

      assert result.supersedes == {"finance", "arr_legacy"}
    end
  end

  describe "CERTIFY — EVIDENCE clause" do
    test "simple evidence" do
      {:ok, result} =
        Parser.parse(
          ~s(CERTIFY entity:finance:arr STATUS proposed EVIDENCE "Validated against Q4 actuals")
        )

      assert result.evidence == "Validated against Q4 actuals"
    end

    test "evidence with special characters" do
      {:ok, result} =
        Parser.parse(
          ~s(CERTIFY entity:finance:arr STATUS proposed EVIDENCE "Source: SAP ERP, validated 2026-04-01")
        )

      assert result.evidence == "Source: SAP ERP, validated 2026-04-01"
    end

    test "empty evidence" do
      {:ok, result} =
        Parser.parse(~s(CERTIFY entity:finance:arr STATUS proposed EVIDENCE ""))

      assert result.evidence == ""
    end
  end

  describe "CERTIFY — full expressions" do
    test "all clauses in canonical order" do
      {:ok, result} =
        Parser.parse(
          ~s(CERTIFY entity:finance:arr STATUS proposed AUTHORITY cfo SUPERSEDES entity:finance:arr_legacy EVIDENCE "Validated against Q4 actuals")
        )

      assert result.entity == {"finance", "arr"}
      assert result.status == :proposed
      assert result.authority == "cfo"
      assert result.supersedes == {"finance", "arr_legacy"}
      assert result.evidence == "Validated against Q4 actuals"
    end
  end

  describe "CERTIFY — order-insensitive clauses" do
    test "AUTHORITY before STATUS" do
      {:ok, result} =
        Parser.parse("CERTIFY entity:finance:arr AUTHORITY cfo STATUS proposed")

      assert result.authority == "cfo"
      assert result.status == :proposed
    end

    test "EVIDENCE before AUTHORITY" do
      {:ok, result} =
        Parser.parse(~s(CERTIFY entity:finance:arr STATUS proposed EVIDENCE "test" AUTHORITY cfo))

      assert result.evidence == "test"
      assert result.authority == "cfo"
    end

    test "SUPERSEDES before STATUS" do
      {:ok, result} =
        Parser.parse(
          "CERTIFY entity:finance:arr SUPERSEDES entity:finance:arr_legacy STATUS proposed"
        )

      assert result.supersedes == {"finance", "arr_legacy"}
      assert result.status == :proposed
    end

    test "all clauses in reverse order" do
      {:ok, result} =
        Parser.parse(
          ~s(CERTIFY entity:finance:arr EVIDENCE "test" SUPERSEDES entity:finance:old AUTHORITY admin STATUS certified)
        )

      assert result.evidence == "test"
      assert result.supersedes == {"finance", "old"}
      assert result.authority == "admin"
      assert result.status == :certified
    end
  end

  describe "CERTIFY — nil defaults" do
    test "optional fields are nil when absent" do
      {:ok, result} = Parser.parse("CERTIFY entity:finance:arr STATUS proposed")
      assert result.authority == nil
      assert result.supersedes == nil
      assert result.evidence == nil
    end
  end
end
