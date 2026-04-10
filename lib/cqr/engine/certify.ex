defmodule Cqr.Engine.Certify do
  @moduledoc """
  CERTIFY execution path.

  Manages the governance lifecycle: proposed → under_review → certified → superseded.
  Writes audit records to Grafeo and triggers scope tree cache invalidation.
  """

  alias Cqr.Grafeo.Server, as: GrafeoServer

  @valid_transitions %{
    nil => [:proposed],
    :proposed => [:under_review, :superseded],
    :under_review => [:certified, :proposed, :superseded],
    :certified => [:superseded],
    :superseded => []
  }

  @doc """
  Execute a CERTIFY operation. Validates the status transition,
  writes the governance record, and returns the result.
  """
  def execute(%Cqr.Certify{} = certify, context) do
    entity = certify.entity
    new_status = certify.status
    agent_id = context[:agent_id] || "anonymous"

    with {:ok, current_status} <- get_current_status(entity),
         :ok <- validate_transition(current_status, new_status),
         :ok <- write_governance_record(certify, agent_id),
         :ok <- update_entity_status(entity, new_status, certify) do
      result = %Cqr.Result{
        data: [
          %{
            entity: entity,
            previous_status: current_status,
            new_status: new_status,
            authority: certify.authority,
            evidence: certify.evidence,
            agent: agent_id
          }
        ],
        sources: ["grafeo"],
        quality: %Cqr.Quality{
          owner: certify.authority || agent_id,
          certified_by: if(new_status == :certified, do: certify.authority),
          provenance: "CERTIFY operation by #{agent_id}"
        }
      }

      # Invalidate scope tree cache if a scope-level entity changed
      if certify.supersedes do
        Cqr.Repo.ScopeTree.reload()
      end

      {:ok, result}
    end
  end

  defp get_current_status({ns, name}) do
    case GrafeoServer.query(
           "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}) " <>
             "RETURN e.certification_status"
         ) do
      {:ok, [%{"e.certification_status" => status}]} when is_binary(status) ->
        {:ok, String.to_existing_atom(status)}

      {:ok, [%{"e.certification_status" => nil}]} ->
        {:ok, nil}

      {:ok, [_row]} ->
        {:ok, nil}

      {:ok, []} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, %Cqr.Error{code: :adapter_error, message: "Grafeo error: #{inspect(reason)}"}}
    end
  end

  defp validate_transition(current, new_status) do
    allowed = Map.get(@valid_transitions, current, [])

    if new_status in allowed do
      :ok
    else
      {:error,
       %Cqr.Error{
         code: :invalid_transition,
         message: "Cannot transition from #{inspect(current)} to #{inspect(new_status)}",
         suggestions: Enum.map(allowed, fn s -> "Valid transitions: #{inspect(s)}" end),
         retry_guidance:
           "Current status is #{inspect(current)}. Valid next states: #{inspect(allowed)}"
       }}
    end
  end

  defp write_governance_record(%Cqr.Certify{} = certify, agent_id) do
    {ns, name} = certify.entity
    evidence = escape(certify.evidence || "")
    authority = certify.authority || agent_id

    query =
      "INSERT (:GovernanceRecord {" <>
        "entity_namespace: '#{ns}', entity_name: '#{name}', " <>
        "status: '#{certify.status}', authority: '#{authority}', " <>
        "agent: '#{agent_id}', evidence: '#{evidence}', " <>
        "timestamp: '#{DateTime.utc_now() |> DateTime.to_iso8601()}'" <>
        "})"

    case GrafeoServer.query(query) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, %Cqr.Error{code: :adapter_error, message: "#{reason}"}}
    end
  end

  defp update_entity_status({ns, name}, new_status, certify) do
    authority = certify.authority || ""

    query =
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}) " <>
        "SET e.certification_status = '#{new_status}', " <>
        "e.certified = #{new_status == :certified}, " <>
        "e.certified_by = '#{authority}'"

    case GrafeoServer.query(query) do
      {:ok, _} ->
        # Handle supersedes: mark the old entity as superseded
        if certify.supersedes do
          {old_ns, old_name} = certify.supersedes

          GrafeoServer.query(
            "MATCH (e:Entity {namespace: '#{old_ns}', name: '#{old_name}'}) " <>
              "SET e.certification_status = 'superseded'"
          )
        end

        :ok

      {:error, reason} ->
        {:error, %Cqr.Error{code: :adapter_error, message: "#{reason}"}}
    end
  end

  defp escape(str) when is_binary(str), do: String.replace(str, "'", "\\'")
  defp escape(_), do: ""
end
