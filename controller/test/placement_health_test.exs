defmodule CrfController.PlacementHealthTest do
  use ExUnit.Case, async: true

  alias CrfController.{Node, Placement, PlacementHealth}

  test "missing placement becomes orphaned only after grace and recovery clears it" do
    {:ok, placement} = placement(7)

    first = PlacementHealth.update([placement], [], %{}, 100, 1_000)
    assert first.orphaned == []
    assert first.missing_since == %{"placement-1" => 100}

    expired = PlacementHealth.update([placement], [], first.missing_since, 1_100, 1_000)
    assert [%{placement_id: "placement-1", missing_for_ms: 1_000}] = expired.orphaned

    {:ok, node} = node(7, [])
    recovered = PlacementHealth.update([placement], [node], expired.missing_since, 1_200, 1_000)
    assert recovered.missing_since == %{}
    assert recovered.orphaned == []
  end

  test "newer node generation is healthy only when it reports the old placement active" do
    {:ok, placement} = placement(7)
    {:ok, restarted} = node(8, [])

    missing = PlacementHealth.update([placement], [restarted], %{}, 100, 1_000)
    assert missing.missing_since == %{"placement-1" => 100}

    {:ok, adopted} = node(8, ["placement-1"])
    healthy = PlacementHealth.update([placement], [adopted], missing.missing_since, 2_000, 1_000)
    assert healthy.missing_since == %{}
    assert healthy.orphaned == []
  end

  test "terminal placements never remain orphaned" do
    {:ok, placement} = placement(7)
    {:ok, finished} = Placement.advance(placement, :finished, nil, 20)

    health =
      PlacementHealth.update(
        [finished],
        [],
        %{"placement-1" => 1},
        10_000,
        1_000
      )

    assert health.missing_since == %{}
    assert health.orphaned == []
  end

  defp placement(generation) do
    Placement.new(
      %{
        id: "placement-1",
        command_id: "command-1",
        idempotency_key: "idem-1",
        node_id: "dookie",
        node_generation: generation,
        work_id: "work-1",
        pool_id: "build",
        resources: %{cpu_millis: 2_000, memory_bytes: 4 * 1024 * 1024 * 1024}
      },
      10
    )
  end

  defp node(generation, active) do
    with {:ok, node} <-
           Node.new(
             %{
               id: "dookie",
               generation: generation,
               os: :linux,
               arch: :x86_64,
               execution_backends: [:native_process],
               capabilities: ["github-actions"],
               total: %{cpu_millis: 8_000, memory_bytes: 16 * 1024 * 1024 * 1024},
               available: %{cpu_millis: 8_000, memory_bytes: 16 * 1024 * 1024 * 1024}
             },
             10
           ) do
      {:ok, %{node | active_placements: MapSet.new(active)}}
    end
  end
end
