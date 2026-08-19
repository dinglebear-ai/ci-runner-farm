defmodule CrfController.SchedulerWireTest do
  use ExUnit.Case, async: true

  alias CrfController.{Node, SchedulerWire}

  @gib 1024 * 1024 * 1024

  test "encodes heterogeneous scheduling request for the Rust contract" do
    {:ok, binary} = SchedulerWire.encode_request("schedule-1", [work()], [test_node()])
    decoded = :json.decode(binary)

    assert decoded["protocol_version"] == 1
    assert decoded["request_id"] == "schedule-1"
    assert hd(decoded["requests"])["required_os"] == "windows"
    assert hd(decoded["nodes"])["execution_backends"] == ["native_process"]
  end

  test "strict response parser accepts matching Rust result and rejects request mismatch" do
    binary =
      :json.encode(%{
        "protocol_version" => 1,
        "request_id" => "schedule-1",
        "status" => "ok",
        "code" => :null,
        "result" => %{
          "placements" => [
            %{
              "work_id" => "work-1",
              "pool_id" => "build",
              "node_id" => "steamy",
              "node_generation" => 3,
              "reserved" => %{"cpu_millis" => 2_000, "memory_bytes" => 4 * @gib}
            }
          ],
          "unplaced" => []
        }
      })
      |> IO.iodata_to_binary()

    assert {:ok, %{placements: [%{node_id: "steamy"}], unplaced: []}} =
             SchedulerWire.decode_response(binary, "schedule-1")

    assert {:error, :scheduler_response_mismatch} =
             SchedulerWire.decode_response(binary, "schedule-other")
  end

  test "unknown response fields fail closed" do
    binary =
      :json.encode(%{
        "protocol_version" => 1,
        "request_id" => "schedule-1",
        "status" => "ok",
        "code" => :null,
        "result" => %{"placements" => [], "unplaced" => []},
        "surprise" => true
      })
      |> IO.iodata_to_binary()

    assert {:error, :unexpected_scheduler_fields} =
             SchedulerWire.decode_response(binary, "schedule-1")
  end

  defp test_node do
    {:ok, node} =
      Node.new(
        %{
          id: "steamy",
          generation: 3,
          os: :windows,
          arch: :x86_64,
          execution_backends: [:native_process],
          capabilities: ["github-actions"],
          total: %{cpu_millis: 12_000, memory_bytes: 32 * @gib},
          available: %{cpu_millis: 12_000, memory_bytes: 32 * @gib}
        },
        1
      )

    node
  end

  defp work do
    %{
      work_id: "work-1",
      pool_id: "build",
      resources: %{cpu_millis: 2_000, memory_bytes: 4 * @gib},
      required_os: :windows,
      required_arch: :x86_64,
      required_backend: :native_process,
      required_capabilities: []
    }
  end
end
