defmodule CrfController.Wire do
  alias CrfController.{Identifier, NodeCommand, PeerIdentity, Resources}

  @protocol_version 1
  @max_wire_message_bytes 256 * 1024
  @max_active_placements 1024
  @envelope_keys MapSet.new([
                   "protocol_version",
                   "message_id",
                   "node_id",
                   "node_generation",
                   "sent_at_unix_ms",
                   "payload"
                 ])

  def protocol_version, do: @protocol_version
  def max_wire_message_bytes, do: @max_wire_message_bytes

  @spec decode_node_envelope(binary(), PeerIdentity.t()) :: {:ok, map()} | {:error, atom()}
  def decode_node_envelope(binary, %PeerIdentity{} = peer)
      when is_binary(binary) and byte_size(binary) > 0 and
             byte_size(binary) <= @max_wire_message_bytes do
    with {:ok, envelope} <- decode_json(binary),
         :ok <- exact_keys(envelope, @envelope_keys),
         :ok <- protocol_version(envelope),
         {:ok, message_id} <- identifier(envelope["message_id"], :invalid_message_id),
         {:ok, node_id} <- identifier(envelope["node_id"], :invalid_node_id),
         :ok <- authenticated_identity(node_id, peer),
         {:ok, generation} <- positive_integer(envelope["node_generation"], :invalid_generation),
         {:ok, sent_at_unix_ms} <-
           positive_integer(envelope["sent_at_unix_ms"], :invalid_timestamp),
         {:ok, payload} <- parse_payload(envelope["payload"], node_id, generation) do
      {:ok,
       %{
         protocol_version: @protocol_version,
         message_id: message_id,
         node_id: node_id,
         node_generation: generation,
         sent_at_unix_ms: sent_at_unix_ms,
         payload: payload
       }}
    end
  end

  def decode_node_envelope(binary, %PeerIdentity{}) when is_binary(binary),
    do: {:error, :message_too_large}

  def decode_node_envelope(_, _), do: {:error, :invalid_transport_input}

  @spec encode_response(String.t(), :accepted | :duplicate | :rejected, atom() | nil) ::
          {:ok, binary()} | {:error, atom()}
  def encode_response(message_id, status, code \\ nil) do
    encode_response(message_id, status, code, nil, System.system_time(:millisecond))
  end

  @spec encode_response(
          String.t(),
          :accepted | :duplicate | :rejected,
          atom() | nil,
          NodeCommand.t() | nil,
          non_neg_integer()
        ) :: {:ok, binary()} | {:error, atom()}
  def encode_response(message_id, status, code, command, now_unix_ms) do
    with {:ok, message_id} <- identifier(message_id, :invalid_message_id),
         true <- status in [:accepted, :duplicate, :rejected],
         {:ok, code} <- response_code(code),
         {:ok, command} <- response_command(command, now_unix_ms) do
      json = %{
        "protocol_version" => @protocol_version,
        "message_id" => message_id,
        "status" => Atom.to_string(status),
        "code" => if(is_nil(code), do: :null, else: code),
        "command" => command
      }

      encoded = :json.encode(json) |> IO.iodata_to_binary()

      if byte_size(encoded) <= @max_wire_message_bytes,
        do: {:ok, encoded},
        else: {:error, :message_too_large}
    else
      false -> {:error, :invalid_response_status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_payload(%{"type" => "register"} = payload, node_id, generation) do
    with :ok <- exact_keys(payload, MapSet.new(["type", "node", "agent_version"])),
         {:ok, node} <- parse_node(payload["node"]),
         true <- node.id == node_id and node.generation == generation,
         {:ok, agent_version} <- agent_version(payload["agent_version"]) do
      {:ok, {:register, node, agent_version}}
    else
      false -> {:error, :identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_payload(%{"type" => "heartbeat"} = payload, _node_id, _generation) do
    with :ok <- exact_keys(payload, MapSet.new(["type", "available", "active_placements"])),
         {:ok, available} <- resources(payload["available"], false),
         {:ok, active} <- identifiers(payload["active_placements"], @max_active_placements) do
      {:ok, {:heartbeat, available, MapSet.new(active)}}
    end
  end

  defp parse_payload(%{"type" => "command_ack"} = payload, _node_id, _generation) do
    with :ok <-
           exact_keys(
             payload,
             MapSet.new(["type", "command_id", "idempotency_key", "status", "detail_code"])
           ),
         {:ok, command_id} <- identifier(payload["command_id"], :invalid_command_id),
         {:ok, idempotency_key} <-
           identifier(payload["idempotency_key"], :invalid_idempotency_key),
         {:ok, status} <- command_ack_status(payload["status"]),
         {:ok, detail_code} <- detail_code(payload["detail_code"]) do
      {:ok, {:command_ack, command_id, idempotency_key, status, detail_code}}
    end
  end

  defp parse_payload(%{"type" => "placement_update"} = payload, _node_id, _generation) do
    with :ok <-
           exact_keys(
             payload,
             MapSet.new(["type", "placement_id", "command_id", "state", "detail_code"])
           ),
         {:ok, placement_id} <- identifier(payload["placement_id"], :invalid_placement_id),
         {:ok, command_id} <- identifier(payload["command_id"], :invalid_command_id),
         {:ok, state} <- placement_state(payload["state"]),
         {:ok, detail_code} <- detail_code(payload["detail_code"]) do
      {:ok, {:placement_update, placement_id, command_id, state, detail_code}}
    end
  end

  defp parse_payload(_, _node_id, _generation), do: {:error, :invalid_payload}

  defp parse_node(node) when is_map(node) do
    keys =
      MapSet.new([
        "node_id",
        "generation",
        "os",
        "arch",
        "execution_backends",
        "capabilities",
        "total",
        "available",
        "draining"
      ])

    with :ok <- exact_keys(node, keys),
         {:ok, id} <- identifier(node["node_id"], :invalid_node_id),
         {:ok, generation} <- positive_integer(node["generation"], :invalid_generation),
         {:ok, os} <- operating_system(node["os"]),
         {:ok, arch} <- architecture(node["arch"]),
         {:ok, backends} <- execution_backends(node["execution_backends"]),
         {:ok, capabilities} <- identifiers(node["capabilities"], 256),
         {:ok, total} <- resources(node["total"], true),
         {:ok, available} <- resources(node["available"], false),
         true <- Resources.fits?(total, available),
         {:ok, draining} <- boolean(node["draining"], :invalid_draining) do
      {:ok,
       %{
         id: id,
         generation: generation,
         os: os,
         arch: arch,
         execution_backends: backends,
         capabilities: capabilities,
         total: total,
         available: available,
         draining: draining
       }}
    else
      false -> {:error, :available_exceeds_total}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_node(_), do: {:error, :invalid_node}

  defp resources(%{"cpu_millis" => cpu, "memory_bytes" => memory} = value, positive?)
       when map_size(value) == 2 do
    with true <- is_integer(cpu) and cpu >= 0 and is_integer(memory) and memory >= 0,
         true <- not positive? or (cpu > 0 and memory > 0),
         {:ok, resources} <- Resources.new(%{cpu_millis: cpu, memory_bytes: memory}) do
      {:ok, resources}
    else
      _ -> {:error, :invalid_resources}
    end
  end

  defp resources(_, _), do: {:error, :invalid_resources}

  defp exact_keys(value, expected) when is_map(value) do
    if Map.keys(value) |> MapSet.new() |> MapSet.equal?(expected),
      do: :ok,
      else: {:error, :unexpected_fields}
  end

  defp protocol_version(%{"protocol_version" => @protocol_version}), do: :ok
  defp protocol_version(_), do: {:error, :unsupported_protocol_version}

  defp authenticated_identity(node_id, %PeerIdentity{node_id: node_id}), do: :ok
  defp authenticated_identity(_, _), do: {:error, :authenticated_identity_mismatch}

  defp identifier(value, error) do
    if Identifier.valid?(value), do: {:ok, value}, else: {:error, error}
  end

  defp identifiers(values, max) when is_list(values) and length(values) <= max do
    if Enum.all?(values, &Identifier.valid?/1) and
         MapSet.size(MapSet.new(values)) == length(values),
       do: {:ok, values},
       else: {:error, :invalid_identifier_list}
  end

  defp identifiers(_, _), do: {:error, :invalid_identifier_list}

  defp positive_integer(value, _error) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_, error), do: {:error, error}

  defp boolean(value, _error) when is_boolean(value), do: {:ok, value}
  defp boolean(_, error), do: {:error, error}

  defp operating_system("linux"), do: {:ok, :linux}
  defp operating_system("windows"), do: {:ok, :windows}
  defp operating_system("macos"), do: {:ok, :macos}
  defp operating_system("other"), do: {:ok, :other}
  defp operating_system(_), do: {:error, :invalid_os}

  defp architecture("x86_64"), do: {:ok, :x86_64}
  defp architecture("arm64"), do: {:ok, :arm64}
  defp architecture("other"), do: {:ok, :other}
  defp architecture(_), do: {:error, :invalid_arch}

  defp execution_backends(values) when is_list(values) and values != [] do
    converted = Enum.map(values, &execution_backend/1)

    if Enum.all?(converted, &match?({:ok, _}, &1)) do
      backends = Enum.map(converted, fn {:ok, value} -> value end)

      if MapSet.size(MapSet.new(backends)) == length(backends),
        do: {:ok, backends},
        else: {:error, :invalid_execution_backends}
    else
      {:error, :invalid_execution_backends}
    end
  end

  defp execution_backends(_), do: {:error, :invalid_execution_backends}

  defp execution_backend("container"), do: {:ok, :container}
  defp execution_backend("native_process"), do: {:ok, :native_process}
  defp execution_backend("virtual_machine"), do: {:ok, :virtual_machine}
  defp execution_backend(_), do: :error

  defp command_ack_status("accepted"), do: {:ok, :accepted}
  defp command_ack_status("duplicate"), do: {:ok, :duplicate}
  defp command_ack_status("rejected"), do: {:ok, :rejected}
  defp command_ack_status(_), do: {:error, :invalid_ack_status}

  defp placement_state("accepted"), do: {:ok, :accepted}
  defp placement_state("starting"), do: {:ok, :starting}
  defp placement_state("observed"), do: {:ok, :observed}
  defp placement_state("running"), do: {:ok, :running}
  defp placement_state("finished"), do: {:ok, :finished}
  defp placement_state("failed"), do: {:ok, :failed}
  defp placement_state("cancelled"), do: {:ok, :cancelled}
  defp placement_state(_), do: {:error, :invalid_placement_state}

  defp detail_code(:null), do: {:ok, nil}
  defp detail_code(nil), do: {:ok, nil}
  defp detail_code(value), do: identifier(value, :invalid_detail_code)

  defp response_code(nil), do: {:ok, nil}

  defp response_code(code) when is_atom(code),
    do: identifier(Atom.to_string(code), :invalid_response_code)

  defp response_code(_), do: {:error, :invalid_response_code}

  defp response_command(nil, _now_unix_ms), do: {:ok, :null}

  defp response_command(%NodeCommand{} = command, now_unix_ms),
    do: NodeCommand.wire_map(command, now_unix_ms)

  defp response_command(_, _now_unix_ms), do: {:error, :invalid_response_command}

  defp agent_version(value) when is_binary(value) and byte_size(value) in 1..64 do
    if String.to_charlist(value)
       |> Enum.all?(fn char ->
         char in ?0..?9 or char in ?A..?Z or char in ?a..?z or char in ~c".-+"
       end),
       do: {:ok, value},
       else: {:error, :invalid_agent_version}
  end

  defp agent_version(_), do: {:error, :invalid_agent_version}

  defp decode_json(binary) do
    try do
      case :json.decode(binary) do
        value when is_map(value) -> {:ok, value}
        _ -> {:error, :invalid_json_object}
      end
    rescue
      _ -> {:error, :invalid_json}
    end
  end
end
