defmodule Cqr.Engine.Certify do
  @moduledoc """
  CERTIFY execution path.

  Manages the governance lifecycle: proposed -> under_review -> certified ->
  (contested -> under_review | superseded -> proposed).

  Each phase transition:

    * validates scope access and the transition itself,
    * writes an immutable `CertificationRecord` node with a UUIDv4 `record_id`,
    * attaches a `CERTIFICATION_EVENT` edge from the entity to the record
      (mirroring the `ASSERTED_BY` pattern for `AssertionRecord`),
    * updates the entity node's certification fields and reputation, and
    * triggers scope tree cache invalidation when a scope-level entity changed.

  The chain of `CertificationRecord` nodes per entity is the immutable provenance
  trail the patent describes — every status change is auditable after the fact.
  """

  alias Cqr.Grafeo.Codec
  alias Cqr.Grafeo.Gql
  alias Cqr.Grafeo.Server, as: GrafeoServer
  alias Cqr.Repo.ScopeTree
  alias Cqr.Repo.Semantic

  @valid_transitions %{
    nil => [:proposed],
    :proposed => [:under_review, :superseded],
    :under_review => [:certified, :proposed, :superseded],
    :certified => [:contested, :superseded],
    :contested => [:under_review],
    :superseded => [:proposed]
  }

  @doc """
  Execute a CERTIFY operation.

  Fetches the entity (respecting scope visibility), validates the transition,
  writes the audit record and event edge, updates the entity node, and
  returns a quality-annotated `%Cqr.Result{}`.
  """
  def execute(%Cqr.Certify{} = certify, context) do
    entity = certify.entity
    new_status = certify.status
    agent_id = Map.get(context, :agent_id, "anonymous")
    visible = Map.get(context, :visible_scopes, [])
    now = DateTime.utc_now()

    with {:ok, entity_data} <- fetch_visible_entity(entity, visible),
         current_status <- atomize_status(entity_data[:certification_status]),
         :ok <- validate_transition(current_status, new_status),
         {:ok, record_id} <- generate_record_id(),
         new_reputation <- compute_new_reputation(entity_data, new_status),
         :ok <-
           write_certification_record(certify, agent_id, record_id, current_status, now),
         :ok <- write_certification_event_edge(entity, record_id),
         :ok <- update_entity_node(entity, new_status, certify, new_reputation, now),
         :ok <- maybe_handle_supersedes(certify) do
      if certify.supersedes do
        ScopeTree.reload()
      end

      {:ok, build_result(certify, agent_id, current_status, new_reputation, now)}
    end
  end

  # --- Scope + transition validation ---

  defp fetch_visible_entity(entity, visible) do
    case Semantic.get_entity(entity, visible) do
      {:ok, data} ->
        {:ok, data}

      {:error, :not_found} ->
        {:error,
         Cqr.Error.entity_not_found(Cqr.Types.format_entity(entity),
           similar: []
         )}

      {:error, :not_visible} ->
        {:error,
         Cqr.Error.entity_not_found(Cqr.Types.format_entity(entity),
           similar: []
         )}

      {:error, reason} ->
        {:error, %Cqr.Error{code: :adapter_error, message: "Grafeo error: #{inspect(reason)}"}}
    end
  end

  # certification_status lives as a string on the entity node. Convert
  # to the atom form used by @valid_transitions. Safe because the only
  # writers of this field are this module and the seed path, both of
  # which constrain values to the known statuses.
  defp atomize_status(nil), do: nil
  defp atomize_status(status) when is_atom(status), do: status

  defp atomize_status(status) when is_binary(status) do
    String.to_existing_atom(status)
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

  # --- Reputation policy ---

  defp compute_new_reputation(entity_data, new_status) do
    current = entity_data[:reputation] || 0.5
    adjust_reputation(new_status, current)
  end

  defp adjust_reputation(:certified, current), do: max(current, 0.9)
  defp adjust_reputation(:superseded, current), do: min(current, 0.3)
  defp adjust_reputation(:contested, current), do: current
  defp adjust_reputation(_, current), do: current

  # --- Audit record writes ---

  # RFC 4122 UUIDv4. Mirrors the generator in `Cqr.Adapter.Grafeo` (used for
  # AssertionRecord IDs) so each CertificationRecord has a stable identity
  # we can MATCH against for the CERTIFICATION_EVENT edge. Kept local to
  # avoid a cross-module call into the adapter for what's really a util.
  defp generate_record_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    uuid =
      :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
      |> IO.iodata_to_binary()

    {:ok, uuid}
  end

  defp write_certification_record(
         %Cqr.Certify{} = certify,
         agent_id,
         record_id,
         previous_status,
         now
       ) do
    {ns, name} = certify.entity
    timestamp = DateTime.to_iso8601(now)
    previous = if previous_status, do: to_string(previous_status), else: ""
    authority = certify.authority || ""
    evidence = certify.evidence || ""

    query =
      "INSERT (:CertificationRecord {" <>
        "record_id: '#{record_id}', " <>
        "entity_namespace: '#{ns}', entity_name: '#{name}', " <>
        "previous_status: '#{previous}', " <>
        "new_status: '#{certify.status}', " <>
        "agent_id: '#{escape(agent_id)}', " <>
        "authority: '#{Codec.encode(authority)}', " <>
        "evidence: '#{Codec.encode(evidence)}', " <>
        "timestamp: '#{timestamp}'" <>
        "})"

    exec_write(query)
  end

  defp write_certification_event_edge({ns, name}, record_id) do
    query =
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}), " <>
        "(r:CertificationRecord {record_id: '#{record_id}'}) " <>
        "INSERT (e)-[:CERTIFICATION_EVENT]->(r)"

    exec_write(query)
  end

  # --- Entity node update ---

  defp update_entity_node({ns, name}, new_status, certify, new_reputation, now) do
    timestamp = DateTime.to_iso8601(now)

    base_sets = [
      "e.certification_status = '#{new_status}'",
      "e.certified = #{new_status == :certified}",
      "e.reputation = #{new_reputation}"
    ]

    sets = base_sets ++ certified_at_by_sets(new_status, certify, timestamp)

    query =
      "MATCH (e:Entity {namespace: '#{ns}', name: '#{name}'}) SET " <>
        Enum.join(sets, ", ")

    exec_write(query)
  end

  # Only stamp certified_at/certified_by when transitioning INTO :certified.
  # For :proposed, :under_review, or :superseded we leave any existing
  # certification stamp untouched (superseded entities retain their history).
  defp certified_at_by_sets(:certified, %Cqr.Certify{} = certify, timestamp) do
    authority = certify.authority || ""

    [
      "e.certified_by = '#{Codec.encode(authority)}'",
      "e.certified_at = '#{timestamp}'"
    ]
  end

  defp certified_at_by_sets(_status, _certify, _timestamp), do: []

  # --- Supersedes handling (separate entity) ---

  defp maybe_handle_supersedes(%Cqr.Certify{supersedes: nil}), do: :ok

  defp maybe_handle_supersedes(%Cqr.Certify{supersedes: {old_ns, old_name}}) do
    query =
      "MATCH (e:Entity {namespace: '#{old_ns}', name: '#{old_name}'}) " <>
        "SET e.certification_status = 'superseded', " <>
        "e.certified = false, " <>
        "e.reputation = 0.3"

    exec_write(query)
  end

  # --- Result assembly ---

  defp build_result(
         %Cqr.Certify{} = certify,
         agent_id,
         previous_status,
         new_reputation,
         now
       ) do
    %Cqr.Result{
      data: [
        %{
          entity: certify.entity,
          previous_status: previous_status,
          new_status: certify.status,
          authority: certify.authority,
          evidence: certify.evidence,
          agent: agent_id
        }
      ],
      sources: ["grafeo"],
      quality: %Cqr.Quality{
        freshness: now,
        reputation: new_reputation,
        owner: certify.authority || agent_id,
        provenance: "CERTIFY operation by #{agent_id}",
        certified_by:
          if(certify.status == :certified, do: certify.authority || agent_id, else: nil),
        certified_at: if(certify.status == :certified, do: now, else: nil)
      }
    }
  end

  # --- Low-level write helper ---

  defp exec_write(query) do
    case GrafeoServer.query(query) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error,
         %Cqr.Error{
           code: :adapter_error,
           message: "Grafeo write failed: #{inspect(reason)}"
         }}
    end
  end

  # Delegates to the shared escape. The previous single-quote-only
  # implementation wrote malformed CertificationRecord nodes for any
  # entity whose authority or evidence carried a backslash, newline, or
  # control byte — and those malformed writes were the root cause of
  # the patent-agent UPDATE hang reported in feature/fix-nif-hang-v2.
  defp escape(value), do: Gql.escape(value)
end
