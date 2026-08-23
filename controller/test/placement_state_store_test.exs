defmodule CrfController.PlacementStateStoreTest do
  use ExUnit.Case, async: true

  alias CrfController.{PlacementLedger, PlacementStateStore, PlacementTombstone}

  test "terminal placement compacts to a durable replay tombstone" do
    root =
      Path.join(System.tmp_dir!(), "crf-placement-state-#{System.unique_integer([:positive])}")

    path = Path.join(root, "placements.json")

    {:ok, first} = PlacementLedger.start_link(name: nil, state_path: path)
    attrs = placement_attrs()
    assert {:ok, _} = PlacementLedger.begin_placement(first, attrs, now_ms: 10)

    assert {:ok, finished} =
             PlacementLedger.placement_update(
               first,
               "dookie",
               7,
               "placement-1",
               "command-1",
               :finished,
               nil,
               now_ms: 20
             )

    assert finished.state == :finished
    assert PlacementLedger.snapshot(first) == []

    assert [%PlacementTombstone{id: "placement-1", state: :finished}] =
             PlacementLedger.tombstone_snapshot(first)

    GenServer.stop(first)

    {:ok, second} = PlacementLedger.start_link(name: nil, state_path: path)
    assert {:ok, %PlacementTombstone{} = restored} = PlacementLedger.get(second, "placement-1")
    assert restored.state == :finished
    assert restored.command_id == "command-1"
    assert restored.idempotency_sha256 == PlacementTombstone.digest("idempotency-1")
    assert PlacementLedger.snapshot(second) == []

    decoded = path |> File.read!() |> :json.decode()
    assert decoded["schema_version"] == 3
    assert decoded["placements"] == []

    assert [["placement-1", "command-1", digest, "dookie", 7, "finished", :null, retained_at]] =
             decoded["tombstones"]

    assert digest == PlacementTombstone.digest("idempotency-1")
    assert retained_at > 1_000_000_000_000
    encoded = File.read!(path)
    refute encoded =~ "resources"
    refute encoded =~ "work_id"
    refute encoded =~ "pool_id"

    assert {:ok, stat} = File.stat(path)
    assert stat.type == :regular
    if elem(:os.type(), 0) != :win32, do: assert(Bitwise.band(stat.mode, 0o777) == 0o600)

    GenServer.stop(second)
    File.rm_rf!(root)
  end

  test "legacy schema v1 terminal placement loads as tombstone and late ACK upgrades to v3" do
    root =
      Path.join(System.tmp_dir!(), "crf-placement-v1-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    path = Path.join(root, "placements.json")
    File.write!(path, :json.encode(legacy_terminal_state()) |> IO.iodata_to_binary())
    File.chmod!(path, 0o600)

    {:ok, ledger} = PlacementLedger.start_link(name: nil, state_path: path)

    assert {:ok, %PlacementTombstone{state: :finished}} =
             PlacementLedger.get(ledger, "placement-1")

    assert {:ok, %PlacementTombstone{state: :finished}} =
             PlacementLedger.command_ack(
               ledger,
               "dookie",
               7,
               "command-1",
               "idempotency-1",
               :duplicate,
               nil,
               now_ms: 30
             )

    decoded = path |> File.read!() |> :json.decode()
    assert decoded["schema_version"] == 3
    assert decoded["placements"] == []
    assert length(decoded["tombstones"]) == 1

    GenServer.stop(ledger)
    File.rm_rf!(root)
  end

  test "tombstone replay fences are retained until a newer node generation is durable" do
    root =
      Path.join(System.tmp_dir!(), "crf-placement-compact-#{System.unique_integer([:positive])}")

    path = Path.join(root, "placements.json")

    tombstones =
      Map.new(0..8_192, fn index ->
        id = "placement-#{index}"

        {id,
         %PlacementTombstone{
           id: id,
           command_id: "command-#{index}",
           idempotency_sha256: PlacementTombstone.digest("key-#{index}"),
           node_id: "dookie",
           node_generation: 7,
           state: :finished,
           detail_code: nil,
           updated_at_ms: index
         }}
      end)

    compacted = PlacementStateStore.compact(%{}, tombstones)
    assert map_size(compacted.tombstones) == 8_193
    assert Map.has_key?(compacted.tombstones, "placement-0")
    assert Map.has_key?(compacted.tombstones, "placement-8192")
    assert :ok = PlacementStateStore.persist(path, %{}, compacted.tombstones)

    {:ok, ledger} = PlacementLedger.start_link(name: nil, state_path: path)

    assert {:ok, %PlacementTombstone{}} =
             PlacementLedger.command_ack(
               ledger,
               "dookie",
               7,
               "command-8192",
               "key-8192",
               :duplicate,
               nil,
               now_ms: 9_000
             )

    assert {:ok, %PlacementTombstone{}} = PlacementLedger.get(ledger, "placement-0")
    assert :ok = PlacementLedger.prune_before_generation(ledger, "dookie", 8)
    assert [] = PlacementLedger.tombstone_snapshot(ledger)
    assert {:error, :unknown_placement} = PlacementLedger.get(ledger, "placement-0")
    GenServer.stop(ledger)
    File.rm_rf!(root)
  end

  test "fresh post-restart tombstone does not evict existing replay fences" do
    root =
      Path.join(
        System.tmp_dir!(),
        "crf-placement-restart-order-#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "placements.json")

    persisted =
      Map.new(1..8_192, fn index ->
        id = "old-placement-#{index}"

        {id,
         %PlacementTombstone{
           id: id,
           command_id: "old-command-#{index}",
           idempotency_sha256: PlacementTombstone.digest("old-key-#{index}"),
           node_id: "dookie",
           node_generation: 7,
           state: :finished,
           detail_code: nil,
           updated_at_ms: 1_000_000_000_000 + index
         }}
      end)

    assert :ok = PlacementStateStore.persist(path, %{}, persisted)
    {:ok, ledger} = PlacementLedger.start_link(name: nil, state_path: path)

    fresh =
      placement_attrs()
      |> Map.put(:id, "fresh-placement")
      |> Map.put(:command_id, "fresh-command")

    assert {:ok, _} = PlacementLedger.begin_placement(ledger, fresh, now_ms: 1)

    assert {:ok, _} =
             PlacementLedger.placement_update(
               ledger,
               "dookie",
               7,
               "fresh-placement",
               "fresh-command",
               :finished,
               nil,
               now_ms: 2
             )

    assert {:ok, %PlacementTombstone{}} = PlacementLedger.get(ledger, "fresh-placement")
    assert length(PlacementLedger.tombstone_snapshot(ledger)) == 8_193

    GenServer.stop(ledger)
    File.rm_rf!(root)
  end

  test "capacity rejects only new placements and preserves idempotent retries" do
    {:ok, ledger} = PlacementLedger.start_link(name: nil, record_capacity: 1)
    attrs = placement_attrs()

    assert {:ok, original} = PlacementLedger.begin_placement(ledger, attrs, now_ms: 1)
    assert {:ok, ^original} = PlacementLedger.begin_placement(ledger, attrs, now_ms: 2)

    assert {:error, :placement_state_capacity} =
             PlacementLedger.begin_placement(
               ledger,
               %{attrs | id: "placement-2", command_id: "command-2"},
               now_ms: 3
             )

    GenServer.stop(ledger)
  end

  test "persistence remains bounded at 10x 100x and 1000x record counts" do
    root =
      Path.join(System.tmp_dir!(), "crf-placement-scale-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    for count <- [10, 100, 1_000] do
      tombstones =
        Map.new(1..count, fn index ->
          id = "placement-#{index}"

          {id,
           %PlacementTombstone{
             id: id,
             command_id: "command-#{index}",
             idempotency_sha256: PlacementTombstone.digest("key-#{index}"),
             node_id: "dookie",
             node_generation: 7,
             state: :finished,
             detail_code: nil,
             updated_at_ms: index
           }}
        end)

      {elapsed_us, :ok} =
        :timer.tc(fn ->
          PlacementStateStore.persist(Path.join(root, "#{count}.json"), %{}, tombstones)
        end)

      assert elapsed_us < 2_000_000
    end

    File.rm_rf!(root)
  end

  test "hot-path mutations append bounded frames and recover through a torn journal tail" do
    root =
      Path.join(System.tmp_dir!(), "crf-placement-wal-#{System.unique_integer([:positive])}")

    path = Path.join(root, "placements.json")

    {:ok, ledger} =
      PlacementLedger.start_link(name: nil, state_path: path, checkpoint_bytes: 16_777_216)

    baseline_bytes = File.stat!(path).size

    {elapsed_us, :ok} =
      :timer.tc(fn ->
        for index <- 1..1_000 do
          attrs = %{
            placement_attrs()
            | id: "placement-#{index}",
              command_id: "command-#{index}",
              idempotency_key: "key-#{index}"
          }

          assert {:ok, _} = PlacementLedger.begin_placement(ledger, attrs, now_ms: index)
        end

        :ok
      end)

    assert File.stat!(path).size == baseline_bytes
    assert PlacementStateStore.journal_size(path) in 1..1_000_000
    # Includes one fsync per acknowledged mutation; guards against accidental
    # quadratic/full-snapshot work without depending on tmpfs-class latency.
    assert elapsed_us < 20_000_000
    GenServer.stop(ledger)

    File.write!(path <> ".wal", <<0, 0, 1>>, [:append])
    {:ok, recovered} = PlacementLedger.start_link(name: nil, state_path: path)
    assert length(PlacementLedger.snapshot(recovered)) == 1_000
    assert {:ok, %{command_id: "command-1000"}} = PlacementLedger.get(recovered, "placement-1000")
    assert PlacementStateStore.journal_size(path) == 0

    GenServer.stop(recovered)
    File.rm_rf!(root)
  end

  test "stale pre-checkpoint WAL cannot resurrect an acknowledged generation prune" do
    root =
      Path.join(
        System.tmp_dir!(),
        "crf-placement-prune-wal-#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "placements.json")

    old = %PlacementTombstone{
      id: "old",
      command_id: "old-command",
      idempotency_sha256: PlacementTombstone.digest("old-key"),
      node_id: "dookie",
      node_generation: 1,
      state: :finished,
      detail_code: nil,
      updated_at_ms: 10
    }

    current = %PlacementTombstone{
      id: "current",
      command_id: "current-command",
      idempotency_sha256: PlacementTombstone.digest("current-key"),
      node_id: "dookie",
      node_generation: 2,
      state: :finished,
      detail_code: nil,
      updated_at_ms: 20
    }

    assert :ok = PlacementStateStore.persist(path, %{}, %{old.id => old, current.id => current})
    assert :ok = PlacementStateStore.append(path, {:put, old})
    assert :ok = PlacementStateStore.append(path, {:put, current})
    assert :ok = PlacementStateStore.append(path, {:prune_before_generation, "dookie", 2})

    # Model a crash after the compacted snapshot is durable but before the old
    # WAL is unlinked: recovery must replay the durable prune after stale puts.
    assert :ok = PlacementStateStore.persist(path, %{}, %{current.id => current})
    assert {:ok, %{placements: %{}, tombstones: tombstones}} = PlacementStateStore.load(path)
    refute Map.has_key?(tombstones, old.id)
    assert Map.has_key?(tombstones, current.id)

    File.rm_rf!(root)
  end

  test "corrupt durable placement state fails closed on startup" do
    root =
      Path.join(System.tmp_dir!(), "crf-placement-corrupt-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    path = Path.join(root, "placements.json")
    File.write!(path, ~s({"schema_version":1,"placements":[{"surprise":true}]}))
    File.chmod!(path, 0o600)

    assert {:error, :invalid_placement_state} =
             GenServer.start(PlacementLedger, name: nil, state_path: path)

    File.rm_rf!(root)
  end

  test "malformed schema v2 tombstone fails closed" do
    root =
      Path.join(
        System.tmp_dir!(),
        "crf-placement-v2-corrupt-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    path = Path.join(root, "placements.json")

    invalid = %{
      "schema_version" => 2,
      "placements" => [],
      "tombstones" => [
        ["placement-1", "command-1", "not-a-digest", "dookie", 7, "finished", :null]
      ]
    }

    File.write!(path, :json.encode(invalid) |> IO.iodata_to_binary())
    File.chmod!(path, 0o600)

    assert {:error, :invalid_placement_state} =
             GenServer.start(PlacementLedger, name: nil, state_path: path)

    File.rm_rf!(root)
  end

  defp placement_attrs do
    %{
      id: "placement-1",
      command_id: "command-1",
      idempotency_key: "idempotency-1",
      node_id: "dookie",
      node_generation: 7,
      work_id: "work-1",
      pool_id: "build",
      resources: %{cpu_millis: 2_000, memory_bytes: 4 * 1024 * 1024 * 1024}
    }
  end

  defp legacy_terminal_state do
    %{
      "schema_version" => 1,
      "placements" => [
        %{
          "id" => "placement-1",
          "command_id" => "command-1",
          "idempotency_key" => "idempotency-1",
          "node_id" => "dookie",
          "node_generation" => 7,
          "work_id" => "work-1",
          "pool_id" => "build",
          "resources" => %{"cpu_millis" => 2_000, "memory_bytes" => 4 * 1024 * 1024 * 1024},
          "state" => "finished",
          "detail_code" => :null,
          "updated_at_ms" => 20
        }
      ]
    }
  end
end
