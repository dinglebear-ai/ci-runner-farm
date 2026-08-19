defmodule CrfController.Scheduler do
  alias CrfController.{CapacityView, NodeRegistry, OfferLedger, PlacementLedger, SchedulerClient}

  def schedule(requests, opts \\ [])

  def schedule(requests, opts) when is_list(requests) do
    node_registry = Keyword.get(opts, :node_registry, NodeRegistry)
    placement_ledger = Keyword.get(opts, :placement_ledger, PlacementLedger)
    offer_ledger = Keyword.get(opts, :offer_ledger, OfferLedger)
    scheduler_client = Keyword.get(opts, :scheduler_client, SchedulerClient)
    timeout = Keyword.get(opts, :timeout, 10_000)

    with {:ok, nodes} <-
           CapacityView.effective_nodes(
             NodeRegistry.snapshot(node_registry),
             PlacementLedger.snapshot(placement_ledger),
             OfferLedger.snapshot(offer_ledger)
           ) do
      SchedulerClient.schedule(scheduler_client, requests, nodes, timeout)
    end
  end

  def schedule(_, _), do: {:error, :invalid_scheduler_request}
end
