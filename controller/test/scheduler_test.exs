defmodule CrfController.SchedulerTest do
  use ExUnit.Case, async: false

  alias CrfController.{NodeRegistry, PlacementLedger, Scheduler, SchedulerClient}

  @gib 1024 * 1024 * 1024

  test "Rust scheduler sees controller shadow reservations exactly until heartbeat owns them" do
    case System.get_env("CRF_SCHEDULER_BIN") do
      nil ->
        assert true

      executable ->
        registry = start_supervised!({NodeRegistry, name: nil, stale_after_ms: 10_000})
        placements = start_supervised!({PlacementLedger, name: nil})

        client =
          start_supervised!(
            {SchedulerClient, name: nil, executable: executable, request_timeout_ms: 5_000}
          )

        assert {:ok, _} =
                 NodeRegistry.register(
                   registry,
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
                   now_ms: 1
                 )

        assert {:ok, _} =
                 PlacementLedger.begin_placement(
                   placements,
                   %{
                     id: "placement-1",
                     command_id: "command-1",
                     idempotency_key: "idem-1",
                     node_id: "dookie",
                     node_generation: 7,
                     work_id: "reserved-work",
                     pool_id: "build",
                     resources: %{cpu_millis: 6_000, memory_bytes: 12 * @gib}
                   },
                   now_ms: 2
                 )

        opts = [node_registry: registry, placement_ledger: placements, scheduler_client: client]
        assert {:ok, %{placements: [%{node_id: "dookie"}]}} = Scheduler.schedule([work()], opts)

        assert {:ok, _} =
                 NodeRegistry.heartbeat(
                   registry,
                   "dookie",
                   7,
                   %{cpu_millis: 2_000, memory_bytes: 4 * @gib},
                   active_placements: MapSet.new(["placement-1"]),
                   now_ms: 3
                 )

        assert {:ok, %{placements: [%{node_id: "dookie"}]}} = Scheduler.schedule([work()], opts)
    end
  end

  defp work do
    %{
      work_id: "new-work",
      pool_id: "build",
      resources: %{cpu_millis: 1_000, memory_bytes: 2 * @gib},
      required_os: :linux,
      required_arch: :x86_64,
      required_backend: :native_process,
      required_capabilities: ["github-actions"]
    }
  end
end
