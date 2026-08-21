defmodule CrfController.PlacementStateStoreTest do
  use ExUnit.Case, async: true

  alias CrfController.{PlacementLedger, PlacementTombstone}

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
    assert decoded["schema_version"] == 2
    assert decoded["placements"] == []

    assert [["placement-1", "command-1", digest, "dookie", 7, "finished", :null]] =
             decoded["tombstones"]

    assert digest == PlacementTombstone.digest("idempotency-1")
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

  test "legacy schema v1 terminal placement loads as tombstone and late ACK upgrades to v2" do
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
    assert decoded["schema_version"] == 2
    assert decoded["placements"] == []
    assert length(decoded["tombstones"]) == 1

    GenServer.stop(ledger)
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
