defmodule CrfController.DemandCoordinator do
  use GenServer

  alias CrfController.{
    DemandWork,
    NodeMailbox,
    NodeRegistry,
    OfferLedger,
    OfferPlanner,
    Placement,
    PlacementHealth,
    PlacementTombstone,
    PlacementLedger,
    PoolPolicy,
    ScaleSetClient,
    WorkIdentity
  }

  @default_offer_ttl_ms 90_000
  @default_max_new_offers 4
  @default_reconcile_interval_ms 1_000
  @default_placement_loss_grace_ms 60_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def status(server \\ __MODULE__, timeout \\ 5_000), do: GenServer.call(server, :status, timeout)

  def force_abandon_placement(placement_id, opts \\ []) do
    force_abandon_placement(__MODULE__, placement_id, opts)
  end

  def force_abandon_placement(server, placement_id, opts) do
    GenServer.call(
      server,
      {:force_abandon, placement_id, Keyword.get(opts, :force, false),
       Keyword.get(opts, :now_ms, now_ms())},
      Keyword.get(opts, :timeout, 30_000)
    )
  end

  def reconcile(server \\ __MODULE__, opts \\ []) do
    GenServer.call(
      server,
      {:reconcile, Keyword.get(opts, :now_ms, now_ms()),
       Keyword.get(opts, :now_unix_ms, now_unix_ms())},
      Keyword.get(opts, :timeout, 30_000)
    )
  end

  @impl true
  def init(opts) do
    with {:ok, policies} <- policies(Keyword.get(opts, :policies, [])),
         {:ok, scale_set_client} <- Keyword.fetch(opts, :scale_set_client),
         {:ok, scheduler_client} <- Keyword.fetch(opts, :scheduler_client),
         offer_ttl when is_integer(offer_ttl) and offer_ttl in 1_000..300_000 <-
           Keyword.get(opts, :offer_ttl_ms, @default_offer_ttl_ms),
         max_new when is_integer(max_new) and max_new in 1..64 <-
           Keyword.get(opts, :max_new_offers_per_tick, @default_max_new_offers),
         auto_reconcile when is_boolean(auto_reconcile) <-
           Keyword.get(opts, :auto_reconcile, false),
         interval when is_integer(interval) and interval in 100..60_000 <-
           Keyword.get(opts, :reconcile_interval_ms, @default_reconcile_interval_ms),
         loss_grace when is_integer(loss_grace) and loss_grace in 1_000..86_400_000 <-
           Keyword.get(opts, :placement_loss_grace_ms, @default_placement_loss_grace_ms) do
      ctx = %{
        policies: policies,
        scale_set_client: scale_set_client,
        scheduler_client: scheduler_client,
        node_registry: Keyword.get(opts, :node_registry, CrfController.NodeRegistry),
        placement_ledger: Keyword.get(opts, :placement_ledger, PlacementLedger),
        offer_ledger: Keyword.get(opts, :offer_ledger, OfferLedger),
        node_mailbox: Keyword.get(opts, :node_mailbox, CrfController.NodeMailbox),
        placement_coordinator:
          Keyword.get(opts, :placement_coordinator, CrfController.PlacementCoordinator),
        offer_ttl_ms: offer_ttl
      }

      state = %{
        ctx: ctx,
        sessions_active: false,
        planner: %{offer_sequence: 0, cursor: 0, max_new_offers_per_tick: max_new},
        auto_reconcile: auto_reconcile,
        reconcile_interval_ms: interval,
        placement_loss_grace_ms: loss_grace,
        placement_health: %{missing_since: %{}, orphaned: []},
        pool_status: [],
        last_outcome: nil,
        last_reconcile_unix_ms: nil
      }

      {:ok, schedule_tick(state)}
    else
      :error -> {:stop, :missing_demand_dependency}
      {:error, reason} -> {:stop, reason}
      _ -> {:stop, :invalid_demand_coordinator_config}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      sessions_active: state.sessions_active,
      auto_reconcile: state.auto_reconcile,
      reconcile_interval_ms: state.reconcile_interval_ms,
      placement_loss_grace_ms: state.placement_loss_grace_ms,
      orphaned_placements: state.placement_health.orphaned,
      last_outcome: state.last_outcome,
      last_reconcile_unix_ms: state.last_reconcile_unix_ms,
      pools: state.ctx.policies |> Map.keys() |> Enum.sort(),
      pool_status: state.pool_status
    }

    {:reply, status, state}
  end

  def handle_call({:force_abandon, placement_id, force, now_ms}, _from, state) do
    state = refresh_placement_health(state, now_ms)

    reply =
      cond do
        force != true ->
          {:error, :explicit_force_required}

        not is_binary(placement_id) ->
          {:error, :invalid_placement_id}

        not PlacementHealth.orphaned?(state.placement_health, placement_id) ->
          {:error, :placement_not_orphaned}

        true ->
          force_abandon_now(placement_id, now_ms, state)
      end

    {:reply, reply, refresh_placement_health(state, now_ms)}
  end

  def handle_call({:reconcile, now_ms, now_unix_ms}, _from, state) do
    {reply, state} = reconcile_once(state, now_ms, now_unix_ms)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:reconcile_tick, state) do
    {_reply, state} = reconcile_once(state, now_ms(), now_unix_ms())
    {:noreply, schedule_tick(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reconcile_once(state, now_ms, now_unix_ms) do
    state = refresh_placement_health(state, now_ms)

    result =
      case ensure_sessions(state) do
        {:ok, state} ->
          case reclaim_orphaned_placements(state, now_ms) do
            :ok ->
              case do_reconcile(state, now_ms, now_unix_ms) do
                {:ok, value, state} -> {{:ok, value}, state}
                {:error, reason, state} -> {{:error, reason}, maybe_reset_sessions(state, reason)}
              end

            {:error, reason} ->
              {{:error, reason}, state}
          end

        {:error, reason, state} ->
          {{:error, reason}, maybe_reset_sessions(state, reason)}
      end

    {reply, state} = result
    state = refresh_placement_health(state, now_ms)

    {reply,
     %{
       state
       | last_outcome: reply,
         last_reconcile_unix_ms: now_unix_ms
     }}
  end

  defp ensure_sessions(%{sessions_active: true} = state), do: {:ok, state}

  defp ensure_sessions(state) do
    case ScaleSetClient.apply_sessions(state.ctx.scale_set_client, true) do
      {:ok, _} -> {:ok, %{state | sessions_active: true}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp do_reconcile(state, now_ms, now_unix_ms) do
    ctx = state.ctx

    with {:ok, jit_states} <- ScaleSetClient.read_jit_state(ctx.scale_set_client),
         {:ok, jit_blocked} <-
           DemandWork.reconcile_jit_states(jit_states, ctx, now_ms, now_unix_ms),
         {:ok, snapshot} <- ScaleSetClient.read_snapshot(ctx.scale_set_client),
         {:ok, acquired_blocked} <-
           DemandWork.reconcile_acquired(snapshot, jit_states, ctx, now_ms, now_unix_ms),
         {:ok, reclaimed} <- DemandWork.reclaim_unassigned(snapshot, ctx, now_ms, now_unix_ms),
         blocked <- MapSet.union(jit_blocked, acquired_blocked),
         :ok <- OfferPlanner.trim_excess(ctx, now_ms),
         {:ok, planner} <- OfferPlanner.plan(snapshot, blocked, ctx, state.planner, now_ms),
         {:ok, leases} <- OfferPlanner.advertised_leases(snapshot, ctx, now_ms),
         {:ok, _} <- ScaleSetClient.publish_capacity_leases(ctx.scale_set_client, leases) do
      result = %{
        leases: leases,
        blocked_pools: blocked |> MapSet.to_list() |> Enum.sort(),
        offers: length(OfferLedger.snapshot(ctx.offer_ledger, now_ms: now_ms)),
        placements: length(PlacementLedger.snapshot(ctx.placement_ledger)),
        reclaimed_idle_placements: reclaimed
      }

      {:ok, result,
       %{state | planner: planner, pool_status: operator_pool_status(snapshot.pools)}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp operator_pool_status(pools) do
    pools
    |> Enum.map(fn pool ->
      %{
        pool_id: pool.pool_id,
        scale_set_id: pool.scale_set_id,
        assigned_jobs: pool.assigned_jobs,
        advertised_capacity: pool.advertised_capacity,
        session_healthy: pool.session_healthy,
        fast_lane_state: Map.get(pool, :fast_lane_state, "inactive"),
        fast_lane_long_threshold_ms: Map.get(pool, :fast_lane_long_threshold_ms, 0),
        fast_lane_hold_duration_ms: Map.get(pool, :fast_lane_hold_duration_ms, 0),
        fast_lane_reserved_slots: Map.get(pool, :fast_lane_reserved_slots, 0),
        fast_lane_hold_until_ms: Map.get(pool, :fast_lane_hold_until_ms, 0),
        observed_at: Map.get(pool, :observed_at),
        valid_until: Map.get(pool, :valid_until)
      }
    end)
    |> Enum.sort_by(& &1.pool_id)
  end

  defp refresh_placement_health(state, now_ms) do
    health =
      PlacementHealth.update(
        PlacementLedger.snapshot(state.ctx.placement_ledger),
        NodeRegistry.snapshot(state.ctx.node_registry),
        state.placement_health.missing_since,
        now_ms,
        state.placement_loss_grace_ms
      )

    %{state | placement_health: health}
  end

  defp force_abandon_now(placement_id, now_ms, state) do
    abandon_now(placement_id, "operator_abandoned", now_ms, state)
  end

  defp reclaim_orphaned_placements(state, now_ms) do
    state.placement_health.orphaned
    |> Enum.reduce_while(:ok, fn orphan, :ok ->
      case abandon_now(orphan.placement_id, "placement_lost", now_ms, state) do
        {:ok, _result} -> {:cont, :ok}
        {:error, :placement_terminal} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:lost_placement_reclaim_failed, reason}}}
      end
    end)
  end

  defp abandon_now(placement_id, detail_code, now_ms, state) do
    with {:ok, %Placement{} = placement} <-
           PlacementLedger.get(state.ctx.placement_ledger, placement_id),
         false <- Placement.terminal?(placement),
         {:ok, failed} <-
           PlacementLedger.fail_placement(
             state.ctx.placement_ledger,
             placement_id,
             detail_code,
             now_ms: now_ms
           ) do
      discard_mailbox_command(state.ctx.node_mailbox, placement.command_id)
      cleanup = cleanup_jit_for_placement(placement, state.ctx)
      {:ok, %{placement: failed, jit_cleanup: cleanup}}
    else
      {:ok, %PlacementTombstone{}} -> {:error, :placement_terminal}
      true -> {:error, :placement_terminal}
      {:error, reason} -> {:error, reason}
    end
  end

  defp discard_mailbox_command(mailbox, command_id) do
    case NodeMailbox.discard(mailbox, command_id) do
      {:ok, _command} -> :ok
      {:error, :unknown_command} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp cleanup_jit_for_placement(placement, ctx) do
    case ScaleSetClient.read_jit_state(ctx.scale_set_client) do
      {:ok, states} ->
        states
        |> Enum.filter(&jit_matches_placement?(&1, placement.id))
        |> Enum.reduce([], fn jit, errors ->
          case ScaleSetClient.retire_jit(
                 ctx.scale_set_client,
                 jit.pool_id,
                 jit.scale_set_id,
                 jit.work_handle
               ) do
            {:ok, _result} ->
              release_offer_for_handle(ctx.offer_ledger, jit.pool_id, jit.work_handle)

              with :ok <-
                     PlacementLedger.release_terminal_fence(
                       ctx.placement_ledger,
                       placement.id
                     ),
                   {:ok, _} <-
                     ScaleSetClient.confirm_jit_retirement(
                       ctx.scale_set_client,
                       jit.pool_id,
                       jit.scale_set_id,
                       jit.work_handle,
                       Map.get(jit, :ownership_revision)
                     ) do
                errors
              else
                {:error, reason} -> [reason | errors]
              end

            {:error, reason} ->
              [reason | errors]
          end
        end)
        |> case do
          [] -> :ok
          errors -> {:pending, Enum.reverse(errors)}
        end

      {:error, reason} ->
        {:pending, reason}
    end
  end

  defp jit_matches_placement?(jit, placement_id) do
    case WorkIdentity.for_handle(jit.pool_id, jit.scale_set_id, jit.work_handle) do
      {:ok, identity} -> identity.placement_id == placement_id
      {:error, _reason} -> false
    end
  end

  defp release_offer_for_handle(ledger, pool_id, work_handle) do
    case OfferLedger.find_by_handle(ledger, pool_id, work_handle) do
      {:ok, offer} ->
        case OfferLedger.release(ledger, offer.id) do
          {:ok, _released} -> :ok
          {:error, _reason} -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp maybe_reset_sessions(state, {:scaleset_transport, _}),
    do: %{state | sessions_active: false}

  defp maybe_reset_sessions(state, {:scaleset_error, _}), do: %{state | sessions_active: false}

  defp maybe_reset_sessions(state, :invalid_scaleset_snapshot),
    do: %{state | sessions_active: false}

  defp maybe_reset_sessions(state, _reason), do: state

  defp schedule_tick(%{auto_reconcile: true} = state) do
    Process.send_after(self(), :reconcile_tick, state.reconcile_interval_ms)
    state
  end

  defp schedule_tick(state), do: state

  defp policies(values) when is_list(values) and length(values) in 1..8 do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, acc} ->
      result = if match?(%PoolPolicy{}, value), do: {:ok, value}, else: PoolPolicy.new(value)

      case result do
        {:ok, policy} when not is_map_key(acc, policy.id) ->
          {:cont, {:ok, Map.put(acc, policy.id, policy)}}

        {:ok, _policy} ->
          {:halt, {:error, :duplicate_pool_policy}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp policies(_), do: {:error, :invalid_pool_policies}

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp now_unix_ms, do: System.system_time(:millisecond)
end
