defmodule CrfController.NodeCommandTest do
  use ExUnit.Case, async: true

  alias CrfController.{NodeCommand, Placement, Secret, TestFixtures}

  @fixture Path.expand("../../tests/fixtures/distributed-controller-command-v1.json", __DIR__)

  test "Elixir emits the canonical command fixture consumed by Rust" do
    {:ok, placement} = Placement.new(TestFixtures.placement_attrs("steamy", 3), 10)
    {:ok, secret} = Secret.new("jit-config-abc123==")

    assert {:ok, command} =
             NodeCommand.start_placement(
               placement,
               "crf-steamy-1",
               :native_process,
               secret,
               1_787_070_000_000,
               1_787_070_030_000
             )

    assert {:ok, encoded} = NodeCommand.encode(command, 1_787_070_001_000)
    fixture = File.read!(@fixture)

    assert :json.decode(encoded) == :json.decode(fixture)
  end

  test "command and secret inspection redact JIT material" do
    {:ok, placement} = Placement.new(TestFixtures.placement_attrs("steamy", 3), 10)
    {:ok, secret} = Secret.new("jit-config-abc123==")

    {:ok, command} =
      NodeCommand.start_placement(
        placement,
        "crf-steamy-1",
        :native_process,
        secret,
        1_787_070_000_000,
        1_787_070_030_000
      )

    refute inspect(secret) =~ "jit-config-abc123=="
    refute inspect(command) =~ "jit-config-abc123=="
    assert inspect(command) =~ "[REDACTED]"
  end

  test "expired and overlong commands fail closed" do
    assert {:ok, command} =
             NodeCommand.set_drain(
               "dookie",
               7,
               "command-drain-1",
               "idempotency-drain-1",
               true,
               1_000,
               2_000
             )

    assert {:error, :invalid_or_expired_command} = NodeCommand.encode(command, 2_001)

    assert {:error, :invalid_command_lifetime} =
             NodeCommand.set_drain(
               "dookie",
               7,
               "command-drain-2",
               "idempotency-drain-2",
               true,
               1_000,
               301_001
             )
  end
end
