defmodule CrfController.IngressTest do
  use ExUnit.Case, async: true

  alias CrfController.{
    Ingress,
    NodeCommand,
    NodeMailbox,
    NodeRegistry,
    PlacementLedger,
    Secret,
    TestFixtures
  }

  @now_unix_ms 1_787_070_001_000

  setup do
    registry = start_supervised!({NodeRegistry, name: nil, stale_after_ms: 1_000})
    placements = start_supervised!({PlacementLedger, name: nil})
    mailbox = start_supervised!({NodeMailbox, name: nil, capacity: 16})

    ingress =
      start_supervised!(
        {Ingress,
         name: nil,
         node_registry: registry,
         placement_ledger: placements,
         node_mailbox: mailbox,
         ledger_capacity: 16}
      )

    %{registry: registry, placements: placements, mailbox: mailbox, ingress: ingress}
  end

  test "registration is authenticated and exact replay returns identical response bytes",
       context do
    binary = TestFixtures.registration("dookie", 7, :linux, :container, "message-1")
    peer = TestFixtures.peer("dookie")

    assert {:ok, response} =
             Ingress.ingest(context.ingress, peer, binary,
               now_ms: 10,
               now_unix_ms: @now_unix_ms
             )

    decoded = TestFixtures.decode_json(response)
    assert decoded["status"] == "accepted"
    assert decoded["command"] == :null
    assert [%{id: "dookie", generation: 7}] = NodeRegistry.snapshot(context.registry)

    assert {:ok, replay} =
             Ingress.ingest(context.ingress, peer, binary,
               now_ms: 20,
               now_unix_ms: @now_unix_ms + 1
             )

    assert replay == response
    assert length(NodeRegistry.snapshot(context.registry)) == 1
  end

  test "same message id with changed contents is rejected", context do
    peer = TestFixtures.peer("dookie")
    first = TestFixtures.registration("dookie", 7, :linux, :container, "message-2")
    changed = TestFixtures.registration("dookie", 7, :linux, :native_process, "message-2")

    assert {:ok, _} =
             Ingress.ingest(context.ingress, peer, first,
               now_ms: 10,
               now_unix_ms: @now_unix_ms
             )

    assert {:ok, response} =
             Ingress.ingest(context.ingress, peer, changed,
               now_ms: 20,
               now_unix_ms: @now_unix_ms + 1
             )

    decoded = TestFixtures.decode_json(response)
    assert decoded["status"] == "rejected"
    assert decoded["code"] == "message_id_conflict"
    assert decoded["command"] == :null
  end

  test "heartbeat updates free resources and active placement evidence", context do
    peer = TestFixtures.peer("dookie")
    register = TestFixtures.registration("dookie", 7, :linux, :container, "message-3")

    assert {:ok, _} =
             Ingress.ingest(context.ingress, peer, register,
               now_ms: 10,
               now_unix_ms: @now_unix_ms
             )

    heartbeat = TestFixtures.heartbeat("dookie", 7, "message-4", 0, 0, ["placement-1"])

    assert {:ok, response} =
             Ingress.ingest(context.ingress, peer, heartbeat,
               now_ms: 20,
               now_unix_ms: @now_unix_ms + 1
             )

    decoded = TestFixtures.decode_json(response)
    assert decoded["status"] == "accepted"
    assert decoded["command"] == :null

    [node] = NodeRegistry.snapshot(context.registry)
    assert node.available.cpu_millis == 0
    assert node.available.memory_bytes == 0
    assert node.active_placements == MapSet.new(["placement-1"])
  end

  test "pending command is attached until ACK and exact heartbeat replay is stable", context do
    peer = TestFixtures.peer("dookie")
    register = TestFixtures.registration("dookie", 7, :linux, :container, "message-8")

    assert {:ok, _} =
             Ingress.ingest(context.ingress, peer, register,
               now_ms: 10,
               now_unix_ms: @now_unix_ms
             )

    assert {:ok, placement} =
             PlacementLedger.begin_placement(
               context.placements,
               TestFixtures.placement_attrs("dookie", 7),
               now_ms: 11
             )

    command = start_command(placement)

    assert {:ok, ^command} =
             NodeMailbox.enqueue(context.mailbox, command, now_unix_ms: @now_unix_ms)

    heartbeat = TestFixtures.heartbeat("dookie", 7, "message-9", 6_000, gib(12), [])

    assert {:ok, response} =
             Ingress.ingest(context.ingress, peer, heartbeat,
               now_ms: 20,
               now_unix_ms: @now_unix_ms + 1
             )

    decoded = TestFixtures.decode_json(response)
    assert decoded["command"]["command_id"] == "command-1"
    assert decoded["command"]["payload"]["jit_config"] == "jit-config-abc123=="
    assert NodeMailbox.size(context.mailbox) == 1

    assert {:ok, replay} =
             Ingress.ingest(context.ingress, peer, heartbeat,
               now_ms: 21,
               now_unix_ms: @now_unix_ms + 2
             )

    assert replay == response
    assert NodeMailbox.size(context.mailbox) == 1

    ack =
      TestFixtures.command_ack(
        "dookie",
        7,
        "message-10",
        "command-1",
        "idempotency-1",
        :accepted
      )

    assert {:ok, ack_response} =
             Ingress.ingest(context.ingress, peer, ack,
               now_ms: 30,
               now_unix_ms: @now_unix_ms + 3
             )

    assert TestFixtures.decode_json(ack_response)["command"] == :null
    assert NodeMailbox.size(context.mailbox) == 0
  end

  test "command acknowledgements and placement progress route through the fenced ledger",
       context do
    register_node(context.registry)

    assert {:ok, placement} =
             PlacementLedger.begin_placement(
               context.placements,
               TestFixtures.placement_attrs("dookie", 7),
               now_ms: 10
             )

    command = start_command(placement)

    assert {:ok, ^command} =
             NodeMailbox.enqueue(context.mailbox, command, now_unix_ms: @now_unix_ms)

    peer = TestFixtures.peer("dookie")

    ack =
      TestFixtures.command_ack(
        "dookie",
        7,
        "message-5",
        "command-1",
        "idempotency-1",
        :accepted
      )

    assert {:ok, ack_response} =
             Ingress.ingest(context.ingress, peer, ack,
               now_ms: 20,
               now_unix_ms: @now_unix_ms + 1
             )

    assert TestFixtures.decode_json(ack_response)["status"] == "accepted"
    assert NodeMailbox.size(context.mailbox) == 0

    update =
      TestFixtures.placement_update(
        "dookie",
        7,
        "message-6",
        "placement-1",
        "command-1",
        :running
      )

    assert {:ok, update_response} =
             Ingress.ingest(context.ingress, peer, update,
               now_ms: 30,
               now_unix_ms: @now_unix_ms + 2
             )

    assert TestFixtures.decode_json(update_response)["status"] == "accepted"
    assert {:ok, placement} = PlacementLedger.get(context.placements, "placement-1")
    assert placement.state == :running
  end

  test "placement ledger rejection leaves the prepared command in the mailbox", context do
    register_node(context.registry)

    command =
      TestFixtures.placement_attrs("dookie", 7)
      |> then(fn attrs ->
        {:ok, placement} = CrfController.Placement.new(attrs, 10)
        start_command(placement)
      end)

    assert {:ok, ^command} =
             NodeMailbox.enqueue(context.mailbox, command, now_unix_ms: @now_unix_ms)

    ack =
      TestFixtures.command_ack(
        "dookie",
        7,
        "message-ledger-reject",
        "command-1",
        "idempotency-1",
        :accepted
      )

    assert {:ok, response} =
             Ingress.ingest(context.ingress, TestFixtures.peer("dookie"), ack,
               now_ms: 20,
               now_unix_ms: @now_unix_ms + 1
             )

    decoded = TestFixtures.decode_json(response)
    assert decoded["status"] == "rejected"
    assert decoded["code"] == "unknown_command"
    assert NodeMailbox.size(context.mailbox) == 1

    assert {:ok, ^command} =
             NodeMailbox.next_for(context.mailbox, "dookie", 7, now_unix_ms: @now_unix_ms + 2)
  end

  test "placement generation adoption requires the currently registered node incarnation",
       context do
    register_node_generation(context.registry, 7)

    assert {:ok, _placement} =
             PlacementLedger.begin_placement(
               context.placements,
               TestFixtures.placement_attrs("dookie", 7),
               now_ms: 10
             )

    register_node_generation(context.registry, 8)
    peer = TestFixtures.peer("dookie")

    forged =
      TestFixtures.placement_update(
        "dookie",
        9,
        "message-generation-forged",
        "placement-1",
        "command-1",
        :running
      )

    assert {:ok, forged_response} =
             Ingress.ingest(context.ingress, peer, forged,
               now_ms: 20,
               now_unix_ms: @now_unix_ms
             )

    forged_decoded = TestFixtures.decode_json(forged_response)
    assert forged_decoded["status"] == "rejected"
    assert forged_decoded["code"] == "generation_mismatch"
    assert {:ok, before_adoption} = PlacementLedger.get(context.placements, "placement-1")
    assert before_adoption.node_generation == 7
    assert before_adoption.state == :commanded

    legitimate =
      TestFixtures.placement_update(
        "dookie",
        8,
        "message-generation-legitimate",
        "placement-1",
        "command-1",
        :running
      )

    assert {:ok, accepted_response} =
             Ingress.ingest(context.ingress, peer, legitimate,
               now_ms: 30,
               now_unix_ms: @now_unix_ms + 1
             )

    assert TestFixtures.decode_json(accepted_response)["status"] == "accepted"
    assert {:ok, adopted} = PlacementLedger.get(context.placements, "placement-1")
    assert adopted.node_generation == 8
    assert adopted.state == :running

    stale =
      TestFixtures.placement_update(
        "dookie",
        7,
        "message-generation-stale",
        "placement-1",
        "command-1",
        :finished
      )

    assert {:ok, stale_response} =
             Ingress.ingest(context.ingress, peer, stale,
               now_ms: 40,
               now_unix_ms: @now_unix_ms + 2
             )

    stale_decoded = TestFixtures.decode_json(stale_response)
    assert stale_decoded["status"] == "rejected"
    assert stale_decoded["code"] == "generation_mismatch"
  end

  test "certificate identity mismatch is rejected before mutation", context do
    binary = TestFixtures.registration("dookie", 7, :linux, :container, "message-7")

    assert {:error, :authenticated_identity_mismatch} =
             Ingress.ingest(context.ingress, TestFixtures.peer("steamy"), binary,
               now_ms: 10,
               now_unix_ms: @now_unix_ms
             )

    assert NodeRegistry.snapshot(context.registry) == []
  end

  defp register_node(registry), do: register_node_generation(registry, 7)

  defp register_node_generation(registry, generation) do
    assert {:ok, _node} =
             NodeRegistry.register(
               registry,
               %{
                 id: "dookie",
                 generation: generation,
                 os: :linux,
                 arch: :x86_64,
                 execution_backends: [:container],
                 capabilities: ["github-actions"],
                 total: %{cpu_millis: 8_000, memory_bytes: 16 * 1024 * 1024 * 1024},
                 available: %{cpu_millis: 8_000, memory_bytes: 16 * 1024 * 1024 * 1024}
               },
               now_ms: 5
             )

    :ok
  end

  defp start_command(placement) do
    {:ok, secret} = Secret.new("jit-config-abc123==")

    {:ok, command} =
      NodeCommand.start_placement(
        placement,
        "crf-dookie-1",
        :container,
        secret,
        @now_unix_ms - 1_000,
        @now_unix_ms + 30_000
      )

    command
  end

  defp gib(value), do: value * 1024 * 1024 * 1024
end
