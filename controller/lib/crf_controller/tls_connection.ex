defmodule CrfController.TlsConnection do
  alias CrfController.{Framing, Ingress, PeerAuthorizer, PeerRegistry}

  @default_timeout 15_000

  @spec run(term(), GenServer.server(), term(), keyword()) :: :ok | {:error, term()}
  def run(socket, ingress \\ Ingress, auth_source, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    result =
      with :ok <- valid_timeout(timeout),
           {:ok, socket} <- :ssl.handshake(socket, timeout),
           {:ok, certificate_der} <- :ssl.peercert(socket),
           {:ok, peer} <- authorize_certificate(auth_source, certificate_der) do
        receive_loop(socket, ingress, auth_source, peer, timeout)
      end

    _ = :ssl.close(socket)
    result
  end

  defp receive_loop(socket, ingress, auth_source, peer, timeout) do
    case receive_payload(socket, timeout) do
      {:ok, payload} ->
        with :ok <- authorize_identity(auth_source, peer),
             {:ok, response} <- Ingress.ingest(ingress, peer, payload),
             {:ok, frame} <- Framing.encode(response),
             :ok <- :ssl.send(socket, frame) do
          receive_loop(socket, ingress, auth_source, peer, timeout)
        end

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authorize_certificate(%PeerAuthorizer{} = authorizer, certificate_der),
    do: PeerAuthorizer.authorize(authorizer, certificate_der)

  defp authorize_certificate(registry, certificate_der),
    do: PeerRegistry.authorize_certificate(registry, certificate_der)

  defp authorize_identity(%PeerAuthorizer{} = authorizer, peer),
    do: PeerAuthorizer.authorize_identity(authorizer, peer)

  defp authorize_identity(registry, peer), do: PeerRegistry.authorize_identity(registry, peer)

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
