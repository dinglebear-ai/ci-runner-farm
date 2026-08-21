defmodule CrfController.PlacementCoordinatorTest do
  use ExUnit.Case, async: true

  alias CrfController.{
    NodeMailbox,
    NodeRegistry,
    OfferLedger,
    PlacementCoordinator,
    PlacementLedger,
    Secret
  }

  @gib 1024 * 1024 * 1024
  @now_unix_ms 1_787_070_001_000

  setup do
    registry = start_supervised!({NodeRegistry, name: nil, stale_after_ms: 10_000})
    placements = start_supervised!({PlacementLedger, name: nil})
    offers = start_supervised!({OfferLedger, name: nil, capacity: 16})
    mailbox = start_supervised!({NodeMailbox, name: nil, capacity: 16})

    coordinator =
      start_supervised!(
        {PlacementCoordinator,
         name: nil,
         node_registry: registry,
         placement_ledger: placements,
         offer_ledger: offers,
         node_mailbox: mailbox}
      )

    register_node(registry)

    %{
      registry: registry,
      placements: placements,
      offers: offers,
      mailbox: mailbox,
      coordinator: coordinator
    }
  end

  test "assigned offer converts into placement without double charging capacity", context do
    offer_attrs = offer_attrs("offer-1", 6_000)
    assert {:ok, _} = OfferLedger.reserve(context.offers, offer_attrs, now_ms: 5)
    assert {:ok, assigned} = OfferLedger.assign_next(context.offers, "build", 101, now_ms: 6)

    attrs =
      dispatch_attrs("placement-offer", "command-offer", "idem-offer", 6_000)
      |> Map.merge(%{offer_id: assigned.id, work_handle: 101})

    assert {:ok, %{placement: placement, replay: false}} =
             PlacementCoordinator.dispatch(context.coordinator, attrs,
               now_ms: 10,
               now_unix_ms: @now_unix_ms
             )

    assert placement.id == "placement-offer"
    assert {:error, :unknown_offer} = OfferLedger.get(context.offers, assigned.id)
    assert NodeMailbox.size(context.mailbox) == 1
  end

  test "unrelated offered slot cannot be stolen by an unbacked dispatch", context do
    assert {:ok, _} =
             OfferLedger.reserve(context.offers, offer_attrs("offer-1", 7_000), now_ms: 5)

    attrs = dispatch_attrs("placement-1", "command-1", "idem-1", 2_000)

    assert {:error, :insufficient_node_capacity} =
             PlacementCoordinator.dispatch(context.coordinator, attrs,
               now_ms: 10,
               now_unix_ms: @now_unix_ms
             )

    assert PlacementLedger.snapshot(context.placements) == []
  end

  test "mismatched offer assignment fails before placement mutation", context do
    assert {:ok, _} =
             OfferLedger.reserve(context.offers, offer_attrs("offer-1", 2_000), now_ms: 5)

    assert {:ok, assigned} = OfferLedger.assign_next(context.offers, "build", 101, now_ms: 6)

    attrs =
      dispatch_attrs("placement-1", "command-1", "idem-1", 2_000)
      |> Map.merge(%{offer_id: assigned.id, work_handle: 102})

    assert {:error, :offer_assignment_conflict} =
             PlacementCoordinator.dispatch(context.coordinator, attrs,
               now_ms: 10,
               now_unix_ms: @now_unix_ms
             )

    assert PlacementLedger.snapshot(context.placements) == []
    assert {:ok, ^assigned} = OfferLedger.get(context.offers, assigned.id)
  end

  test "dispatch creates one fenced placement and mailbox command", context do
    attrs = dispatch_attrs("placement-1", "command-1", "idem-1", 2_000)

    assert {:ok, %{placement: placement, command: command, replay: false}} =
             PlacementCoordinator.dispatch(context.coordinator, attrs,
               now_ms: 10,
               now_unix_ms: @now_unix_ms
             )

    assert placement.node_id == "dookie"
    assert placement.node_generation == 7
    assert command.node_id == "dookie"
    assert command.node_generation == 7
    assert NodeMailbox.size(context.mailbox) == 1

    assert {:ok, ^command} =
             NodeMailbox.next_for(context.mailbox, "dookie", 7, now_unix_ms: @now_unix_ms)
  end

  test "back-to-back dispatches reserve capacity before heartbeat catches up", context do
    first = dispatch_attrs("placement-1", "command-1", "idem-1", 5_000)
    second = dispatch_attrs("placement-2", "command-2", "idem-2", 4_000)

    assert {:ok, _} =
             PlacementCoordinator.dispatch(context.coordinator, first,
               now_ms: 10,
               now_unix_ms: @now_unix_ms
             )

    assert {:error, :insufficient_node_capacity} =
             PlacementCoordinator.dispatch(context.coordinator, second,
               now_ms: 11,
               now_unix_ms: @now_unix_ms + 1
             )

    assert NodeMailbox.size(context.mailbox) == 1
  end

  test "heartbeat active placement prevents controller double subtraction", context do
    first = dispatch_attrs("placement-1", "command-1", "idem-1", 5_000)
    second = dispatch_attrs("placement-2", "command-2", "idem-2", 2_000)

    assert {:ok, _} =
             PlacementCoordinator.dispatch(context.coordinator, first,
               now_ms: 10,
               now_unix_ms: @now_unix_ms
             )

    assert {:ok, _node} =
             NodeRegistry.heartbeat(
               context.registry,
               "dookie",
               7,
               %{cpu_millis: 3_000, memory_bytes: 11 * @gib},
               active_placements: MapSet.new(["placement-1"]),
               now_ms: 20
             )

    assert {:ok, %{placement: placement}} =
             PlacementCoordinator.dispatch(context.coordinator, second,
               now_ms: 21,
               now_unix_ms: @now_unix_ms + 1
             )

    assert placement.id == "placement-2"
    assert NodeMailbox.size(context.mailbox) == 2
  end

  test "exact dispatch retry is idempotent even after reservation", context do
    attrs = dispatch_attrs("placement-1", "command-1", "idem-1", 5_000)

    assert {:ok, %{command: command, replay: false}} =
             PlacementCoordinator.dispatch(context.coordinator, attrs,
               now_ms: 10,
               now_unix_ms: @now_unix_ms
             )

    assert {:ok, %{command: ^command, replay: true}} =
             PlacementCoordinator.dispatch(context.coordinator, attrs,
               now_ms: 20,
               now_unix_ms: @now_unix_ms
             )

    assert NodeMailbox.size(context.mailbox) == 1
  end

  test "accepted placement retry does not recreate a mailbox command", context do
    attrs = dispatch_attrs("placement-1", "command-1", "idem-1", 2_000)
    assert {:ok, %{command: command}} = dispatch(context.coordinator, attrs, 10)

    assert {:ok, ^command} =
             NodeMailbox.prepare_ack(
               context.mailbox,
               "dookie",
               7,
               "command-1",
               "idem-1",
               :accepted
             )

    assert {:ok, _placement} =
             PlacementLedger.command_ack(
               context.placements,
               "dookie",
               7,
               "command-1",
               "idem-1",
               :accepted,
               nil,
               now_ms: 20
             )

    assert {:ok, ^command} = NodeMailbox.commit_ack(context.mailbox, "command-1", "idem-1")
    assert NodeMailbox.size(context.mailbox) == 0

    assert {:ok, %{placement: placement, command: ^command, replay: true}} =
             dispatch(context.coordinator, attrs, 21)

    assert placement.state == :accepted
    assert NodeMailbox.size(context.mailbox) == 0
  end

  test "same placement ids with changed JIT command conflict instead of replacement", context do
    attrs = dispatch_attrs("placement-1", "command-1", "idem-1", 2_000)
    assert {:ok, _} = dispatch(context.coordinator, attrs, 10)

    {:ok, different_secret} = Secret.new("different-jit-config==")
    changed = %{attrs | jit_config: different_secret}

    assert {:error, :command_id_conflict} = dispatch(context.coordinator, changed, 11)
    assert NodeMailbox.size(context.mailbox) == 1
  end

  test "draining node rejects dispatch before creating placement", context do
    assert {:ok, _} = NodeRegistry.set_draining(context.registry, "dookie", 7, true)
    attrs = dispatch_attrs("placement-1", "command-1", "idem-1", 2_000)

    assert {:error, :node_draining} = dispatch(context.coordinator, attrs, 10)
    assert PlacementLedger.snapshot(context.placements) == []
    assert NodeMailbox.size(context.mailbox) == 0
  end

  test "mailbox-full dispatch is terminalized and releases controller reservation" do
    registry =
      start_supervised!({NodeRegistry, name: nil, stale_after_ms: 10_000}, id: :full_registry)

    placements = start_supervised!({PlacementLedger, name: nil}, id: :full_placements)
    mailbox = start_supervised!({NodeMailbox, name: nil, capacity: 1}, id: :full_mailbox)

    coordinator =
      start_supervised!(
        {PlacementCoordinator,
         name: nil, node_registry: registry, placement_ledger: placements, node_mailbox: mailbox},
        id: :full_coordinator
      )

    register_node(registry)
    first = dispatch_attrs("placement-1", "command-1", "idem-1", 1_000)
    second = dispatch_attrs("placement-2", "command-2", "idem-2", 1_000)

    assert {:ok, _} = dispatch(coordinator, first, 10)
    assert {:error, :mailbox_full} = dispatch(coordinator, second, 11)
    assert {:ok, failed} = PlacementLedger.get(placements, "placement-2")
    assert failed.state == :failed
    assert failed.detail_code == "mailbox_enqueue_failed"
    assert {:error, :placement_terminal} = dispatch(coordinator, second, 12)

    third = dispatch_attrs("placement-3", "command-3", "idem-3", 6_500)
    assert {:error, :mailbox_full} = dispatch(coordinator, third, 12)
    assert {:ok, failed_third} = PlacementLedger.get(placements, "placement-3")
    assert failed_third.state == :failed
  end

  defp register_node(registry) do
    NodeRegistry.register(
      registry,
      %{
        id: "dookie",
        generation: 7,
        os: :linux,
        arch: :x86_64,
        execution_backends: [:native_process],
        capabilities: ["github-actions", "native-process"],
        total: %{cpu_millis: 8_000, memory_bytes: 16 * @gib},
        available: %{cpu_millis: 8_000, memory_bytes: 16 * @gib},
        draining: false
      },
      now_ms: 1
    )
  end

  defp offer_attrs(id, cpu_millis) do
    %{
      id: id,
      pool_id: "build",
      node_id: "dookie",
      node_generation: 7,
      resources: %{cpu_millis: cpu_millis, memory_bytes: 4 * @gib},
      expires_at_ms: 1_000
    }
  end

  defp dispatch_attrs(placement_id, command_id, idempotency_key, cpu_millis) do
    {:ok, secret} = Secret.new("jit-config-abc123==")

    %{
      placement_id: placement_id,
      command_id: command_id,
      idempotency_key: idempotency_key,
      work_id: "work-#{placement_id}",
      pool_id: "build",
      node_id: "dookie",
      resources: %{cpu_millis: cpu_millis, memory_bytes: 4 * @gib},
      runner_name: "runner-#{placement_id}",
      execution_backend: :native_process,
      jit_config: secret,
      issued_at_unix_ms: @now_unix_ms - 1_000,
      expires_at_unix_ms: @now_unix_ms + 30_000
    }
  end

  defp dispatch(coordinator, attrs, now_ms) do
    PlacementCoordinator.dispatch(coordinator, attrs,
      now_ms: now_ms,
      now_unix_ms: @now_unix_ms
    )
  end
end
