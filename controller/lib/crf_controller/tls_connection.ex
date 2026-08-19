defmodule CrfController.TlsConnection do
  alias CrfController.{Framing, Ingress, PeerAuthorizer}

  @default_timeout 15_000

  @spec run(term(), GenServer.server(), PeerAuthorizer.t(), keyword()) :: :ok | {:error, term()}
  def run(socket, ingress \\ Ingress, %PeerAuthorizer{} = authorizer, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    result =
      with :ok <- valid_timeout(timeout),
           {:ok, socket} <- :ssl.handshake(socket, timeout),
           {:ok, certificate_der} <- :ssl.peercert(socket),
           {:ok, peer} <- PeerAuthorizer.authorize(authorizer, certificate_der) do
        receive_loop(socket, ingress, peer, timeout)
      end

    _ = :ssl.close(socket)
    result
  end

  defp receive_loop(socket, ingress, peer, timeout) do
    case receive_payload(socket, timeout) do
      {:ok, payload} ->
        with {:ok, response} <- Ingress.ingest(ingress, peer, payload),
             {:ok, frame} <- Framing.encode(response),
             :ok <- :ssl.send(socket, frame) do
          receive_loop(socket, ingress, peer, timeout)
        end

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_payload(socket, timeout) do
    case :ssl.recv(socket, Framing.header_bytes(), timeout) do
      {:ok, <<length::unsigned-big-integer-size(32)>>} ->
        if length > 0 and length <= Framing.max_payload_bytes() do
          case :ssl.recv(socket, length, timeout) do
            {:ok, payload} when byte_size(payload) == length -> {:ok, payload}
            {:ok, _partial} -> {:error, :truncated_frame}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, :invalid_frame_header}
        end

      {:ok, _invalid_header} ->
        {:error, :invalid_frame_header}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_timeout(timeout) when is_integer(timeout) and timeout in 1..120_000, do: :ok
  defp valid_timeout(_), do: {:error, :invalid_timeout}
end
