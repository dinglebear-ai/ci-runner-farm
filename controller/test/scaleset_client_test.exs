defmodule CrfController.ScaleSetClientTest do
  use ExUnit.Case, async: false

  alias CrfController.{ScaleSetClient, ScaleSetEligibility, Secret}

  @revision String.duplicate("b", 64)

  test "client owns monotonic sequence and wraps JIT descriptor as secret" do
    if :os.type() |> elem(0) == :win32 do
      assert true
    else
      path = socket_path()
      {:ok, listener} = :socket.open(:local, :stream, :default)
      :ok = :socket.bind(listener, %{family: :local, path: path})
      :ok = :socket.listen(listener, 4)
      parent = self()

      server =
        Task.async(fn ->
          for _ <- 1..4 do
            {:ok, socket} = :socket.accept(listener, 5_000)
            request = recv_json(socket)
            send(parent, {:request, request})
            response = response_for(request)
            :ok = :socket.send(socket, :json.encode(response) |> IO.iodata_to_binary(), 5_000)
            :socket.close(socket)
          end
        end)

      client =
        start_supervised!(
          {ScaleSetClient,
           name: nil,
           socket_path: path,
           controller_instance_id: "controller-1",
           config_revision: @revision,
           ownership_revision: @revision,
           timeout_ms: 5_000}
        )

      assert {:ok, %{"applied" => true}} = ScaleSetClient.apply_sessions(client, true)

      assert {:ok, %{descriptor: %Secret{} = secret, scale_set_id: 74}} =
               ScaleSetClient.issue_jit(client, "build", 101, "runner-101", "_work")

      assert Secret.expose(secret) == "jit-config-super-secret=="
      refute inspect(secret) =~ "jit-config-super-secret=="

      assert {:ok, [%{pool_id: "build", work_handle: 101, descriptor_available: true}]} =
               ScaleSetClient.read_jit_state(client)

      assert {:ok, %{"retired" => true}} = ScaleSetClient.retire_jit(client, "build", 101)

      requests =
        for _ <- 1..4,
            do: receive(do: ({:request, req} -> req), after: (5_000 -> flunk("missing request")))

      assert Enum.map(requests, & &1["sequence"]) == [1, 2, 3, 4]

      assert Enum.map(requests, & &1["request_id"]) == [
               "scaleset-1",
               "scaleset-2",
               "scaleset-3",
               "scaleset-4"
             ]

      assert Enum.map(requests, & &1["operation"]) == [
               "apply_sessions",
               "issue_jit",
               "read_jit_state",
               "retire_jit"
             ]

      Task.await(server, 5_000)
      :socket.close(listener)
      File.rm(path)
      File.rm(path <> ".sequence")
      File.rm(path <> ".eligibility")
    end
  end

  test "client restart continues the durable sequence against the same sidecar" do
    if :os.type() |> elem(0) == :win32 do
      assert true
    else
      # Uses read_jit_state (not apply_sessions) deliberately: this test's
      # only concern is sequence-number durability across a restart. Eligible
      # reconciliation (tested separately below) would inject an extra,
      # automatic apply_sessions request on the second client's startup —
      # unrelated to what this test asserts, and it would eat into the fake
      # server's fixed accept count.
      path = socket_path()
      {:ok, listener} = :socket.open(:local, :stream, :default)
      :ok = :socket.bind(listener, %{family: :local, path: path})
      :ok = :socket.listen(listener, 2)
      parent = self()

      server =
        Task.async(fn ->
          for _ <- 1..2 do
            {:ok, socket} = :socket.accept(listener, 5_000)
            request = recv_json(socket)
            send(parent, {:restart_request, request})
            response = response_for(request)
            :ok = :socket.send(socket, :json.encode(response) |> IO.iodata_to_binary(), 5_000)
            :socket.close(socket)
          end
        end)

      opts = [
        name: nil,
        socket_path: path,
        controller_instance_id: "controller-restart",
        config_revision: @revision,
        ownership_revision: @revision,
        timeout_ms: 5_000
      ]

      {:ok, first} = ScaleSetClient.start_link(opts)
      assert {:ok, [%{pool_id: "build"}]} = ScaleSetClient.read_jit_state(first)
      GenServer.stop(first)

      {:ok, second} = ScaleSetClient.start_link(opts)
      assert {:ok, [%{pool_id: "build"}]} = ScaleSetClient.read_jit_state(second)
      GenServer.stop(second)

      requests =
        for _ <- 1..2,
            do:
              receive(
                do: ({:restart_request, request} -> request),
                after: (5_000 -> flunk("missing restart request"))
              )

      assert Enum.map(requests, & &1["sequence"]) == [1, 2]
      assert Enum.map(requests, & &1["request_id"]) == ["scaleset-1", "scaleset-2"]

      Task.await(server, 5_000)
      :socket.close(listener)
      File.rm(path)
      File.rm(path <> ".sequence")
      File.rm(path <> ".eligibility")
    end
  end

  test "a persisted eligibility value is reasserted automatically on start, before any caller asks" do
    if :os.type() |> elem(0) == :win32 do
      assert true
    else
      path = socket_path()
      eligibility_path = path <> ".eligibility"
      # Pre-seeds the file a *prior* process run would have left behind after
      # an earlier `apply_sessions(false)` — simulating exactly the incident
      # this reconciliation exists to prevent: a restart that would otherwise
      # come back up trusting whatever ambient eligibility GitHub's scale-set
      # session already has, rather than the last explicitly commanded value.
      assert :ok = ScaleSetEligibility.persist(eligibility_path, "controller-preseed", false)

      {:ok, listener} = :socket.open(:local, :stream, :default)
      :ok = :socket.bind(listener, %{family: :local, path: path})
      :ok = :socket.listen(listener, 1)
      parent = self()

      server =
        Task.async(fn ->
          {:ok, socket} = :socket.accept(listener, 5_000)
          request = recv_json(socket)
          send(parent, {:reassert_request, request})
          response = response_for(request)
          :ok = :socket.send(socket, :json.encode(response) |> IO.iodata_to_binary(), 5_000)
          :socket.close(socket)
        end)

      start_supervised!({
        ScaleSetClient,
        # Long enough that only the startup reassert (not a periodic tick)
        # can be responsible for the single request this test expects.
        name: nil,
        socket_path: path,
        controller_instance_id: "controller-preseed",
        config_revision: @revision,
        ownership_revision: @revision,
        timeout_ms: 5_000,
        reconcile_interval_ms: 60_000
      })

      request =
        receive do
          {:reassert_request, request} -> request
        after
          5_000 -> flunk("client never reasserted the persisted eligibility on start")
        end

      assert request["operation"] == "apply_sessions"
      assert request["payload"] == %{"eligible" => false}

      Task.await(server, 5_000)
      :socket.close(listener)
      File.rm(path)
      File.rm(path <> ".sequence")
      File.rm(eligibility_path)
    end
  end

  test "eligibility reconciliation retries on the next tick after a failed reassert" do
    if :os.type() |> elem(0) == :win32 do
      assert true
    else
      path = socket_path()
      eligibility_path = path <> ".eligibility"
      assert :ok = ScaleSetEligibility.persist(eligibility_path, "controller-retry", true)

      {:ok, listener} = :socket.open(:local, :stream, :default)
      :ok = :socket.bind(listener, %{family: :local, path: path})
      # A backlog of 1: the startup reassert's connection is accepted and
      # dropped without a response (simulating a sidecar that isn't up yet);
      # only the SECOND attempt, from the fast reconcile tick, gets served.
      :ok = :socket.listen(listener, 1)
      parent = self()

      server =
        Task.async(fn ->
          {:ok, dropped} = :socket.accept(listener, 5_000)
          :socket.close(dropped)

          {:ok, socket} = :socket.accept(listener, 5_000)
          request = recv_json(socket)
          send(parent, {:retried_request, request})
          response = response_for(request)
          :ok = :socket.send(socket, :json.encode(response) |> IO.iodata_to_binary(), 5_000)
          :socket.close(socket)
        end)

      start_supervised!(
        {ScaleSetClient,
         name: nil,
         socket_path: path,
         controller_instance_id: "controller-retry",
         config_revision: @revision,
         ownership_revision: @revision,
         timeout_ms: 2_000,
         reconcile_interval_ms: 50}
      )

      request =
        receive do
          {:retried_request, request} -> request
        after
          5_000 -> flunk("reconciliation never retried after the failed attempt")
        end

      assert request["operation"] == "apply_sessions"
      assert request["payload"] == %{"eligible" => true}

      Task.await(server, 5_000)
      :socket.close(listener)
      File.rm(path)
      File.rm(path <> ".sequence")
      File.rm(eligibility_path)
    end
  end

  test "public calls outlive the implicit five second GenServer timeout" do
    if :os.type() |> elem(0) == :win32 do
      assert true
    else
      path = socket_path()
      {:ok, listener} = :socket.open(:local, :stream, :default)
      :ok = :socket.bind(listener, %{family: :local, path: path})
      :ok = :socket.listen(listener, 1)

      server =
        Task.async(fn ->
          {:ok, socket} = :socket.accept(listener, 5_000)
          request = recv_json(socket)
          Process.sleep(5_100)
          response = response_for(request)
          :ok = :socket.send(socket, :json.encode(response) |> IO.iodata_to_binary(), 5_000)
          :socket.close(socket)
        end)

      client =
        start_supervised!(
          {ScaleSetClient,
           name: nil,
           socket_path: path,
           controller_instance_id: "controller-slow",
           config_revision: @revision,
           ownership_revision: @revision,
           timeout_ms: 6_000}
        )

      assert {:ok, %{"applied" => true}} = ScaleSetClient.apply_sessions(client, true)
      Task.await(server, 6_000)
      :socket.close(listener)
      File.rm(path)
      File.rm(path <> ".sequence")
      File.rm(path <> ".eligibility")
    end
  end

  defp response_for(%{"operation" => "apply_sessions", "request_id" => request_id}) do
    %{
      "schema_version" => 1,
      "request_id" => request_id,
      "ok" => true,
      "result" => %{"applied" => true}
    }
  end

  defp response_for(%{"operation" => "issue_jit", "request_id" => request_id}) do
    %{
      "schema_version" => 1,
      "request_id" => request_id,
      "ok" => true,
      "result" => %{"descriptor" => "jit-config-super-secret==", "scale_set_id" => 74}
    }
  end

  defp response_for(%{"operation" => "read_jit_state", "request_id" => request_id}) do
    %{
      "schema_version" => 1,
      "request_id" => request_id,
      "ok" => true,
      "result" => %{
        "states" => [
          %{
            "pool_id" => "build",
            "scale_set_id" => 74,
            "work_handle" => 101,
            "state" => "issued",
            "descriptor_available" => true
          }
        ]
      }
    }
  end

  defp response_for(%{"operation" => "retire_jit", "request_id" => request_id}) do
    %{
      "schema_version" => 1,
      "request_id" => request_id,
      "ok" => true,
      "result" => %{"retired" => true}
    }
  end

  defp recv_json(socket) do
    socket
    |> recv_to_eof(<<>>)
    |> :json.decode()
  end

  defp recv_to_eof(socket, acc) do
    case :socket.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_to_eof(socket, <<acc::binary, data::binary>>)
      {:error, :closed} -> acc
      {:error, reason} -> raise "socket receive failed: #{inspect(reason)}"
    end
  end

  defp socket_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "crf-scaleset-client-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
      )

    File.rm(path)
    path
  end
end
