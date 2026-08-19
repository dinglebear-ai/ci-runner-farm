defmodule CrfController.PlacementStateStoreTest do
  use ExUnit.Case, async: true

  alias CrfController.PlacementLedger

  test "terminal placement state survives a fresh ledger process" do
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
    GenServer.stop(first)

    {:ok, second} = PlacementLedger.start_link(name: nil, state_path: path)
    assert {:ok, restored} = PlacementLedger.get(second, "placement-1")
    assert restored.state == :finished
    assert restored.command_id == "command-1"
    assert restored.resources.cpu_millis == 2_000

    assert {:ok, stat} = File.stat(path)
    assert stat.type == :regular
    if elem(:os.type(), 0) != :win32, do: assert(Bitwise.band(stat.mode, 0o777) == 0o600)

    GenServer.stop(second)
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
end
