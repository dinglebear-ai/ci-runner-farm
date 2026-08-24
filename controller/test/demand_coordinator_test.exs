defmodule CrfController.DemandCoordinatorTest do
  use ExUnit.Case, async: false

  alias CrfController.{
    DemandCoordinator,
    NodeCommand,
    NodeMailbox,
    NodeRegistry,
    OfferLedger,
    PlacementCoordinator,
    PlacementLedger,
    SchedulerClient,
    Secret,
    WorkIdentity
  }

  @gib 1024 * 1024 * 1024
  @now_unix_ms 1_787_070_001_000

  defmodule FakeScaleSet do
    use GenServer

    alias CrfController.Secret

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def state(server), do: GenServer.call(server, :state)

    def set_handles(server, handles, assigned_jobs \\ nil),
      do: GenServer.call(server, {:set_handles, handles, assigned_jobs})

    def set_assigned_jobs(server, assigned_jobs),
      do: GenServer.call(server, {:set_assigned_jobs, assigned_jobs})

    def add_pool(server, pool), do: GenServer.call(server, {:add_pool, pool})

    def set_pool_health(server, pool_id, healthy),
      do: GenServer.call(server, {:set_pool_health, pool_id, healthy})

    def set_jit_states(server, states), do: GenServer.call(server, {:set_jit_states, states})
    def fail_next_snapshot(server), do: GenServer.call(server, :fail_next_snapshot)

    @impl true
    def init(_opts) do
      {:ok,
       %{
         snapshot: snapshot([]),
         jit_states: [],
         apply_calls: 0,
         issue_calls: 0,
         retire_calls: 0,
         confirm_calls: 0,
         last_retire_payload: nil,
         last_confirm_payload: nil,
         last_leases: %{},
         fail_next_snapshot: false
       }}
    end

    @impl true
    def handle_call(:state, _from, state), do: {:reply, state, state}

    def handle_call({:set_handles, handles, assigned_jobs}, _from, state) do
      [pool] = state.snapshot.pools
      assigned_jobs = if is_nil(assigned_jobs), do: length(handles), else: assigned_jobs
      pool = %{pool | acquired_handles: handles, assigned_jobs: assigned_jobs}
      state = %{state | snapshot: %{state.snapshot | pools: [pool]}}
      {:reply, :ok, state}
    end

    def handle_call({:set_assigned_jobs, assigned_jobs}, _from, state) do
      [pool] = state.snapshot.pools
      pool = %{pool | assigned_jobs: assigned_jobs}
      state = %{state | snapshot: %{state.snapshot | pools: [pool]}}
      {:reply, :ok, state}
    end

    def handle_call({:add_pool, pool}, _from, state) do
      pools = state.snapshot.pools ++ [pool]
      {:reply, :ok, %{state | snapshot: %{state.snapshot | pools: pools}}}
    end

    def handle_call({:set_pool_health, pool_id, healthy}, _from, state) do
      pools =
        Enum.map(state.snapshot.pools, fn pool ->
          if pool.pool_id == pool_id, do: %{pool | session_healthy: healthy}, else: pool
        end)

      {:reply, :ok, %{state | snapshot: %{state.snapshot | pools: pools}}}
    end

    def handle_call({:set_jit_states, states}, _from, state) do
      states =
        Enum.map(states, &Map.put_new(&1, :ownership_revision, state.snapshot.ownership_revision))

      {:reply, :ok, %{state | jit_states: states}}
    end

    def handle_call(:fail_next_snapshot, _from, state) do
      {:reply, :ok, %{state | fail_next_snapshot: true}}
    end

    def handle_call({:call, "apply_sessions", %{"eligible" => true}}, _from, state) do
      {:reply, {:ok, %{"applied" => true}}, %{state | apply_calls: state.apply_calls + 1}}
    end

    def handle_call({:call, "read_jit_state", %{}}, _from, state) do
      {:reply, {:ok, state.jit_states}, state}
    end

    def handle_call({:call, "read_snapshot", %{}}, _from, %{fail_next_snapshot: true} = state) do
      {:reply, {:error, {:scaleset_transport, :closed}}, %{state | fail_next_snapshot: false}}
    end

    def handle_call({:call, "read_snapshot", %{}}, _from, state) do
      {:reply, {:ok, state.snapshot}, state}
    end

    def handle_call({:call, "publish_capacity_leases", %{"leases" => leases}}, _from, state) do
      {:reply, {:ok, %{"leases" => leases}}, %{state | last_leases: leases}}
    end

    def handle_call({:call, "issue_jit", payload}, _from, state) do
      pool_id = payload["pool_id"]
      handle = payload["work_handle"]
      [pool] = state.snapshot.pools
      {:ok, secret} = Secret.new("jit-config-#{handle}==")

      jit = %{
        pool_id: pool_id,
        scale_set_id: pool.scale_set_id,
        work_handle: handle,
        state: "issued",
        ownership_revision: state.snapshot.ownership_revision,
        descriptor_available: true
      }

      jit_states =
        [jit | state.jit_states]
        |> Enum.uniq_by(&{&1.pool_id, &1.work_handle})

      {:reply, {:ok, %{descriptor: secret, scale_set_id: pool.scale_set_id}},
       %{state | issue_calls: state.issue_calls + 1, jit_states: jit_states}}
    end

    def handle_call({:call, "retire_jit", payload}, _from, state) do
      pool_id = payload["pool_id"]
      handle = payload["work_handle"]

      jit_states =
        Enum.reject(state.jit_states, &(&1.pool_id == pool_id and &1.work_handle == handle))

      {:reply, {:ok, %{"retired" => true}},
       %{
         state
         | retire_calls: state.retire_calls + 1,
           last_retire_payload: payload,
           jit_states: jit_states
       }}
    end

    def handle_call({:call, "confirm_jit_retirement", payload}, _from, state) do
      pool_id = payload["pool_id"]
      handle = payload["work_handle"]

      jit_states =
        Enum.reject(state.jit_states, &(&1.pool_id == pool_id and &1.work_handle == handle))

      {:reply, {:ok, %{"confirmed" => true}},
       %{
         state
         | confirm_calls: state.confirm_calls + 1,
           last_confirm_payload: payload,
           jit_states: jit_states
       }}
    end

    defp snapshot(handles) do
      %{
        controller_instance_id: "controller-1",
        config_revision: String.duplicate("a", 64),
        ownership_revision: String.duplicate("b", 64),
        sequence: 1,
        pools: [
          %{
            pool_id: "build",
            scale_set_id: 74,
            assigned_jobs: length(handles),
            advertised_capacity: 0,
            last_message_id: 1,
            session_healthy: true,
            acquired_handles: handles,
            fast_lane_state: "holding",
            fast_lane_long_threshold_ms: 360_000,
            fast_lane_hold_duration_ms: 15_000,
            fast_lane_reserved_slots: 1,
            fast_lane_hold_until_ms: 123_456
          }
        ]
      }
    end
  end

  setup do
    case System.get_env("CRF_SCHEDULER_BIN") do
      nil ->
        %{disabled: true}

      executable ->
        registry = start_supervised!({NodeRegistry, name: nil, stale_after_ms: 10_000})
        placements = start_supervised!({PlacementLedger, name: nil})
        offers = start_supervised!({OfferLedger, name: nil, capacity: 32})
        mailbox = start_supervised!({NodeMailbox, name: nil, capacity: 32})
        scale_set = start_supervised!({FakeScaleSet, []})

        scheduler =
          start_supervised!(
            {SchedulerClient, name: nil, executable: executable, request_timeout_ms: 5_000}
          )

        coordinator =
          start_supervised!(
            {PlacementCoordinator,
             name: nil,
             node_registry: registry,
             placement_ledger: placements,
             offer_ledger: offers,
             node_mailbox: mailbox}
          )

        assert {:ok, _} = register_node(registry)

        demand =
          start_supervised!(
            {DemandCoordinator,
             name: nil,
             policies: [policy(2)],
             scale_set_client: scale_set,
             scheduler_client: scheduler,
             node_registry: registry,
             placement_ledger: placements,
             offer_ledger: offers,
             node_mailbox: mailbox,
             placement_coordinator: coordinator,
             placement_loss_grace_ms: 1_000,
             max_new_offers_per_tick: 4}
          )

        %{
          disabled: false,
          registry: registry,
          placements: placements,
          offers: offers,
          mailbox: mailbox,
          scale_set: scale_set,
          scheduler: scheduler,
          coordinator: coordinator,
          demand: demand
        }
    end
  end

  test "status exposes bounded fast lane policy without acquired handles", ctx do
    unless ctx.disabled do
      assert {:ok, _} = reconcile(ctx.demand, 50)
      status = DemandCoordinator.status(ctx.demand)
      assert [pool] = status.pool_status
      assert pool.pool_id == "build"
      assert pool.scale_set_id == 74
      assert pool.fast_lane_state == "holding"
      assert pool.fast_lane_long_threshold_ms == 360_000
      assert pool.fast_lane_hold_duration_ms == 15_000
      assert pool.fast_lane_reserved_slots == 1
      assert pool.fast_lane_hold_until_ms == 123_456
      refute Map.has_key?(pool, :acquired_handles)
    end
  end

  test "resource-backed offers become JIT placements without changing advertised capacity", ctx do
    unless ctx.disabled do
      :ok = FakeScaleSet.set_assigned_jobs(ctx.scale_set, 2)

      assert {:ok, first} = reconcile(ctx.demand, 100)
      assert first.leases == %{"build" => 2}
      assert first.offers == 2
      assert first.placements == 0
      assert Enum.all?(OfferLedger.snapshot(ctx.offers, now_ms: 101), &(&1.state == :offered))

      :ok = FakeScaleSet.set_handles(ctx.scale_set, [101, 102])

      assert {:ok, second} = reconcile(ctx.demand, 200)
      assert second.leases == %{"build" => 2}
      assert second.offers == 0
      assert second.placements == 2
      assert NodeMailbox.size(ctx.mailbox) == 2

      placements = PlacementLedger.snapshot(ctx.placements)
      assert Enum.all?(placements, &(&1.state == :commanded))
      assert Enum.map(placements, & &1.pool_id) == ["build", "build"]

      sidecar = FakeScaleSet.state(ctx.scale_set)
      assert sidecar.apply_calls == 1
      assert sidecar.issue_calls == 2
      assert sidecar.last_leases == %{"build" => 2}
    end
  end

  test "acquired handles cannot exceed the pool concurrency policy", ctx do
    unless ctx.disabled do
      :ok = FakeScaleSet.set_assigned_jobs(ctx.scale_set, 4)

      assert {:ok, first} = reconcile(ctx.demand, 100)
      assert first.offers == 2

      :ok = FakeScaleSet.set_handles(ctx.scale_set, [101, 102, 103, 104])

      assert {:ok, second} = reconcile(ctx.demand, 200)
      assert second.placements == 2
      assert length(PlacementLedger.snapshot(ctx.placements)) == 2
      assert NodeMailbox.size(ctx.mailbox) == 2
      assert FakeScaleSet.state(ctx.scale_set).issue_calls == 2
    end
  end

  test "active deterministic placement is reconstructed without another JIT issuance", ctx do
    unless ctx.disabled do
      {:ok, identity} = WorkIdentity.for_handle("build", 74, 501)

      :ok =
        FakeScaleSet.set_jit_states(ctx.scale_set, [
          %{
            pool_id: "build",
            scale_set_id: 74,
            work_handle: 501,
            state: "issued",
            descriptor_available: true
          }
        ])

      assert {:ok, _} =
               NodeRegistry.heartbeat(
                 ctx.registry,
                 "dookie",
                 7,
                 %{cpu_millis: 6_000, memory_bytes: 12 * @gib},
                 active_placements: MapSet.new([identity.placement_id]),
                 now_ms: 90
               )

      assert {:ok, _} = reconcile(ctx.demand, 100)
      assert {:ok, placement} = PlacementLedger.get(ctx.placements, identity.placement_id)
      assert placement.state == :observed
      assert FakeScaleSet.state(ctx.scale_set).issue_calls == 0
      assert NodeMailbox.size(ctx.mailbox) == 0
    end
  end

  test "unassigned active JIT placement is cancelled after the idle timeout", ctx do
    unless ctx.disabled do
      {:ok, identity} = WorkIdentity.for_handle("build", 74, 502)

      :ok = FakeScaleSet.set_handles(ctx.scale_set, [502], 0)

      :ok =
        FakeScaleSet.set_jit_states(ctx.scale_set, [
          %{
            pool_id: "build",
            scale_set_id: 74,
            work_handle: 502,
            state: "issued",
            descriptor_available: true
          }
        ])

      assert {:ok, _} =
               NodeRegistry.heartbeat(
                 ctx.registry,
                 "dookie",
                 7,
                 %{cpu_millis: 6_000, memory_bytes: 12 * @gib},
                 active_placements: MapSet.new([identity.placement_id]),
                 now_ms: 90
               )

      assert {:ok, first} = reconcile(ctx.demand, 100)
      assert first.reclaimed_idle_placements == 0
      assert {:ok, placement} = PlacementLedger.get(ctx.placements, identity.placement_id)
      assert placement.state == :observed
      assert placement.updated_at_ms == 100

      assert {:ok, before_timeout} = reconcile(ctx.demand, 90_099)
      assert before_timeout.reclaimed_idle_placements == 0
      assert NodeMailbox.size(ctx.mailbox) == 0
      assert {:ok, unchanged} = PlacementLedger.get(ctx.placements, identity.placement_id)
      assert unchanged.updated_at_ms == 100

      assert {:ok, after_timeout} = reconcile(ctx.demand, 90_100)
      assert after_timeout.reclaimed_idle_placements == 1
      assert NodeMailbox.size(ctx.mailbox) == 1
      assert {:ok, cancelling} = PlacementLedger.get(ctx.placements, identity.placement_id)
      assert cancelling.updated_at_ms == 90_100
      assert cancelling.detail_code == "idle_cancel_requested"

      assert {:ok, pending} = reconcile(ctx.demand, 90_101)
      assert pending.reclaimed_idle_placements == 0
      assert NodeMailbox.size(ctx.mailbox) == 1

      assert {:ok, command} =
               NodeMailbox.next_for(ctx.mailbox, "dookie", 7, now_unix_ms: @now_unix_ms + 90_100)

      assert command.payload == {:cancel_placement, identity.placement_id}
    end
  end

  test "assigned active JIT placement is not reclaimed", ctx do
    unless ctx.disabled do
      {:ok, identity} = WorkIdentity.for_handle("build", 74, 503)

      :ok = FakeScaleSet.set_handles(ctx.scale_set, [503], 1)

      :ok =
        FakeScaleSet.set_jit_states(ctx.scale_set, [
          %{
            pool_id: "build",
            scale_set_id: 74,
            work_handle: 503,
            state: "issued",
            descriptor_available: true
          }
        ])

      assert {:ok, _} =
               NodeRegistry.heartbeat(
                 ctx.registry,
                 "dookie",
                 7,
                 %{cpu_millis: 6_000, memory_bytes: 12 * @gib},
                 active_placements: MapSet.new([identity.placement_id]),
                 now_ms: 90
               )

      assert {:ok, _} = reconcile(ctx.demand, 100)
      assert {:ok, result} = reconcile(ctx.demand, 200_000)
      assert result.reclaimed_idle_placements == 0
      assert NodeMailbox.size(ctx.mailbox) == 0
    end
  end

  test "persisted commanded placement rebuilds a lost mailbox command exactly once", ctx do
    unless ctx.disabled do
      {:ok, identity} = WorkIdentity.for_handle("build", 74, 701)

      assert {:ok, _} =
               PlacementLedger.begin_placement(ctx.placements, placement_attrs(identity, 7),
                 now_ms: 50
               )

      :ok =
        FakeScaleSet.set_jit_states(ctx.scale_set, [
          %{
            pool_id: "build",
            scale_set_id: 74,
            work_handle: 701,
            state: "issued",
            descriptor_available: true
          }
        ])

      assert NodeMailbox.size(ctx.mailbox) == 0
      assert {:ok, _} = reconcile(ctx.demand, 100)
      assert NodeMailbox.size(ctx.mailbox) == 1
      assert FakeScaleSet.state(ctx.scale_set).issue_calls == 1

      assert {:ok, _} = reconcile(ctx.demand, 200)
      assert NodeMailbox.size(ctx.mailbox) == 1
      assert FakeScaleSet.state(ctx.scale_set).issue_calls == 1
    end
  end

  test "surviving runner adopts a newer node generation and drops stale mailbox command", ctx do
    unless ctx.disabled do
      {:ok, identity} = WorkIdentity.for_handle("build", 74, 702)

      assert {:ok, placement} =
               PlacementLedger.begin_placement(ctx.placements, placement_attrs(identity, 7),
                 now_ms: 50
               )

      {:ok, secret} = Secret.new("jit-config-702==")

      {:ok, command} =
        NodeCommand.start_placement(
          placement,
          identity.runner_name,
          :native_process,
          secret,
          @now_unix_ms,
          @now_unix_ms + 60_000
        )

      assert {:ok, ^command} =
               NodeMailbox.enqueue(ctx.mailbox, command, now_unix_ms: @now_unix_ms)

      assert {:ok, _} = register_node_generation(ctx.registry, 8)

      assert {:ok, _} =
               NodeRegistry.heartbeat(
                 ctx.registry,
                 "dookie",
                 8,
                 %{cpu_millis: 6_000, memory_bytes: 12 * @gib},
                 active_placements: MapSet.new([identity.placement_id]),
                 now_ms: 90
               )

      :ok =
        FakeScaleSet.set_jit_states(ctx.scale_set, [
          %{
            pool_id: "build",
            scale_set_id: 74,
            work_handle: 702,
            state: "issued",
            descriptor_available: true
          }
        ])

      assert {:ok, _} = reconcile(ctx.demand, 100)
      assert {:ok, adopted} = PlacementLedger.get(ctx.placements, identity.placement_id)
      assert adopted.node_generation == 8
      assert adopted.state == :observed
      assert NodeMailbox.size(ctx.mailbox) == 0
      assert FakeScaleSet.state(ctx.scale_set).issue_calls == 0

      # A second node restart must still adopt the durable runner even though
      # its controller state is already observed. Otherwise later cancellation
      # remains fenced to generation 8 and can never reach generation 9.
      assert {:ok, _} = register_node_generation(ctx.registry, 9)

      assert {:ok, _} =
               NodeRegistry.heartbeat(
                 ctx.registry,
                 "dookie",
                 9,
                 %{cpu_millis: 6_000, memory_bytes: 12 * @gib},
                 active_placements: MapSet.new([identity.placement_id]),
                 now_ms: 110
               )

      assert {:ok, _} = reconcile(ctx.demand, 120)
      assert {:ok, readopted} = PlacementLedger.get(ctx.placements, identity.placement_id)
      assert readopted.node_generation == 9
      assert readopted.state == :observed
    end
  end

  test "missing placement becomes operator-visible orphan without automatic retry", ctx do
    unless ctx.disabled do
      {:ok, identity} = WorkIdentity.for_handle("build", 74, 801)

      assert {:ok, placement} =
               PlacementLedger.begin_placement(ctx.placements, placement_attrs(identity, 7),
                 now_ms: 50
               )

      {:ok, secret} = Secret.new("jit-config-801==")

      {:ok, command} =
        NodeCommand.start_placement(
          placement,
          identity.runner_name,
          :native_process,
          secret,
          @now_unix_ms,
          @now_unix_ms + 60_000
        )

      assert {:ok, ^command} =
               NodeMailbox.enqueue(ctx.mailbox, command, now_unix_ms: @now_unix_ms)

      assert ["dookie"] = NodeRegistry.prune_stale(ctx.registry, 20_000)
      assert {:ok, _} = reconcile(ctx.demand, 100)
      assert CrfController.DemandCoordinator.status(ctx.demand).orphaned_placements == []

      assert {:error, :placement_not_orphaned} =
               DemandCoordinator.force_abandon_placement(ctx.demand, identity.placement_id,
                 force: true,
                 now_ms: 500
               )

      assert {:ok, _} = reconcile(ctx.demand, 1_100)

      assert [orphan] =
               CrfController.DemandCoordinator.status(ctx.demand).orphaned_placements

      assert orphan.placement_id == identity.placement_id
      assert orphan.state == :commanded
      assert orphan.missing_for_ms == 1_000
      assert NodeMailbox.size(ctx.mailbox) == 1
      assert {:ok, still_live} = PlacementLedger.get(ctx.placements, identity.placement_id)
      assert still_live.state == :commanded
    end
  end

  test "force abandon requires explicit confirmation and terminalizes an orphan", ctx do
    unless ctx.disabled do
      {:ok, identity} = WorkIdentity.for_handle("build", 74, 802)

      assert {:ok, placement} =
               PlacementLedger.begin_placement(ctx.placements, placement_attrs(identity, 7),
                 now_ms: 50
               )

      {:ok, secret} = Secret.new("jit-config-802==")

      {:ok, command} =
        NodeCommand.start_placement(
          placement,
          identity.runner_name,
          :native_process,
          secret,
          @now_unix_ms,
          @now_unix_ms + 60_000
        )

      assert {:ok, ^command} =
               NodeMailbox.enqueue(ctx.mailbox, command, now_unix_ms: @now_unix_ms)

      :ok =
        FakeScaleSet.set_jit_states(ctx.scale_set, [
          %{
            pool_id: "build",
            scale_set_id: 74,
            work_handle: 802,
            state: "issued",
            descriptor_available: true
          }
        ])

      assert ["dookie"] = NodeRegistry.prune_stale(ctx.registry, 20_000)
      assert {:ok, _} = reconcile(ctx.demand, 100)
      assert {:ok, _} = reconcile(ctx.demand, 1_100)

      assert {:error, :explicit_force_required} =
               DemandCoordinator.force_abandon_placement(ctx.demand, identity.placement_id,
                 now_ms: 1_100
               )

      assert {:ok, %{placement: failed, jit_cleanup: :ok}} =
               DemandCoordinator.force_abandon_placement(ctx.demand, identity.placement_id,
                 force: true,
                 now_ms: 1_100
               )

      assert failed.state == :failed
      assert failed.detail_code == "operator_abandoned"
      assert NodeMailbox.size(ctx.mailbox) == 0
      sidecar = FakeScaleSet.state(ctx.scale_set)
      assert sidecar.retire_calls == 1
      assert sidecar.jit_states == []
      assert CrfController.DemandCoordinator.status(ctx.demand).orphaned_placements == []
    end
  end

  test "force abandon rechecks live node recovery instead of trusting stale orphan status", ctx do
    unless ctx.disabled do
      {:ok, identity} = WorkIdentity.for_handle("build", 74, 803)

      assert {:ok, _placement} =
               PlacementLedger.begin_placement(ctx.placements, placement_attrs(identity, 7),
                 now_ms: 50
               )

      assert ["dookie"] = NodeRegistry.prune_stale(ctx.registry, 20_000)
      assert {:ok, _} = reconcile(ctx.demand, 100)
      assert {:ok, _} = reconcile(ctx.demand, 1_100)
      assert [_orphan] = CrfController.DemandCoordinator.status(ctx.demand).orphaned_placements

      assert {:ok, _node} = register_node_generation(ctx.registry, 7)

      assert {:error, :placement_not_orphaned} =
               DemandCoordinator.force_abandon_placement(ctx.demand, identity.placement_id,
                 force: true,
                 now_ms: 1_200
               )

      assert {:ok, placement} = PlacementLedger.get(ctx.placements, identity.placement_id)
      assert placement.state == :commanded
      assert CrfController.DemandCoordinator.status(ctx.demand).orphaned_placements == []
    end
  end

  test "scale-set transport failure resets session activation and the next tick reapplies sessions",
       ctx do
    unless ctx.disabled do
      assert {:ok, _} = reconcile(ctx.demand, 100)
      assert FakeScaleSet.state(ctx.scale_set).apply_calls == 1
      assert CrfController.DemandCoordinator.status(ctx.demand).sessions_active

      :ok = FakeScaleSet.fail_next_snapshot(ctx.scale_set)
      assert {:error, {:scaleset_transport, :closed}} = reconcile(ctx.demand, 200)
      refute CrfController.DemandCoordinator.status(ctx.demand).sessions_active

      assert {:ok, _} = reconcile(ctx.demand, 300)
      assert FakeScaleSet.state(ctx.scale_set).apply_calls == 2
      assert CrfController.DemandCoordinator.status(ctx.demand).sessions_active
    end
  end

  test "planning waits until every configured pool session is healthy", ctx do
    unless ctx.disabled do
      :ok =
        FakeScaleSet.add_pool(ctx.scale_set, %{
          pool_id: "other",
          scale_set_id: 75,
          assigned_jobs: 0,
          advertised_capacity: 0,
          last_message_id: 0,
          session_healthy: false,
          acquired_handles: []
        })

      demand =
        start_supervised!(
          Supervisor.child_spec(
            {DemandCoordinator,
             name: nil,
             policies: [policy(2), %{policy(1) | id: "other"}],
             scale_set_client: ctx.scale_set,
             scheduler_client: ctx.scheduler,
             node_registry: ctx.registry,
             placement_ledger: ctx.placements,
             offer_ledger: ctx.offers,
             node_mailbox: ctx.mailbox,
             placement_coordinator: ctx.coordinator,
             placement_loss_grace_ms: 1_000,
             max_new_offers_per_tick: 1},
            id: :session_barrier_demand
          )
        )

      assert {:ok, waiting} = reconcile(demand, 100)
      assert waiting.offers == 0
      assert waiting.leases == %{"build" => 0, "other" => 0}

      :ok = FakeScaleSet.set_pool_health(ctx.scale_set, "other", true)
      assert {:ok, ready} = reconcile(demand, 200)
      assert ready.offers == 1
      assert ready.leases == %{"build" => 1, "other" => 0}
    end
  end

  test "planning rotates past an unplaceable pool to advertise a feasible pool", ctx do
    unless ctx.disabled do
      :ok =
        FakeScaleSet.add_pool(ctx.scale_set, %{
          pool_id: "blocked",
          scale_set_id: 75,
          assigned_jobs: 0,
          advertised_capacity: 0,
          last_message_id: 0,
          session_healthy: true,
          acquired_handles: []
        })

      blocked =
        policy(1)
        |> Map.put(:id, "blocked")
        |> Map.put(:required_backend, :container)
        |> Map.put(:required_capabilities, ["container", "github-actions"])

      demand =
        start_supervised!(
          Supervisor.child_spec(
            {DemandCoordinator,
             name: nil,
             policies: [blocked, policy(1)],
             scale_set_client: ctx.scale_set,
             scheduler_client: ctx.scheduler,
             node_registry: ctx.registry,
             placement_ledger: ctx.placements,
             offer_ledger: ctx.offers,
             node_mailbox: ctx.mailbox,
             placement_coordinator: ctx.coordinator,
             placement_loss_grace_ms: 1_000,
             max_new_offers_per_tick: 1},
            id: :eligible_node_barrier_demand
          )
        )

      assert {:ok, waiting} = reconcile(demand, 100)
      assert waiting.offers == 0
      assert waiting.leases == %{"blocked" => 0, "build" => 0}

      assert {:ok, ready} = reconcile(demand, 200)
      assert ready.offers == 1
      assert ready.leases == %{"blocked" => 0, "build" => 1}
    end
  end

  test "ambiguous JIT tombstone is retired before new capacity is offered", ctx do
    unless ctx.disabled do
      historical_revision = String.duplicate("c", 64)
      :ok = FakeScaleSet.set_assigned_jobs(ctx.scale_set, 2)

      :ok =
        FakeScaleSet.set_jit_states(ctx.scale_set, [
          %{
            pool_id: "build",
            scale_set_id: 74,
            work_handle: 601,
            state: "issue_started",
            ownership_revision: historical_revision,
            descriptor_available: false
          }
        ])

      assert {:ok, result} = reconcile(ctx.demand, 100)
      assert result.leases == %{"build" => 2}
      sidecar = FakeScaleSet.state(ctx.scale_set)
      assert sidecar.retire_calls == 1
      assert sidecar.last_retire_payload["expected_ownership_revision"] == historical_revision
      assert sidecar.jit_states == []
    end
  end

  test "durable retired proof is confirmed directly with its historical ownership fence", ctx do
    unless ctx.disabled do
      historical_revision = String.duplicate("c", 64)
      {:ok, identity} = WorkIdentity.for_handle("build", 74, 602)

      assert {:ok, _placement} =
               PlacementLedger.begin_placement(ctx.placements, placement_attrs(identity, 7),
                 now_ms: 90
               )

      :ok =
        FakeScaleSet.set_jit_states(ctx.scale_set, [
          %{
            pool_id: "build",
            scale_set_id: 74,
            work_handle: 602,
            state: "retired",
            ownership_revision: historical_revision,
            descriptor_available: false
          }
        ])

      assert {:ok, _result} = reconcile(ctx.demand, 100)

      sidecar = FakeScaleSet.state(ctx.scale_set)
      assert sidecar.retire_calls == 0
      assert sidecar.confirm_calls == 1
      assert sidecar.last_confirm_payload["expected_ownership_revision"] == historical_revision
      assert sidecar.jit_states == []
      assert {:ok, placement} = PlacementLedger.get(ctx.placements, identity.placement_id)
      assert placement.state == :failed
      assert placement.detail_code == "jit_retired"
    end
  end

  defp reconcile(server, now_ms) do
    DemandCoordinator.reconcile(server,
      now_ms: now_ms,
      now_unix_ms: @now_unix_ms + now_ms,
      timeout: 10_000
    )
  end

  defp register_node(registry), do: register_node_generation(registry, 7)

  defp register_node_generation(registry, generation) do
    NodeRegistry.register(
      registry,
      %{
        id: "dookie",
        generation: generation,
        os: :linux,
        arch: :x86_64,
        execution_backends: [:native_process],
        capabilities: ["github-actions"],
        total: %{cpu_millis: 8_000, memory_bytes: 16 * @gib},
        available: %{cpu_millis: 8_000, memory_bytes: 16 * @gib}
      },
      now_ms: 1
    )
  end

  defp placement_attrs(identity, generation) do
    %{
      id: identity.placement_id,
      command_id: identity.command_id,
      idempotency_key: identity.idempotency_key,
      node_id: "dookie",
      node_generation: generation,
      work_id: identity.work_id,
      pool_id: "build",
      resources: %{cpu_millis: 2_000, memory_bytes: 4 * @gib}
    }
  end

  defp policy(max_concurrency) do
    %{
      id: "build",
      max_concurrency: max_concurrency,
      resources: %{cpu_millis: 2_000, memory_bytes: 4 * @gib},
      required_os: :linux,
      required_arch: :x86_64,
      required_backend: :native_process,
      required_capabilities: ["github-actions"],
      work_folder: "_work"
    }
  end
end
