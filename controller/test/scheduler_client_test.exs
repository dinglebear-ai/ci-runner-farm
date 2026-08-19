defmodule CrfController.SchedulerClientTest do
  use ExUnit.Case, async: false

  alias CrfController.{Node, SchedulerClient}

  @gib 1024 * 1024 * 1024

  test "persistent Elixir Port uses the real Rust scheduler for sequential and queued calls" do
    case System.get_env("CRF_SCHEDULER_BIN") do
      nil ->
        assert true

      executable ->
        client =
          start_supervised!(
            {SchedulerClient, name: nil, executable: executable, request_timeout_ms: 5_000}
          )

        requests = [work("work-1"), work("work-2")]
        nodes = [node("dookie", :linux, :container), node("steamy", :windows, :native_process)]

        assert {:ok, result} = SchedulerClient.schedule(client, requests, nodes)
        assert Enum.map(result.placements, & &1.node_id) == ["steamy", "steamy"]

        tasks =
          for index <- 3..6 do
            Task.async(fn -> SchedulerClient.schedule(client, [work("work-#{index}")], nodes) end)
          end

        assert Enum.all?(Task.await_many(tasks, 10_000), fn
                 {:ok, %{placements: [%{node_id: "steamy"}]}} -> true
                 _ -> false
               end)
    end
  end

  defp node(id, os, backend) do
    {:ok, node} =
      Node.new(
        %{
          id: id,
          generation: if(id == "steamy", do: 3, else: 7),
          os: os,
          arch: :x86_64,
          execution_backends: [backend],
          capabilities: ["github-actions"],
          total: %{cpu_millis: 12_000, memory_bytes: 32 * @gib},
          available: %{cpu_millis: 12_000, memory_bytes: 32 * @gib}
        },
        1
      )

    node
  end

  defp work(id) do
    %{
      work_id: id,
      pool_id: "build",
      resources: %{cpu_millis: 2_000, memory_bytes: 4 * @gib},
      required_os: :windows,
      required_arch: :x86_64,
      required_backend: :native_process,
      required_capabilities: []
    }
  end
end
