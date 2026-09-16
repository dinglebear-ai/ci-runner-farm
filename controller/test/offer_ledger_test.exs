defmodule CrfController.OfferLedgerTest do
  use ExUnit.Case, async: true

  alias CrfController.OfferLedger

  @gib 1024 * 1024 * 1024

  setup do
    ledger = start_supervised!({OfferLedger, name: nil, capacity: 8})
    %{ledger: ledger}
  end

  test "offer assignment is deterministic and consumed exactly once", %{ledger: ledger} do
    assert {:ok, first} = OfferLedger.reserve(ledger, attrs("offer-a"), now_ms: 10)
    assert {:ok, _second} = OfferLedger.reserve(ledger, attrs("offer-b"), now_ms: 11)

    assert {:ok, assigned} = OfferLedger.assign_next(ledger, "build", 101, now_ms: 12)
    assert assigned.id == first.id
    assert assigned.state == :assigned
    assert assigned.work_handle == 101
    assert assigned.scale_set_id == 74

    assert {:ok, ^assigned} = OfferLedger.assign_next(ledger, "build", 101, now_ms: 13)
    assert {:ok, ^assigned} = OfferLedger.consume(ledger, assigned.id, 101)
    assert {:error, :unknown_offer} = OfferLedger.consume(ledger, assigned.id, 101)
  end

  test "assigned offer cannot expire while its work handle is in flight", %{ledger: ledger} do
    assert {:ok, _} = OfferLedger.reserve(ledger, attrs("offer-a", 20), now_ms: 10)
    assert {:ok, assigned} = OfferLedger.assign_next(ledger, "build", 101, now_ms: 11)

    assert [%{id: id, state: :assigned}] = OfferLedger.snapshot(ledger, now_ms: 100)
    assert id == assigned.id
  end

  test "expired unassigned offers are pruned", %{ledger: ledger} do
    assert {:ok, _} = OfferLedger.reserve(ledger, attrs("offer-a", 20), now_ms: 10)
    assert OfferLedger.snapshot(ledger, now_ms: 21) == []
  end

  test "one pool work handle cannot own two offers", %{ledger: ledger} do
    assert {:ok, first} =
             OfferLedger.reserve_assigned(ledger, attrs("offer-a"), 101, now_ms: 10)

    assert first.work_handle == 101

    assert {:error, :work_handle_already_offered} =
             OfferLedger.reserve_assigned(ledger, attrs("offer-b"), 101, now_ms: 11)
  end

  test "recovery may create an already assigned node reservation", %{ledger: ledger} do
    assert {:ok, offer} =
             OfferLedger.reserve_assigned(ledger, attrs("offer-recovery"), 901, now_ms: 10)

    assert offer.state == :assigned
    assert {:ok, ^offer} = OfferLedger.find_by_handle(ledger, "build", 901)
  end

  test "scale-set identity must be positive", %{ledger: ledger} do
    for scale_set_id <- [0, -1] do
      invalid = Map.put(attrs("offer-#{scale_set_id}"), :scale_set_id, scale_set_id)
      assert {:error, :invalid_offer} = OfferLedger.reserve(ledger, invalid, now_ms: 10)
    end
  end

  test "scale-set identity participates in reservation replay equality", %{ledger: ledger} do
    assert {:ok, %{scale_set_id: 74}} =
             OfferLedger.reserve(ledger, attrs("offer-a"), now_ms: 10)

    conflicting = Map.put(attrs("offer-a"), :scale_set_id, 75)
    assert {:error, :offer_conflict} = OfferLedger.reserve(ledger, conflicting, now_ms: 11)
  end

  defp attrs(id, expires_at_ms \\ 100) do
    %{
      id: id,
      pool_id: "build",
      scale_set_id: 74,
      node_id: "dookie",
      node_generation: 7,
      resources: %{cpu_millis: 2_000, memory_bytes: 4 * @gib},
      expires_at_ms: expires_at_ms
    }
  end
end
