defmodule CrfController.ScaleSetWireTest do
  use ExUnit.Case, async: true

  alias CrfController.{ScaleSetWire, Secret}

  @revision String.duplicate("a", 64)

  test "encodes strict versioned request and rejects malformed revisions" do
    assert {:ok, binary} =
             ScaleSetWire.encode_request(
               "scaleset-1",
               "read_snapshot",
               @revision,
               @revision,
               "controller-1",
               1,
               %{}
             )

    decoded = :json.decode(binary)
    assert decoded["schema_version"] == 1
    assert decoded["request_id"] == "scaleset-1"
    assert decoded["sequence"] == 1
    assert decoded["operation"] == "read_snapshot"

    assert {:error, :invalid_scaleset_request} =
             ScaleSetWire.encode_request(
               "scaleset-2",
               "read_snapshot",
               String.duplicate("A", 64),
               @revision,
               "controller-1",
               2,
               %{}
             )
  end

  test "JIT descriptor becomes a redacted Secret immediately" do
    descriptor = "jit-config-super-secret=="

    assert {:ok, %{descriptor: %Secret{} = secret, scale_set_id: 74}} =
             ScaleSetWire.decode_jit_result(%{
               "descriptor" => descriptor,
               "scale_set_id" => 74
             })

    assert Secret.expose(secret) == descriptor
    refute inspect(secret) =~ descriptor
    assert inspect(secret) =~ "[REDACTED]"
  end

  test "non-secret JIT state metadata parses strictly" do
    assert {:ok,
            [
              %{
                pool_id: "build",
                scale_set_id: 74,
                work_handle: 101,
                state: "issued",
                ownership_revision: @revision,
                descriptor_available: true
              }
            ]} =
             ScaleSetWire.decode_jit_states(%{
               "states" => [
                 %{
                   "pool_id" => "build",
                   "scale_set_id" => 74,
                   "work_handle" => 101,
                   "state" => "issued",
                   "ownership_revision" => @revision,
                   "descriptor_available" => true
                 }
               ]
             })

    assert {:error, :invalid_jit_state_response} =
             ScaleSetWire.decode_jit_states(%{
               "states" => [
                 %{
                   "pool_id" => "build",
                   "scale_set_id" => 74,
                   "work_handle" => 101,
                   "state" => "issued",
                   "ownership_revision" => @revision,
                   "descriptor_available" => true,
                   "descriptor" => "must-never-be-exposed"
                 }
               ]
             })
  end

  test "response identity and unknown fields fail closed" do
    valid =
      :json.encode(%{
        "schema_version" => 1,
        "request_id" => "scaleset-1",
        "ok" => true,
        "result" => %{"applied" => true}
      })
      |> IO.iodata_to_binary()

    assert {:ok, %{"applied" => true}} = ScaleSetWire.decode_response(valid, "scaleset-1")

    assert {:error, :scaleset_response_mismatch} =
             ScaleSetWire.decode_response(valid, "scaleset-2")

    unexpected =
      :json.encode(%{
        "schema_version" => 1,
        "request_id" => "scaleset-1",
        "ok" => true,
        "result" => %{},
        "surprise" => true
      })
      |> IO.iodata_to_binary()

    assert {:error, :unexpected_scaleset_fields} =
             ScaleSetWire.decode_response(unexpected, "scaleset-1")
  end

  test "fresh snapshot parses acquired handles while stale snapshot is rejected" do
    now = ~U[2026-08-18 23:15:00Z]
    snapshot = snapshot(now)

    assert {:ok, parsed} = ScaleSetWire.decode_snapshot(snapshot, now)
    assert [%{pool_id: "build", acquired_handles: [101, 102]}] = parsed.pools

    stale = %{snapshot | "valid_until" => DateTime.to_iso8601(DateTime.add(now, -1, :second))}
    assert {:error, :invalid_scaleset_snapshot} = ScaleSetWire.decode_snapshot(stale, now)
  end

  test "fast lane policy fields are strict and bounded" do
    now = ~U[2026-08-18 23:15:00Z]
    snapshot = snapshot(now)
    [pool] = snapshot["pools"]

    assert {:ok, parsed} = ScaleSetWire.decode_snapshot(snapshot, now)
    assert [%{fast_lane_state: "holding", fast_lane_long_threshold_ms: 360_000}] = parsed.pools

    for invalid <- [
          %{pool | "fast_lane_state" => "teleporting"},
          %{pool | "fast_lane_long_threshold_ms" => 239_999},
          %{pool | "fast_lane_long_threshold_ms" => 480_001},
          %{pool | "fast_lane_hold_duration_ms" => 4_999},
          %{pool | "fast_lane_hold_duration_ms" => 30_001},
          %{pool | "fast_lane_reserved_slots" => 0},
          %{pool | "fast_lane_reserved_slots" => 5},
          %{pool | "fast_lane_reserved_slots" => 4},
          %{pool | "fast_lane_hold_until_ms" => 0},
          %{
            pool
            | "fast_lane_hold_until_ms" =>
                DateTime.to_unix(DateTime.add(now, 121, :second), :millisecond)
          }
        ] do
      assert {:error, :invalid_scaleset_snapshot} =
               ScaleSetWire.decode_snapshot(%{snapshot | "pools" => [invalid]}, now)
    end

    inactive = %{
      pool
      | "fast_lane_state" => "inactive",
        "fast_lane_long_threshold_ms" => 0,
        "fast_lane_hold_duration_ms" => 0,
        "fast_lane_reserved_slots" => 0,
        "fast_lane_hold_until_ms" => 0
    }

    assert {:ok, _} = ScaleSetWire.decode_snapshot(%{snapshot | "pools" => [inactive]}, now)
  end

  test "duplicate acquired handles fail closed" do
    now = ~U[2026-08-18 23:15:00Z]
    snapshot = snapshot(now)
    [pool] = snapshot["pools"]
    invalid = %{snapshot | "pools" => [%{pool | "acquired_handles" => [101, 101]}]}

    assert {:error, :invalid_scaleset_snapshot} = ScaleSetWire.decode_snapshot(invalid, now)
  end

  test "pool TTL covers GitHub long polls without widening the snapshot heartbeat" do
    now = ~U[2026-08-18 23:15:00Z]
    snapshot = snapshot(now)
    [pool] = snapshot["pools"]
    observed = DateTime.add(now, -1, :second)

    long_poll_pool = %{
      pool
      | "observed_at" => DateTime.to_iso8601(observed),
        "valid_until" => DateTime.to_iso8601(DateTime.add(observed, 90, :second))
    }

    assert {:ok, _} =
             ScaleSetWire.decode_snapshot(%{snapshot | "pools" => [long_poll_pool]}, now)

    overlong_pool = %{
      long_poll_pool
      | "valid_until" => DateTime.to_iso8601(DateTime.add(observed, 121, :second))
    }

    assert {:error, :invalid_scaleset_snapshot} =
             ScaleSetWire.decode_snapshot(%{snapshot | "pools" => [overlong_pool]}, now)

    stale_heartbeat = %{
      snapshot
      | "valid_until" => DateTime.to_iso8601(DateTime.add(observed, 31, :second))
    }

    assert {:error, :invalid_scaleset_snapshot} =
             ScaleSetWire.decode_snapshot(stale_heartbeat, now)
  end

  defp snapshot(now) do
    observed = DateTime.add(now, -1, :second)
    valid_until = DateTime.add(now, 10, :second)

    %{
      "schema_version" => 1,
      "controller_instance_id" => "controller-1",
      "config_revision" => @revision,
      "ownership_revision" => @revision,
      "sequence" => 8,
      "observed_at" => DateTime.to_iso8601(observed),
      "valid_until" => DateTime.to_iso8601(valid_until),
      "pools" => [
        %{
          "pool_id" => "build",
          "scale_set_id" => 74,
          "assigned_jobs" => 2,
          "advertised_capacity" => 4,
          "last_message_id" => 99,
          "session_healthy" => true,
          "acquired_handles" => [101, 102],
          "fast_lane_state" => "holding",
          "fast_lane_long_threshold_ms" => 360_000,
          "fast_lane_hold_duration_ms" => 15_000,
          "fast_lane_reserved_slots" => 1,
          "fast_lane_hold_until_ms" =>
            DateTime.to_unix(DateTime.add(now, 14, :second), :millisecond),
          "observed_at" => DateTime.to_iso8601(observed),
          "valid_until" => DateTime.to_iso8601(valid_until)
        }
      ]
    }
  end
end
