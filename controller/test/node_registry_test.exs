defmodule CrfController.NodeRegistryTest do
  use ExUnit.Case, async: true

  alias CrfController.NodeRegistry
  alias CrfController.Resources

  setup do
    start_supervised!({NodeRegistry, name: nil, stale_after_ms: 1_000})
    |> then(&%{registry: &1})
  end

  test "tracks Linux and Windows nodes without controller platform assumptions", %{
    registry: registry
  } do
    assert {:ok, linux} =
             NodeRegistry.register(registry, node_attrs("dookie", :linux, :container), now_ms: 10)

    assert {:ok, windows} =
             NodeRegistry.register(
               registry,
               node_attrs("steamy", :windows, :native_process),
               now_ms: 11
             )

    assert linux.os == :linux
    assert windows.os == :windows
    assert Enum.map(NodeRegistry.snapshot(registry), & &1.id) == ["dookie", "steamy"]
  end

  test "generation fencing rejects stale and conflicting node incarnations", %{registry: registry} do
    assert {:ok, _} =
             NodeRegistry.register(registry, node_attrs("dookie", :linux, :container, 2),
               now_ms: 10
             )

    assert {:error, :stale_generation} =
             NodeRegistry.register(registry, node_attrs("dookie", :linux, :container, 1),
               now_ms: 20
             )

    assert {:error, :generation_conflict} =
             NodeRegistry.register(
               registry,
               node_attrs("dookie", :windows, :native_process, 2),
               now_ms: 25
             )

    assert {:error, :generation_mismatch} =
             NodeRegistry.heartbeat(
               registry,
               "dookie",
               1,
               %{cpu_millis: 1_000, memory_bytes: gib(1)},
               now_ms: 30
             )
  end

  test "failed durable precommit does not advance the registered generation", %{
    registry: registry
  } do
    assert {:ok, _} =
             NodeRegistry.register(registry, node_attrs("dookie", :linux, :container, 1),
               now_ms: 10
             )

    assert {:error, :durability_failed} =
             NodeRegistry.register(registry, node_attrs("dookie", :linux, :container, 2),
               now_ms: 20,
               before_commit: fn _node -> {:error, :durability_failed} end
             )

    assert {:ok, %{generation: 1}} = NodeRegistry.get(registry, "dookie")
  end

  test "heartbeats refresh resources and stale nodes are pruned", %{registry: registry} do
    assert {:ok, _} =
             NodeRegistry.register(registry, node_attrs("squirts", :linux, :container),
               now_ms: 10
             )

    assert {:ok, updated} =
             NodeRegistry.heartbeat(
               registry,
               "squirts",
               1,
               %{cpu_millis: 2_000, memory_bytes: gib(8)},
               now_ms: 500
             )

    assert updated.available == %Resources{cpu_millis: 2_000, memory_bytes: gib(8)}
    assert [] == NodeRegistry.prune_stale(registry, 1_500)
    assert ["squirts"] == NodeRegistry.prune_stale(registry, 1_501)
    assert [] == NodeRegistry.snapshot(registry)
  end

  test "draining state is generation fenced and survives re-registration", %{registry: registry} do
    assert {:ok, _} =
             NodeRegistry.register(registry, node_attrs("steamy", :windows, :native_process),
               now_ms: 10
             )

    assert {:ok, drained} = NodeRegistry.set_draining(registry, "steamy", 1, true)
    assert drained.draining

    assert {:ok, same_generation} =
             NodeRegistry.register(
               registry,
               node_attrs("steamy", :windows, :native_process, 1),
               now_ms: 20
             )

    assert same_generation.draining

    assert {:ok, next_generation} =
             NodeRegistry.register(
               registry,
               node_attrs("steamy", :windows, :native_process, 2),
               now_ms: 30
             )

    assert next_generation.draining

    assert {:error, :generation_mismatch} =
             NodeRegistry.set_draining(registry, "steamy", 1, false)
  end

  test "a node cannot advertise more free resources than it owns", %{registry: registry} do
    attrs =
      node_attrs("bad-node", :linux, :container)
      |> put_in([:available, :cpu_millis], 99_000)

    assert {:error, :available_exceeds_total} = NodeRegistry.register(registry, attrs, now_ms: 10)
  end

  defp node_attrs(id, os, backend, generation \\ 1) do
    %{
      id: id,
      generation: generation,
      os: os,
      arch: :x86_64,
      execution_backends: [backend],
      capabilities: ["github-actions", "x64"],
      total: %{cpu_millis: 8_000, memory_bytes: gib(16)},
      available: %{cpu_millis: 8_000, memory_bytes: gib(16)},
      draining: false
    }
  end

  defp gib(value), do: value * 1024 * 1024 * 1024
end
