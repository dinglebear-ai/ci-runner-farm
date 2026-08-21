defmodule CrfController.TlsServer do
  use GenServer

  alias CrfController.{Ingress, PeerAuthorizer, TlsConnection, TlsOptions}

  @default_handshake_timeout 15_000
  @accept_timeout 1_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 0)
    ingress = Keyword.get(opts, :ingress, Ingress)

    connection_supervisor =
      Keyword.get(opts, :connection_supervisor, CrfController.ConnectionSupervisor)

    handshake_timeout = Keyword.get(opts, :handshake_timeout, @default_handshake_timeout)
    peers = Keyword.get(opts, :peers, [])
    peer_registry = Keyword.get(opts, :peer_registry)

    with true <- is_integer(port) and port in 0..65_535,
         true <- is_integer(handshake_timeout) and handshake_timeout in 1..120_000,
         {:ok, auth_source} <- auth_source(peer_registry, peers),
         {:ok, tls_options} <- TlsOptions.server(opts),
         {:ok, listen_socket} <-
           :ssl.listen(
             port,
             [mode: :binary, active: false, reuseaddr: true] ++ tls_options
           ),
         {:ok, {_address, actual_port}} <- :ssl.sockname(listen_socket),
         server = self(),
         {:ok, acceptor} <-
           Task.Supervisor.start_child(connection_supervisor, fn ->
             accept_loop(
               listen_socket,
               connection_supervisor,
               ingress,
               auth_source,
               handshake_timeout
             )
           end) do
      {:ok,
       %{
         listen_socket: listen_socket,
         acceptor: acceptor,
         auth_source: auth_source,
         server: server,
         port: actual_port
       }}
    else
      false -> {:stop, :invalid_tls_server_options}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def terminate(_reason, state) do
    _ = :ssl.close(state.listen_socket)
    :ok
  end

  defp accept_loop(listen_socket, connection_supervisor, ingress, auth_source, handshake_timeout) do
    case :ssl.transport_accept(listen_socket, @accept_timeout) do
      {:ok, socket} ->
        handoff(socket, connection_supervisor, ingress, auth_source, handshake_timeout)
        accept_loop(listen_socket, connection_supervisor, ingress, auth_source, handshake_timeout)

      {:error, :timeout} ->
        accept_loop(listen_socket, connection_supervisor, ingress, auth_source, handshake_timeout)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end

  defp handoff(socket, connection_supervisor, ingress, auth_source, handshake_timeout) do
    case Task.Supervisor.start_child(connection_supervisor, fn ->
           receive do
             {:crf_tls_socket, owned_socket} ->
               TlsConnection.run(owned_socket, ingress, auth_source, timeout: handshake_timeout)
           after
             handshake_timeout -> {:error, :socket_handoff_timeout}
           end
         end) do
      {:ok, connection_pid} ->
        case :ssl.controlling_process(socket, connection_pid) do
          :ok -> send(connection_pid, {:crf_tls_socket, socket})
          {:error, _reason} -> :ssl.close(socket)
        end

      {:error, _reason} ->
        :ssl.close(socket)
    end
  end

  defp auth_source(nil, peers), do: PeerAuthorizer.new(peers)

  defp auth_source(registry, _peers) when is_pid(registry) do
    if Process.alive?(registry), do: {:ok, registry}, else: {:error, :invalid_peer_registry}
  end

  defp auth_source(registry, _peers) when is_atom(registry) do
    if Process.whereis(registry), do: {:ok, registry}, else: {:error, :invalid_peer_registry}
  end

  defp auth_source(_registry, _peers), do: {:error, :invalid_peer_registry}
end
