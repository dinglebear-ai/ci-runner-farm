defmodule CrfController.NodeMailboxTest do
  use ExUnit.Case, async: true

  alias CrfController.{NodeCommand, NodeMailbox}

  setup do
    mailbox = start_supervised!({NodeMailbox, name: nil, capacity: 4})
    %{mailbox: mailbox}
  end

  test "pending command remains visible until a matching ACK is committed", %{mailbox: mailbox} do
    command = drain_command("dookie", 7, "command-1", "idempotency-1", 10_000)
    assert {:ok, ^command} = NodeMailbox.enqueue(mailbox, command, now_unix_ms: 2_000)

    assert {:ok, ^command} = NodeMailbox.next_for(mailbox, "dookie", 7, now_unix_ms: 2_100)
    assert {:ok, ^command} = NodeMailbox.next_for(mailbox, "dookie", 7, now_unix_ms: 2_200)
    assert NodeMailbox.size(mailbox) == 1

    assert {:ok, ^command} =
             NodeMailbox.prepare_ack(
               mailbox,
               "dookie",
               7,
               "command-1",
               "idempotency-1",
               :accepted
             )

    assert NodeMailbox.size(mailbox) == 1

    assert {:error, :idempotency_key_mismatch} =
             NodeMailbox.commit_ack(mailbox, "command-1", "wrong-idempotency")

    assert NodeMailbox.size(mailbox) == 1
    assert {:ok, ^command} = NodeMailbox.commit_ack(mailbox, "command-1", "idempotency-1")
    assert NodeMailbox.size(mailbox) == 0
    assert {:ok, nil} = NodeMailbox.next_for(mailbox, "dookie", 7, now_unix_ms: 2_300)
  end

  test "node identity and generation fence delivery and ACK preparation", %{mailbox: mailbox} do
    command = drain_command("steamy", 3, "command-2", "idempotency-2", 10_000)
    assert {:ok, ^command} = NodeMailbox.enqueue(mailbox, command, now_unix_ms: 2_000)

    assert {:ok, nil} = NodeMailbox.next_for(mailbox, "steamy", 2, now_unix_ms: 2_100)
    assert {:ok, nil} = NodeMailbox.next_for(mailbox, "dookie", 3, now_unix_ms: 2_100)

    assert {:error, :generation_mismatch} =
             NodeMailbox.prepare_ack(
               mailbox,
               "steamy",
               2,
               "command-2",
               "idempotency-2",
               :accepted
             )

    assert {:error, :node_identity_mismatch} =
             NodeMailbox.prepare_ack(
               mailbox,
               "dookie",
               3,
               "command-2",
               "idempotency-2",
               :accepted
             )

    assert NodeMailbox.size(mailbox) == 1
  end

  test "expired commands are purged even when they are behind another node's live command", %{
    mailbox: mailbox
  } do
    live = drain_command("dookie", 7, "command-live", "idempotency-live", 20_000)
    expired = drain_command("steamy", 3, "command-expired", "idempotency-expired", 3_000)

    assert {:ok, ^live} = NodeMailbox.enqueue(mailbox, live, now_unix_ms: 2_000)
    assert {:ok, ^expired} = NodeMailbox.enqueue(mailbox, expired, now_unix_ms: 2_000)
    assert NodeMailbox.size(mailbox) == 2

    assert {:ok, nil} = NodeMailbox.next_for(mailbox, "steamy", 3, now_unix_ms: 3_001)
    assert NodeMailbox.size(mailbox) == 1
    assert {:ok, ^live} = NodeMailbox.next_for(mailbox, "dookie", 7, now_unix_ms: 3_001)
  end

  test "a full mailbox rejects new work without evicting pending commands" do
    mailbox = start_supervised!({NodeMailbox, name: nil, capacity: 2}, id: :small_mailbox)
    first = drain_command("dookie", 7, "command-a", "idempotency-a", 10_000)
    second = drain_command("steamy", 3, "command-b", "idempotency-b", 10_000)
    third = drain_command("squirts", 1, "command-c", "idempotency-c", 10_000)

    assert {:ok, ^first} = NodeMailbox.enqueue(mailbox, first, now_unix_ms: 2_000)
    assert {:ok, ^second} = NodeMailbox.enqueue(mailbox, second, now_unix_ms: 2_000)
    assert {:error, :mailbox_full} = NodeMailbox.enqueue(mailbox, third, now_unix_ms: 2_000)

    assert NodeMailbox.size(mailbox) == 2
    assert {:ok, ^first} = NodeMailbox.next_for(mailbox, "dookie", 7, now_unix_ms: 2_100)
    assert {:ok, ^second} = NodeMailbox.next_for(mailbox, "steamy", 3, now_unix_ms: 2_100)
  end

  test "expiry reclaims capacity without polling that node" do
    mailbox = start_supervised!({NodeMailbox, name: nil, capacity: 1}, id: :expiring_mailbox)
    now = System.system_time(:millisecond)

    {:ok, expiring} =
      NodeCommand.set_drain("unpolled", 1, "expiring", "expiring-key", true, now, now + 25)

    {:ok, replacement} =
      NodeCommand.set_drain(
        "dookie",
        7,
        "replacement",
        "replacement-key",
        true,
        now,
        now + 5_000
      )

    assert {:ok, ^expiring} = NodeMailbox.enqueue(mailbox, expiring, now_unix_ms: now)
    assert {:error, :mailbox_full} = NodeMailbox.enqueue(mailbox, replacement, now_unix_ms: now)
    Process.sleep(40)
    assert {:ok, ^replacement} = NodeMailbox.enqueue(mailbox, replacement, now_unix_ms: now + 40)
  end

  test "exact enqueue retry is idempotent but command ID reuse with changed payload is rejected",
       %{
         mailbox: mailbox
       } do
    command = drain_command("dookie", 7, "command-3", "idempotency-3", 10_000)
    changed = %{command | payload: {:set_drain, false}}

    assert {:ok, ^command} = NodeMailbox.enqueue(mailbox, command, now_unix_ms: 2_000)
    assert {:ok, ^command} = NodeMailbox.enqueue(mailbox, command, now_unix_ms: 2_100)

    assert {:error, :command_id_conflict} =
             NodeMailbox.enqueue(mailbox, changed, now_unix_ms: 2_100)

    assert NodeMailbox.size(mailbox) == 1
  end

  test "lookup and ACK work do not walk commands belonging to unrelated nodes" do
    mailbox = start_supervised!({NodeMailbox, name: nil, capacity: 20_000}, id: :large_mailbox)

    for index <- 1..10_000 do
      command =
        drain_command("other-#{index}", 1, "other-command-#{index}", "other-key-#{index}", 20_000)

      assert {:ok, _} = NodeMailbox.enqueue(mailbox, command, now_unix_ms: 2_000)
    end

    target = drain_command("dookie", 7, "target-command", "target-key", 20_000)
    assert {:ok, ^target} = NodeMailbox.enqueue(mailbox, target, now_unix_ms: 2_000)

    {lookup_us, {:ok, ^target}} =
      :timer.tc(fn -> NodeMailbox.next_for(mailbox, "dookie", 7, now_unix_ms: 2_100) end)

    {ack_us, {:ok, ^target}} =
      :timer.tc(fn ->
        NodeMailbox.ack(mailbox, "dookie", 7, "target-command", "target-key", :accepted)
      end)

    assert lookup_us < 100_000
    assert ack_us < 100_000
    assert NodeMailbox.size(mailbox) == 10_000
  end

  test "acknowledged identifiers are compacted for a generation that remains live" do
    mailbox = start_supervised!({NodeMailbox, name: nil, capacity: 4}, id: :compacting_mailbox)
    sentinel = drain_command("offline", 9, "sentinel", "sentinel-key", 300_000)
    assert {:ok, ^sentinel} = NodeMailbox.enqueue(mailbox, sentinel, now_unix_ms: 2_000)

    for index <- 1..1_000 do
      command = drain_command("offline", 9, "churn-#{index}", "key-#{index}", 300_000)
      assert {:ok, ^command} = NodeMailbox.enqueue(mailbox, command, now_unix_ms: 2_000)

      assert {:ok, ^command} =
               NodeMailbox.ack(
                 mailbox,
                 "offline",
                 9,
                 command.command_id,
                 command.idempotency_key,
                 :accepted
               )
    end

    state = :sys.get_state(mailbox)
    assert :queue.len(Map.fetch!(state.node_queues, {"offline", 9})) <= 64
    assert state.queue_counts[{"offline", 9}] == 1
  end

  defp drain_command(node_id, generation, command_id, idempotency_key, expires_at_unix_ms) do
    {:ok, command} =
      NodeCommand.set_drain(
        node_id,
        generation,
        command_id,
        idempotency_key,
        true,
        1_000,
        expires_at_unix_ms
      )

    command
  end
end
