defmodule CrfController.ScaleSetTransport do
  @max_frame_bytes 1024 * 1024

  def call(socket_path, request, timeout_ms)
      when is_binary(socket_path) and is_binary(request) and is_integer(timeout_ms) and
             timeout_ms > 0 and timeout_ms <= 120_000 do
    if :os.type() |> elem(0) == :win32 do
      {:error, :unix_socket_unsupported}
    else
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      with {:ok, socket} <- :socket.open(:local, :stream, :default) do
        try do
          with :ok <-
                 :socket.connect(
                   socket,
                   %{family: :local, path: socket_path},
                   remaining(deadline)
                 ),
               :ok <- send_all(socket, request, deadline),
               :ok <- :socket.shutdown(socket, :write),
               {:ok, response} <- recv_all(socket, deadline, <<>>) do
            {:ok, response}
          else
            {:error, :timeout} -> {:error, :scaleset_timeout}
            {:error, reason} -> {:error, {:scaleset_transport, reason}}
          end
        after
          _ = :socket.close(socket)
        end
      else
        {:error, reason} -> {:error, {:scaleset_transport, reason}}
      end
    end
  end

  def call(_, _, _), do: {:error, :invalid_scaleset_transport_request}

  defp send_all(socket, data, deadline) do
    case :socket.send(socket, data, remaining(deadline)) do
      :ok -> :ok
      {:ok, rest} when is_binary(rest) and byte_size(rest) > 0 -> send_all(socket, rest, deadline)
      {:error, {reason, _rest}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_all(socket, deadline, acc) do
    case :socket.recv(socket, 0, remaining(deadline)) do
      {:ok, data} when is_binary(data) ->
        if byte_size(acc) + byte_size(data) > @max_frame_bytes,
          do: {:error, :response_too_large},
          else: recv_all(socket, deadline, <<acc::binary, data::binary>>)

      {:error, :closed} ->
        if byte_size(acc) > 0, do: {:ok, acc}, else: {:error, :empty_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
