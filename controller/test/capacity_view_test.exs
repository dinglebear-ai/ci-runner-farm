defmodule CrfController.CapacityViewTest do
  use ExUnit.Case, async: true

  alias CrfController.{CapacityView, Node, Offer, Placement, Resources}

  @gib 1024 * 1024 * 1024

  test "pending controller reservation closes heartbeat propagation gap without double charging active placement" do
    {:ok, node} = test_node()
    {:ok, placement} = placement()

    assert {:ok, available} = CapacityView.effective_available(node, [placement])
    assert available == %Resources{cpu_millis: 6_000, memory_bytes: 12 * @gib}

    active = %{node | active_placements: MapSet.new([placement.id]), available: available}
    assert {:ok, ^available} = CapacityView.effective_available(active, [placement])
  end

  test "node-bound offers reserve capacity and the converting offer can be excluded exactly once" do
    {:ok, node} = test_node()
    {:ok, offer} = offer()

    assert {:ok, reserved} = CapacityView.effective_available(node, [], [offer])
    assert reserved == %Resources{cpu_millis: 6_000, memory_bytes: 12 * @gib}

    assert {:ok, full} = CapacityView.effective_available(node, [], [offer], offer.id)
    assert full == node.available
  end

  test "reservation larger than reported free capacity fails closed" do
    {:ok, node} = test_node()
    {:ok, placement} = placement()
    constrained = %{node | available: %Resources{cpu_millis: 1_000, memory_bytes: 2 * @gib}}

    assert {:error, :controller_reservation_exceeds_node_available} =
             CapacityView.effective_available(constrained, [placement])
  end

  defp test_node do
    Node.new(
      %{
        id: "dookie",
        generation: 7,
        os: :linux,
        arch: :x86_64,
        execution_backends: [:native_process],
        capabilities: ["github-actions"],
        total: %{cpu_millis: 8_000, memory_bytes: 16 * @gib},
        available: %{cpu_millis: 8_000, memory_bytes: 16 * @gib}
      },
      1
    )
  end

  defp offer do
    Offer.new(
      %{
        id: "offer-1",
        pool_id: "build",
        node_id: "dookie",
        node_generation: 7,
        resources: %{cpu_millis: 2_000, memory_bytes: 4 * @gib},
        expires_at_ms: 100
      },
      1
    )
  end

  defp placement do
    Placement.new(
      %{
        id: "placement-1",
        command_id: "command-1",
        idempotency_key: "idem-1",
        node_id: "dookie",
        node_generation: 7,
        work_id: "work-1",
        pool_id: "build",
        resources: %{cpu_millis: 2_000, memory_bytes: 4 * @gib}
      },
      1
    )
  end
end
