defmodule CrfController.OperatorSnapshotTest do
  use ExUnit.Case, async: true

  alias CrfController.{NodeRegistry, OfferLedger, OperatorSnapshot, PeerRegistry, PlacementLedger}

  test "returns a deterministic secret-free controller view" do
    {:ok, nodes} = start_supervised({NodeRegistry, name: nil})
    {:ok, offers} = start_supervised({OfferLedger, name: nil})
    {:ok, placements} = start_supervised({PlacementLedger, name: nil})
    fingerprint = String.duplicate("a", 64)
    {:ok, peers} = start_supervised({PeerRegistry, name: nil, peers: [{fingerprint, "unraid-1"}]})

    assert {:ok, _} =
             NodeRegistry.register(
               nodes,
               %{
                 id: "unraid-1",
                 generation: 7,
                 os: :linux,
                 arch: :x86_64,
                 execution_backends: [:container],
                 capabilities: ["container", "github-actions"],
                 total: %{cpu_millis: 8_000, memory_bytes: 16_000},
                 available: %{cpu_millis: 6_000, memory_bytes: 12_000}
               },
               now_ms: 100
             )

    assert {:ok, _} =
             OfferLedger.reserve(
               offers,
               %{
                 id: "offer-1",
                 pool_id: "build",
                 node_id: "unraid-1",
                 node_generation: 7,
                 resources: %{cpu_millis: 2_000, memory_bytes: 4_000},
                 expires_at_ms: 1_000
               },
               now_ms: 100
             )

    assert {:ok, _} =
             PlacementLedger.begin_placement(
               placements,
               %{
                 id: "placement-1",
                 command_id: "command-1",
                 idempotency_key: "must-not-leak",
                 node_id: "unraid-1",
                 node_generation: 7,
                 work_id: "work-1",
                 pool_id: "build",
                 resources: %{cpu_millis: 2_000, memory_bytes: 4_000}
               },
               now_ms: 100
             )

    snapshot =
      OperatorSnapshot.snapshot(%{
        nodes: nodes,
        offers: offers,
        placements: placements,
        peers: peers,
        demand: nil,
        sidecar: nil
      })

    assert snapshot.schema_version == 1
    assert [%{id: "unraid-1", execution_backends: [:container]}] = snapshot.nodes
    assert [%{id: "offer-1", pool_id: "build"}] = snapshot.offers
    assert [%{id: "placement-1", state: :commanded}] = snapshot.placements
    assert snapshot.peer_authorization.peer_count == 1
    refute inspect(snapshot) =~ "must-not-leak"
    refute inspect(snapshot) =~ "command-1"
  end

  test "reports optional processes as unavailable without failing the snapshot" do
    snapshot =
      OperatorSnapshot.snapshot(%{
        nodes: nil,
        offers: nil,
        placements: nil,
        demand: nil,
        peers: nil,
        sidecar: nil
      })

    assert snapshot.nodes == []
    assert snapshot.placements == []
    assert snapshot.demand == nil
    assert snapshot.peer_authorization == nil
  end
end
