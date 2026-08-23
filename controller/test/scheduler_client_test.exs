defmodule CrfController.SchedulerClientTest do
  use ExUnit.Case, async: false

  alias CrfController.{Node, SchedulerClient}

  @gib 1024 * 1024 * 1024

  test "queued callers are monitored and expired before they can become ghost work" do
    if match?({:win32, _}, :os.type()) do
      # The blocking fixture is a POSIX executable. Windows still exercises the
      # persistent-port queue through the real scheduler test below.
      assert true
    else
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "crf-scheduler-client-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      executable = Path.join(tmp_dir, "blocking-scheduler")
      File.write!(executable, "#!/bin/sh\nsleep 10\n")
      File.chmod!(executable, 0o700)

      client =
        start_supervised!(
          {SchedulerClient, name: nil, executable: executable, request_timeout_ms: 150},
          id: :ghost_scheduler_client
        )

      nodes = [node("steamy", :windows, :native_process)]

      first =
        Task.async(fn -> SchedulerClient.schedule(client, [work("active")], nodes, 2_000) end)

      Process.sleep(25)

      ghost =
        spawn(fn ->
          _ = SchedulerClient.schedule(client, [work("ghost")], nodes, 2_000)
        end)

      Process.sleep(25)
      Process.exit(ghost, :kill)

      assert eventually(fn -> map_size(:sys.get_state(client).queued) == 0 end)
      assert {:error, :scheduler_timeout} = Task.await(first, 2_000)

      started_at = System.monotonic_time(:millisecond)

      assert {:error, :scheduler_timeout} =
               SchedulerClient.schedule(client, [work("after-ghost")], nodes, 2_000)

      assert System.monotonic_time(:millisecond) - started_at < 500
      stop_supervised!(:ghost_scheduler_client)
    end
  end

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

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
