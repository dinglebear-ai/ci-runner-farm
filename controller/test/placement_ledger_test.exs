defmodule CrfController.PlacementLedgerTest do
  use ExUnit.Case, async: true

  alias CrfController.{PlacementLedger, TestFixtures}

  setup do
    ledger = start_supervised!({PlacementLedger, name: nil})
    %{ledger: ledger}
  end

  test "begin placement is idempotent but conflicting reuse fails", %{ledger: ledger} do
    attrs = TestFixtures.placement_attrs("dookie", 7)
    assert {:ok, first} = PlacementLedger.begin_placement(ledger, attrs, now_ms: 10)
    assert {:ok, replay} = PlacementLedger.begin_placement(ledger, attrs, now_ms: 20)
    assert first == replay

    conflict = %{attrs | work_id: "work-2"}

    assert {:error, :placement_conflict} =
             PlacementLedger.begin_placement(ledger, conflict, now_ms: 30)
  end

  test "out-of-order progress is monotonic and late ACKs do not regress state", %{ledger: ledger} do
    attrs = TestFixtures.placement_attrs("dookie", 7)
    assert {:ok, _} = PlacementLedger.begin_placement(ledger, attrs, now_ms: 10)

    assert {:ok, running} =
             PlacementLedger.placement_update(
               ledger,
               "dookie",
               7,
               "placement-1",
               "command-1",
               :running,
               nil,
               now_ms: 20
             )

    assert running.state == :running

    assert {:ok, after_late_ack} =
             PlacementLedger.command_ack(
               ledger,
               "dookie",
               7,
               "command-1",
               "idempotency-1",
               :accepted,
               nil,
               now_ms: 30
             )

    assert after_late_ack.state == :running
  end

  test "generation fencing rejects updates from a previous node incarnation", %{ledger: ledger} do
    attrs = TestFixtures.placement_attrs("dookie", 7)
    assert {:ok, _} = PlacementLedger.begin_placement(ledger, attrs, now_ms: 10)

    assert {:error, :generation_mismatch} =
             PlacementLedger.placement_update(
               ledger,
               "dookie",
               6,
               "placement-1",
               "command-1",
               :running,
               nil,
               now_ms: 20
             )
  end

  test "terminal placement state cannot be rewritten", %{ledger: ledger} do
    attrs = TestFixtures.placement_attrs("dookie", 7)
    assert {:ok, _} = PlacementLedger.begin_placement(ledger, attrs, now_ms: 10)

    assert {:ok, finished} =
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

    assert finished.state == :finished

    assert {:error, :terminal_state_conflict} =
             PlacementLedger.placement_update(
               ledger,
               "dookie",
               7,
               "placement-1",
               "command-1",
               :failed,
               "late_failure",
               now_ms: 30
             )
  end
end
