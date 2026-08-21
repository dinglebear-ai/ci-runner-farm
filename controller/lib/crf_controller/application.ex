defmodule CrfController.Application do
  @moduledoc false

  use Application

  alias CrfController.ControllerConfig

  @impl true
  def start(_type, _args) do
    with {:ok, children} <- children_from_environment() do
      Supervisor.start_link(children, strategy: :one_for_one, name: CrfController.Supervisor)
    end
  end

  def children_from_environment do
    case System.get_env("CRF_CONTROLLER_CONFIG") do
      nil ->
        {:ok, legacy_children()}

      "" ->
        {:ok, legacy_children()}

      path ->
        with {:ok, config} <- ControllerConfig.load(path), do: {:ok, distributed_children(config)}
    end
  end

  def distributed_children(%ControllerConfig{} = config) do
    sidecar_children =
      case config.sidecar_opts do
        nil -> []
        opts -> [{CrfController.ScaleSetSidecar, opts}]
      end

    peers = Keyword.fetch!(config.tls_opts, :peers)
    tls_opts = Keyword.put(config.tls_opts, :peer_registry, CrfController.PeerRegistry)

    [
      {CrfController.NodeRegistry, config.node_registry_opts},
      {CrfController.PlacementLedger, config.placement_opts},
      {CrfController.OfferLedger, []},
      {CrfController.NodeMailbox, []},
      {CrfController.SchedulerClient, config.scheduler_opts},
      {CrfController.PlacementCoordinator, []},
      {CrfController.Ingress, []},
      {CrfController.PeerRegistry, [peers: peers]},
      {Task.Supervisor, name: CrfController.ConnectionSupervisor}
    ] ++
      sidecar_children ++
      [
        {CrfController.ScaleSetClient, config.scaleset_opts},
        {CrfController.DemandCoordinator, config.demand_opts},
        {CrfController.TlsServer, tls_opts}
      ]
  end

  defp legacy_children do
    placement_options =
      case System.get_env("CRF_PLACEMENT_STATE_PATH") do
        nil -> []
        "" -> []
        path -> [state_path: path]
      end

    scheduler_children =
      case System.get_env("CRF_SCHEDULER_BIN") do
        nil -> []
        "" -> []
        executable -> [{CrfController.SchedulerClient, [executable: executable]}]
      end

    [
      {CrfController.NodeRegistry, []},
      {CrfController.PlacementLedger, placement_options},
      {CrfController.OfferLedger, []},
      {CrfController.NodeMailbox, []}
    ] ++
      scheduler_children ++
      [
        {CrfController.PlacementCoordinator, []},
        {CrfController.Ingress, []},
        {Task.Supervisor, name: CrfController.ConnectionSupervisor}
      ]
  end
end
