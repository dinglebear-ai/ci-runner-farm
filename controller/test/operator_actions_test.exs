defmodule CrfController.OperatorActionsTest do
  use ExUnit.Case, async: true

  alias CrfController.{
    DemandCoordinator,
    NodeMailbox,
    NodeRegistry,
    OfferLedger,
    OperatorActions,
    PlacementLedger,
    PoolPolicy
  }

  defmodule FakeScaleSet do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)
    def init(nil), do: {:ok, nil}

    def handle_call({:call, "read_jit_state", %{}}, _from, state),
      do: {:reply, {:ok, []}, state}
  end

  test "drains only the exact current node generation" do
    {:ok, registry} = start_supervised({NodeRegistry, name: nil})

    assert {:ok, _} =
             NodeRegistry.register(
               registry,
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

    assert {:ok, %{node_id: "unraid-1", generation: 7, draining: true}} =
             OperatorActions.set_draining("unraid-1", 7, true, registry)

    assert {:error, :generation_mismatch} =
             OperatorActions.set_draining("unraid-1", 6, false, registry)

    assert {:error, :invalid_node_id} =
             OperatorActions.set_draining("../escape", 7, true, registry)
  end

  test "force abandon requires a literal force acknowledgement" do
    assert {:error, :explicit_force_required} =
             OperatorActions.force_abandon("placement-1", false, self())

    assert {:error, :invalid_force_abandon_request} =
             OperatorActions.force_abandon("placement-1", :yes, self())
  end

  test "force abandon terminalizes an orphan through the real coordinator and ledger" do
    context = coordinator_context()
    assert {:ok, _placement} = begin_placement(context.placements, "placement-orphan")

    assert {:error, :placement_not_orphaned} =
             OperatorActions.force_abandon("placement-orphan", true, context.demand)

    Process.sleep(1_050)

    assert {:ok,
            %{
              placement_id: "placement-orphan",
              node_id: "unraid-1",
              state: :failed,
              detail_code: "operator_abandoned"
            }} = OperatorActions.force_abandon("placement-orphan", true, context.demand)

    assert {:ok, tombstone} = PlacementLedger.get(context.placements, "placement-orphan")
    assert tombstone.state == :failed
  end

  test "force abandon refuses valid missing and non-orphan placement identifiers" do
    context = coordinator_context()

    assert {:error, :placement_not_orphaned} =
             OperatorActions.force_abandon("missing-placement", true, context.demand)

    assert {:ok, _node} = register_node(context.nodes)
    assert {:ok, _placement} = begin_placement(context.placements, "placement-live")

    assert {:error, :placement_not_orphaned} =
             OperatorActions.force_abandon("placement-live", true, context.demand)

    assert {:ok, placement} = PlacementLedger.get(context.placements, "placement-live")
    assert placement.state == :commanded
  end

  defp coordinator_context do
    nodes = start_supervised!({NodeRegistry, name: nil})
    placements = start_supervised!({PlacementLedger, name: nil})
    offers = start_supervised!({OfferLedger, name: nil})
    mailbox = start_supervised!({NodeMailbox, name: nil})
    scale_set = start_supervised!({FakeScaleSet, []})

    {:ok, policy} =
      PoolPolicy.new(%{
        id: "build",
        max_concurrency: 1,
        resources: %{cpu_millis: 1_000, memory_bytes: 1_024},
        required_os: :linux,
        required_arch: :x86_64,
        required_backend: :container,
        required_capabilities: ["container"],
        work_folder: "_work"
      })

    demand =
      start_supervised!(
        {DemandCoordinator,
         name: nil,
         policies: [policy],
         scale_set_client: scale_set,
         scheduler_client: self(),
         node_registry: nodes,
         placement_ledger: placements,
         offer_ledger: offers,
         node_mailbox: mailbox,
         placement_loss_grace_ms: 1_000,
         auto_reconcile: false}
      )

    %{nodes: nodes, placements: placements, demand: demand}
  end

  defp begin_placement(placements, id) do
    PlacementLedger.begin_placement(
      placements,
      %{
        id: id,
        command_id: "command-#{id}",
        idempotency_key: "key-#{id}",
        node_id: "unraid-1",
        node_generation: 7,
        work_id: "work-#{id}",
        pool_id: "build",
        resources: %{cpu_millis: 1_000, memory_bytes: 1_024}
      },
      now_ms: 10
    )
  end

  defp register_node(nodes) do
    NodeRegistry.register(
      nodes,
      %{
        id: "unraid-1",
        generation: 7,
        os: :linux,
        arch: :x86_64,
        execution_backends: [:container],
        capabilities: ["container"],
        total: %{cpu_millis: 2_000, memory_bytes: 2_048},
        available: %{cpu_millis: 2_000, memory_bytes: 2_048}
      },
      now_ms: System.monotonic_time(:millisecond)
    )
  end
end
