ExUnit.start()

defmodule CrfController.TestFixtures do
  alias CrfController.PeerIdentity

  @gib 1024 * 1024 * 1024

  def peer(node_id) do
    {:ok, peer} = PeerIdentity.from_authenticated_certificate(node_id, "certificate-" <> node_id)
    peer
  end

  def registration(node_id, generation, os, backend, message_id) do
    node = %{
      "node_id" => node_id,
      "generation" => generation,
      "os" => Atom.to_string(os),
      "arch" => "x86_64",
      "execution_backends" => [Atom.to_string(backend)],
      "capabilities" => ["github-actions", "x64"],
      "total" => %{"cpu_millis" => 8_000, "memory_bytes" => 16 * @gib},
      "available" => %{"cpu_millis" => 8_000, "memory_bytes" => 16 * @gib},
      "draining" => false
    }

    envelope(node_id, generation, message_id, %{
      "type" => "register",
      "node" => node,
      "agent_version" => "0.1.0"
    })
  end

  def heartbeat(node_id, generation, message_id, cpu_millis, memory_bytes, active_placements) do
    envelope(node_id, generation, message_id, %{
      "type" => "heartbeat",
      "available" => %{"cpu_millis" => cpu_millis, "memory_bytes" => memory_bytes},
      "active_placements" => active_placements
    })
  end

  def command_ack(node_id, generation, message_id, command_id, idempotency_key, status) do
    envelope(node_id, generation, message_id, %{
      "type" => "command_ack",
      "command_id" => command_id,
      "idempotency_key" => idempotency_key,
      "status" => Atom.to_string(status),
      "detail_code" => :null
    })
  end

  def placement_update(node_id, generation, message_id, placement_id, command_id, state) do
    envelope(node_id, generation, message_id, %{
      "type" => "placement_update",
      "placement_id" => placement_id,
      "command_id" => command_id,
      "state" => Atom.to_string(state),
      "detail_code" => :null
    })
  end

  def placement_attrs(node_id, generation) do
    %{
      id: "placement-1",
      command_id: "command-1",
      idempotency_key: "idempotency-1",
      node_id: node_id,
      node_generation: generation,
      work_id: "work-1",
      pool_id: "build",
      resources: %{cpu_millis: 2_000, memory_bytes: 4 * @gib}
    }
  end

  def decode_json(binary), do: :json.decode(binary)

  defp envelope(node_id, generation, message_id, payload) do
    :json.encode(%{
      "protocol_version" => 1,
      "message_id" => message_id,
      "node_id" => node_id,
      "node_generation" => generation,
      "sent_at_unix_ms" => 1_787_070_000_000,
      "payload" => payload
    })
    |> IO.iodata_to_binary()
  end
end
