defmodule CrfController.PeerRegistry do
  use GenServer

  alias CrfController.{ControllerConfig, PeerAuthorizer, PeerIdentity}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def authorize_certificate(server \\ __MODULE__, certificate_der) do
    GenServer.call(server, {:authorize_certificate, certificate_der})
  end

  def authorize_identity(server \\ __MODULE__, %PeerIdentity{} = peer) do
    GenServer.call(server, {:authorize_identity, peer})
  end

  def replace_peers(server \\ __MODULE__, peers) do
    GenServer.call(server, {:replace_peers, peers})
  end

  def replace_from_config(server \\ __MODULE__, path) do
    with {:ok, config} <- ControllerConfig.load(path) do
      replace_peers(server, Keyword.fetch!(config.tls_opts, :peers))
    end
  end

  def reload_from_env(server \\ __MODULE__) do
    case System.get_env("CRF_CONTROLLER_CONFIG") do
      path when is_binary(path) and byte_size(path) > 0 -> replace_from_config(server, path)
      _ -> {:error, :missing_controller_config}
    end
  end

  def revoke_all(server \\ __MODULE__), do: replace_peers(server, [])

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    peers = Keyword.get(opts, :peers, [])

    with {:ok, authorizer} <- PeerAuthorizer.new(peers) do
      {:ok, %{authorizer: authorizer, revision: 1}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:authorize_certificate, certificate_der}, _from, state) do
    {:reply, PeerAuthorizer.authorize(state.authorizer, certificate_der), state}
  end

  def handle_call({:authorize_identity, %PeerIdentity{} = peer}, _from, state) do
    {:reply, PeerAuthorizer.authorize_identity(state.authorizer, peer), state}
  end

  def handle_call({:replace_peers, peers}, _from, state) do
    case authorizer_for_replace(peers) do
      {:ok, authorizer} ->
        revision = state.revision + 1
        next = %{state | authorizer: authorizer, revision: revision}
        {:reply, {:ok, status_map(next)}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}

  defp authorizer_for_replace([]), do: {:ok, PeerAuthorizer.empty()}
  defp authorizer_for_replace(peers), do: PeerAuthorizer.new(peers)

  defp status_map(state) do
    nodes =
      state.authorizer.by_fingerprint
      |> Map.values()
      |> Enum.uniq()
      |> Enum.sort()

    %{
      revision: state.revision,
      peer_count: map_size(state.authorizer.by_fingerprint),
      node_count: length(nodes),
      nodes: nodes
    }
  end
end
