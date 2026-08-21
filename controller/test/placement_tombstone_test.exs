defmodule CrfController.PlacementTombstoneTest do
  use ExUnit.Case, async: true

  alias CrfController.{PlacementLedger, PlacementTombstone}

  test "terminal compaction permanently fences placement and command identifiers" do
    ledger = start_supervised!({PlacementLedger, name: nil})
    attrs = placement_attrs("placement-1", "command-1")

    assert {:ok, _} = PlacementLedger.begin_placement(ledger, attrs, now_ms: 10)

    assert {:ok, _} =
             PlacementLedger.placement_update(
               ledger,
               "dookie",
               7,
               "placement-1",
               "command-1",
               :finished,
               nil,
               now_ms: 20
             )

    assert {:ok, %PlacementTombstone{state: :finished}} =
             PlacementLedger.get(ledger, "placement-1")

    assert {:error, :placement_terminal} =
             PlacementLedger.begin_placement(ledger, attrs, now_ms: 30)

    reused_command = placement_attrs("placement-2", "command-1")

    assert {:error, :command_id_conflict} =
             PlacementLedger.begin_placement(ledger, reused_command, now_ms: 30)
  end

  test "late duplicate ACK and same terminal update remain accepted after compaction" do
    ledger = start_supervised!({PlacementLedger, name: nil})
    attrs = placement_attrs("placement-1", "command-1")
    assert {:ok, _} = PlacementLedger.begin_placement(ledger, attrs, now_ms: 10)

    assert {:ok, _} =
             PlacementLedger.placement_update(
               ledger,
               "dookie",
               7,
               "placement-1",
               "command-1",
               :finished,
               nil,
               now_ms: 20
             )

    assert {:ok, %PlacementTombstone{state: :finished}} =
             PlacementLedger.command_ack(
               ledger,
               "dookie",
               7,
               "command-1",
               "idempotency-1",
               :duplicate,
               nil,
               now_ms: 21
             )

    assert {:ok, %PlacementTombstone{node_generation: 8, state: :finished}} =
             PlacementLedger.placement_update(
               ledger,
               "dookie",
               8,
               "placement-1",
               "command-1",
               :finished,
               nil,
               now_ms: 22
             )

    assert {:error, :terminal_state_conflict} =
             PlacementLedger.placement_update(
               ledger,
               "dookie",
               8,
               "placement-1",
               "command-1",
               :failed,
               "contradiction",
               now_ms: 23
             )
  end

  test "late ACK identity remains generation and idempotency fenced" do
    ledger = start_supervised!({PlacementLedger, name: nil})
    attrs = placement_attrs("placement-1", "command-1")
    assert {:ok, _} = PlacementLedger.begin_placement(ledger, attrs, now_ms: 10)

    assert {:ok, _} =
             PlacementLedger.fail_placement(ledger, "placement-1", "runner_failed", now_ms: 20)

    assert {:error, :generation_mismatch} =
             PlacementLedger.command_ack(
               ledger,
               "dookie",
               8,
               "command-1",
               "idempotency-1",
               :duplicate,
               nil,
               now_ms: 21
             )

    assert {:error, :idempotency_key_mismatch} =
             PlacementLedger.command_ack(
               ledger,
               "dookie",
               7,
               "command-1",
               "different-idem",
               :duplicate,
               nil,
               now_ms: 21
             )
  end

  defp placement_attrs(placement_id, command_id) do
    %{
      id: placement_id,
      command_id: command_id,
      idempotency_key: "idempotency-1",
      node_id: "dookie",
      node_generation: 7,
      work_id: "work-1",
      pool_id: "build",
      resources: %{cpu_millis: 2_000, memory_bytes: 4 * 1024 * 1024 * 1024}
    }
  end
end
