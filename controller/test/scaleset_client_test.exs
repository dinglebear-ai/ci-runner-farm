defmodule CrfController.ScaleSetClientTest do
  use ExUnit.Case, async: false

  alias CrfController.{ScaleSetClient, Secret}

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
    end
  end

  test "client restart continues the durable sequence against the same sidecar" do
    if :os.type() |> elem(0) == :win32 do
      assert true
    else
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
      assert {:ok, %{"applied" => true}} = ScaleSetClient.apply_sessions(first, true)
      GenServer.stop(first)

      {:ok, second} = ScaleSetClient.start_link(opts)
      assert {:ok, %{"applied" => true}} = ScaleSetClient.apply_sessions(second, true)
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
    Path.join(System.tmp_dir!(), "crf-scaleset-client-#{System.unique_integer([:positive])}.sock")
  end
end
