defmodule CrfController.OperatorSnapshot do
  @moduledoc "Read-only, secret-free operator view of distributed controller state."

  alias CrfController.{
    DemandCoordinator,
    NodeRegistry,
    OfferLedger,
    PeerRegistry,
    PlacementLedger,
    Resources,
    ScaleSetSidecar
  }

  def snapshot(servers \\ %{}, opts \\ []) when is_map(servers) and is_list(opts) do
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    call_timeout_ms = Keyword.get(opts, :call_timeout_ms, 100)

    nodes =
      call(Map.get(servers, :nodes, NodeRegistry), &NodeRegistry.snapshot/1, [], call_timeout_ms)

    offers =
      call(Map.get(servers, :offers, OfferLedger), &OfferLedger.snapshot/1, [], call_timeout_ms)

    placements =
      call(
        Map.get(servers, :placements, PlacementLedger),
        &PlacementLedger.snapshot/1,
        [],
        call_timeout_ms
      )

    tombstones =
      call(
        Map.get(servers, :placements, PlacementLedger),
        &PlacementLedger.tombstone_snapshot/1,
        [],
        call_timeout_ms
      )

    demand =
      call(
        Map.get(servers, :demand, DemandCoordinator),
        &DemandCoordinator.status(&1, call_timeout_ms),
        nil,
        call_timeout_ms
      )

    peers =
      call(Map.get(servers, :peers, PeerRegistry), &PeerRegistry.status/1, nil, call_timeout_ms)

    sidecar =
      call(
        Map.get(servers, :sidecar, ScaleSetSidecar),
        &ScaleSetSidecar.status/1,
        nil,
        call_timeout_ms
      )

    %{
      schema_version: 1,
      nodes: Enum.map(nodes, &node_view(&1, now_ms)),
      offers: Enum.map(offers, &offer/1),
      placements: Enum.map(placements, &placement/1),
      terminal_replay_fences: length(tombstones),
      demand: demand(demand),
      peer_authorization: peers,
      sidecar: sidecar(sidecar)
    }
  end

  defp call(nil, _fun, fallback, _timeout), do: fallback

  defp call(server, fun, fallback, timeout) do
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.(server)}
          catch
            :exit, _ -> :failed
          end

        # Returning the result as the monitored process's exit reason keeps the
        # result and completion signal in one message.  Sending the result and
        # then monitoring the worker races the ordinary message against :DOWN;
        # if :DOWN wins, the result leaks into the caller's mailbox.
        exit({:operator_snapshot_result, result_ref, result})
      end)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid,
       {:operator_snapshot_result, ^result_ref, {:ok, result}}} ->
        result

      {:DOWN, ^monitor_ref, :process, ^pid, {:operator_snapshot_result, ^result_ref, :failed}} ->
        fallback

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        fallback
    after
      timeout ->
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok)
        fallback
    end
  end

  defp node_view(node, now_ms) do
    %{
      id: node.id,
      generation: node.generation,
      os: node.os,
      arch: node.arch,
      execution_backends: node.execution_backends |> MapSet.to_list() |> Enum.sort(),
      capabilities: node.capabilities |> MapSet.to_list() |> Enum.sort(),
      total: resources(node.total),
      available: resources(node.available),
      active_placements: node.active_placements |> MapSet.to_list() |> Enum.sort(),
      draining: node.draining,
      last_seen_age_ms: max(now_ms - node.last_seen_ms, 0)
    }
  end

  defp offer(offer) do
    Map.take(offer, [
      :id,
      :pool_id,
      :node_id,
      :node_generation,
      :state,
      :work_handle,
      :created_at_ms,
      :expires_at_ms
    ])
    |> Map.put(:resources, resources(offer.resources))
  end

  defp placement(placement) do
    Map.take(placement, [
      :id,
      :node_id,
      :node_generation,
      :work_id,
      :pool_id,
      :state,
      :detail_code,
      :updated_at_ms
    ])
    |> Map.put(:resources, resources(placement.resources))
  end

  defp resources(%Resources{} = resources),
    do: %{cpu_millis: resources.cpu_millis, memory_bytes: resources.memory_bytes}

  defp demand(nil), do: nil

  defp demand(status) do
    %{
      sessions_active: status.sessions_active,
      auto_reconcile: status.auto_reconcile,
      reconcile_interval_ms: status.reconcile_interval_ms,
      placement_loss_grace_ms: status.placement_loss_grace_ms,
      orphaned_placements: Enum.sort(status.orphaned_placements),
      last_reconcile_unix_ms: status.last_reconcile_unix_ms,
      pools: status.pools,
      pool_status: Map.get(status, :pool_status, [])
    }
  end

  defp sidecar(nil), do: nil

  defp sidecar(status) do
    Map.take(status, [:ready, :os_pid, :output_bytes, :diagnostic_tail, :started_at_ms])
  end
end
