defmodule CrfController.OperatorSnapshotTest do
  use ExUnit.Case, async: true

  alias CrfController.{
    DemandCoordinator,
    NodeRegistry,
    OfferLedger,
    OperatorSnapshot,
    PeerRegistry,
    PlacementLedger,
    PoolPolicy
  }

  defmodule StatusServer do
    use GenServer

    def start_link(status), do: GenServer.start_link(__MODULE__, status)
    def init(status), do: {:ok, status}
    def handle_call(:status, _from, status), do: {:reply, status, status}
  end

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
      OperatorSnapshot.snapshot(
        %{
          nodes: nodes,
          offers: offers,
          placements: placements,
          peers: peers,
          demand: nil,
          sidecar: nil
        },
        now_ms: 175
      )

    assert snapshot.schema_version == 1

    assert [
             %{
               id: "unraid-1",
               execution_backends: [:container],
               last_seen_age_ms: 75
             }
           ] = snapshot.nodes

    refute Map.has_key?(hd(snapshot.nodes), :last_seen_ms)
    assert [%{id: "offer-1", pool_id: "build"}] = snapshot.offers
    assert [%{id: "placement-1", state: :commanded}] = snapshot.placements
    assert snapshot.peer_authorization.peer_count == 1
    refute inspect(snapshot) =~ "must-not-leak"
    refute inspect(snapshot) =~ "command-1"
  end

  test "reports optional processes as unavailable without failing the snapshot" do
    dead_process = spawn(fn -> receive do: (:stop -> :ok) end)
    monitor = Process.monitor(dead_process)
    send(dead_process, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^dead_process, :normal}

    snapshot =
      OperatorSnapshot.snapshot(%{
        nodes: dead_process,
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

  test "projects only bounded sidecar operator fields" do
    {:ok, sidecar} =
      start_supervised(
        {StatusServer,
         %{
           ready: true,
           os_pid: 123,
           output_bytes: 99,
           diagnostic_tail: "safe diagnostic",
           started_at_ms: 10,
           internal_secret: "must-not-leak"
         }}
      )

    snapshot =
      OperatorSnapshot.snapshot(%{
        nodes: nil,
        offers: nil,
        placements: nil,
        demand: nil,
        peers: nil,
        sidecar: sidecar
      })

    assert snapshot.sidecar == %{
             ready: true,
             os_pid: 123,
             output_bytes: 99,
             diagnostic_tail: "safe diagnostic",
             started_at_ms: 10
           }

    refute inspect(snapshot) =~ "must-not-leak"
  end

  test "renders the list-backed orphan status returned by the production coordinator" do
    {:ok, policy} =
      PoolPolicy.new(%{
        id: "acceptance",
        max_concurrency: 1,
        resources: %{cpu_millis: 1_000, memory_bytes: 1_073_741_824},
        required_os: :windows,
        required_arch: :x86_64,
        required_backend: :native_process,
        required_capabilities: ["github-actions"],
        work_folder: "_work"
      })

    {:ok, demand} =
      start_supervised(
        {DemandCoordinator,
         name: nil,
         policies: [policy],
         scale_set_client: self(),
         scheduler_client: self(),
         auto_reconcile: false}
      )

    snapshot =
      OperatorSnapshot.snapshot(%{
        nodes: nil,
        offers: nil,
        placements: nil,
        demand: demand,
        peers: nil,
        sidecar: nil
      })

    assert snapshot.demand.orphaned_placements == []
    assert snapshot.demand.pools == ["acceptance"]
    assert snapshot.demand.pool_status == []
  end
end
