defmodule CrfController.ScaleSetTransportTest do
  use ExUnit.Case, async: true

  alias CrfController.ScaleSetTransport

  @tag :unix
  test "local-domain transport writes request to EOF and reads bounded response to EOF" do
    if :os.type() |> elem(0) == :win32 do
      assert {:error, :unix_socket_unsupported} =
               ScaleSetTransport.call("C:/not-a-unix-socket", "request", 100)
    else
      path = socket_path("roundtrip")
      {:ok, listener} = :socket.open(:local, :stream, :default)
      :ok = :socket.bind(listener, %{family: :local, path: path})
      :ok = :socket.listen(listener, 1)

      response =
        ~s({"schema_version":1,"request_id":"scaleset-1","ok":true,"result":{"applied":true}})

      server =
        Task.async(fn ->
          {:ok, socket} = :socket.accept(listener, 5_000)
          request = recv_to_eof(socket, <<>>)
          :ok = :socket.send(socket, response, 5_000)
          :ok = :socket.close(socket)
          request
        end)

      request = ~s({"request":"payload"})
      assert {:ok, ^response} = ScaleSetTransport.call(path, request, 5_000)
      assert Task.await(server, 5_000) == request
      :ok = :socket.close(listener)
      File.rm(path)
    end
  end

  test "response larger than one MiB is rejected" do
    if :os.type() |> elem(0) != :win32 do
      path = socket_path("oversized")
      {:ok, listener} = :socket.open(:local, :stream, :default)
      :ok = :socket.bind(listener, %{family: :local, path: path})
      :ok = :socket.listen(listener, 1)

      server =
        Task.async(fn ->
          {:ok, socket} = :socket.accept(listener, 5_000)
          _request = recv_to_eof(socket, <<>>)
          _ = :socket.send(socket, :binary.copy(<<"x">>, 1024 * 1024 + 1), 5_000)
          :socket.close(socket)
        end)

      assert {:error, {:scaleset_transport, :response_too_large}} =
               ScaleSetTransport.call(path, "request", 5_000)

      Task.await(server, 5_000)
      :socket.close(listener)
      File.rm(path)
    end
  end

  test "response deadline cannot become an unbounded socket wait" do
    if :os.type() |> elem(0) != :win32 do
      path = socket_path("deadline")
      {:ok, listener} = :socket.open(:local, :stream, :default)
      :ok = :socket.bind(listener, %{family: :local, path: path})
      :ok = :socket.listen(listener, 1)

      server =
        Task.async(fn ->
          {:ok, socket} = :socket.accept(listener, 5_000)
          _request = recv_to_eof(socket, <<>>)

          Enum.reduce_while(1..100, :ok, fn _, :ok ->
            Process.sleep(10)

            case :socket.send(socket, ".", 100) do
              :ok -> {:cont, :ok}
              {:error, _reason} -> {:halt, :closed}
            end
          end)

          :socket.close(socket)
        end)

      started_at = System.monotonic_time(:millisecond)
      assert {:error, :scaleset_timeout} = ScaleSetTransport.call(path, "request", 50)
      assert System.monotonic_time(:millisecond) - started_at < 400

      Task.await(server, 1_000)
      :socket.close(listener)
      File.rm(path)
    end
  end

  defp recv_to_eof(socket, acc) do
    case :socket.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_to_eof(socket, <<acc::binary, data::binary>>)
      {:error, :closed} -> acc
      {:error, reason} -> raise "socket receive failed: #{inspect(reason)}"
    end
  end

  defp socket_path(label) do
    Path.join(
      System.tmp_dir!(),
      "crf-scaleset-#{label}-#{System.unique_integer([:positive])}.sock"
    )
  end
end
