defmodule CrfController.DemandWork do
  alias CrfController.{
    Node,
    NodeMailbox,
    NodeRegistry,
    OfferLedger,
    Placement,
    PlacementCoordinator,
    PlacementTombstone,
    PlacementLedger,
    PoolPolicy,
    ScaleSetClient,
    Scheduler,
    WorkIdentity
  }

  @command_ttl_ms 60_000

  def reconcile_jit_states(jit_states, _snapshot, ctx, now_ms, now_unix_ms)
      when is_list(jit_states) do
    jit_states
    |> Enum.sort_by(&{&1.pool_id, &1.scale_set_id, &1.work_handle})
    |> Enum.reduce_while({:ok, MapSet.new(), MapSet.new()}, fn jit,
                                                               {:ok, blocked, retry_deferred} ->
      retry_key = {jit.pool_id, jit.work_handle}

      if MapSet.member?(retry_deferred, retry_key) do
        {:cont, {:ok, blocked, retry_deferred}}
      else
        result = reconcile_jit(jit, ctx, now_ms, now_unix_ms)

        case result do
          :ok ->
            {:cont, {:ok, blocked, retry_deferred}}

          {:blocked, pool_id} ->
            {:cont, {:ok, MapSet.put(blocked, pool_id), retry_deferred}}

          # GitHub refuses to delete a JIT runner while it is executing its one
          # job. Keep the pool schedulable, but retry each handle only once per
          # tick because the sidecar reports both issued and retirement-started
          # records for the same lifecycle. Other idle handles in the pool must
          # still be allowed to retire.
          {:error, {:scaleset_error, "jit_runner_delete_failed"}} ->
            {:cont, {:ok, blocked, MapSet.put(retry_deferred, retry_key)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    end)
    |> case do
      {:ok, blocked, _retry_deferred} -> {:ok, blocked}
      {:error, reason} -> {:error, reason}
    end
  end

  def reconcile_acquired(snapshot, jit_states, ctx, now_ms, now_unix_ms) do
    issued = MapSet.new(jit_states, &{&1.pool_id, &1.work_handle})
    placements = PlacementLedger.snapshot(ctx.placement_ledger)

    snapshot.pools
    |> Enum.sort_by(& &1.pool_id)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn pool, {:ok, blocked} ->
      policy = Map.get(ctx.policies, pool.pool_id)

      service =
        Enum.count(
          placements,
          &(&1.pool_id == pool.pool_id and not Placement.terminal?(&1))
        )

      available_slots = if policy, do: max(policy.max_concurrency - service, 0), else: 0

      pool.acquired_handles
      |> Enum.sort()
      |> Enum.reduce_while({:ok, blocked, available_slots}, fn handle, {:ok, blocked, slots} ->
        if MapSet.member?(issued, {pool.pool_id, handle}) do
          {:cont, {:ok, blocked, slots}}
        else
          reconcile_acquired_with_capacity(
            pool,
            handle,
            slots,
            snapshot.ownership_revision,
            ctx,
            now_ms,
            now_unix_ms,
            blocked
          )
        end
      end)
      |> case do
        {:ok, blocked, _slots} -> {:cont, {:ok, blocked}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def release_stale_assigned_offers(snapshot, jit_states, ctx, now_ms) do
    acquired =
      snapshot.pools
      |> Enum.flat_map(fn pool ->
        Enum.map(pool.acquired_handles, &{pool.pool_id, &1})
      end)
      |> MapSet.new()

    issued = MapSet.new(jit_states, &{&1.pool_id, &1.work_handle})
    current_scale_sets = Map.new(snapshot.pools, &{&1.pool_id, &1.scale_set_id})

    ctx.offer_ledger
    |> OfferLedger.snapshot(now_ms: now_ms)
    |> Enum.filter(&(&1.state == :assigned))
    |> Enum.reduce_while(:ok, fn offer, :ok ->
      key = {offer.pool_id, offer.work_handle}

      if MapSet.member?(acquired, key) or MapSet.member?(issued, key) do
        {:cont, :ok}
      else
        with scale_set_id when is_integer(scale_set_id) <-
               Map.get(offer, :scale_set_id) || Map.get(current_scale_sets, offer.pool_id),
             {:ok, identity} <-
               WorkIdentity.for_handle(offer.pool_id, scale_set_id, offer.work_handle) do
          case PlacementLedger.get(ctx.placement_ledger, identity.placement_id) do
            {:error, :unknown_placement} ->
              case OfferLedger.release(ctx.offer_ledger, offer.id) do
                {:ok, _} -> {:cont, :ok}
                {:error, :unknown_offer} -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            {:ok, _record} ->
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        else
          nil -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  # Scale-set `assigned_jobs` is queue demand, not runner busy state. It drops to
  # zero as soon as GitHub hands a job to a runner, so using it to reclaim an
  # observed placement kills long-running jobs after `offer_ttl_ms`. Issued JIT
  # runners are instead retired by their single-job lifecycle or by the existing
  # inactive/lost-placement reconciliation paths, both of which have terminal
  # evidence that this demand snapshot lacks.
  def reclaim_unassigned(_snapshot, _ctx, _now_ms, _now_unix_ms), do: {:ok, 0}

  defp reconcile_acquired_with_capacity(
         pool,
         handle,
         slots,
         ownership_revision,
         ctx,
         now_ms,
         now_unix_ms,
         blocked
       ) do
    with {:ok, identity} <- WorkIdentity.for_handle(pool.pool_id, pool.scale_set_id, handle) do
      case PlacementLedger.get(ctx.placement_ledger, identity.placement_id) do
        {:ok, %PlacementTombstone{}} ->
          case retire_replayed_acquired(
                 pool,
                 handle,
                 identity,
                 ownership_revision,
                 ctx
               ) do
            :ok -> {:cont, {:ok, blocked, slots}}
            :blocked -> {:cont, {:ok, MapSet.put(blocked, pool.pool_id), slots}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:ok, %Placement{}} ->
          {:cont, {:ok, blocked, slots}}

        {:error, :unknown_placement} when slots == 0 ->
          {:cont, {:ok, MapSet.put(blocked, pool.pool_id), slots}}

        {:error, :unknown_placement} ->
          case reconcile_acquired_handle(pool, handle, ctx, now_ms, now_unix_ms) do
            :ok -> {:cont, {:ok, blocked, slots - 1}}
            :stale -> {:cont, {:ok, blocked, slots}}
            :blocked -> {:cont, {:ok, MapSet.put(blocked, pool.pool_id), slots}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp retire_replayed_acquired(pool, handle, identity, ownership_revision, ctx) do
    case Map.get(ctx.policies, pool.pool_id) do
      nil ->
        :blocked

      %PoolPolicy{} = policy ->
        with {:ok, %{scale_set_id: scale_set_id}} <-
               ScaleSetClient.issue_jit(
                 ctx.scale_set_client,
                 pool.pool_id,
                 pool.scale_set_id,
                 handle,
                 identity.runner_name,
                 policy.work_folder
               ),
             true <- scale_set_id == pool.scale_set_id,
             {:ok, _} <-
               ScaleSetClient.retire_jit(
                 ctx.scale_set_client,
                 pool.pool_id,
                 pool.scale_set_id,
                 handle,
                 ownership_revision
               ),
             :ok <-
               PlacementLedger.release_terminal_fence(
                 ctx.placement_ledger,
                 identity.placement_id
               ),
             {:ok, _} <-
               ScaleSetClient.confirm_jit_retirement(
                 ctx.scale_set_client,
                 pool.pool_id,
                 pool.scale_set_id,
                 handle,
                 ownership_revision
               ) do
          :ok
        else
          false -> {:error, :jit_scale_set_mismatch}
          {:error, {:scaleset_error, "jit_issue_ambiguous"}} -> :blocked
          {:error, {:scaleset_error, "jit_runner_delete_failed"}} -> :blocked
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp reconcile_jit(%{state: "retired"} = jit, ctx, now_ms, _now_unix_ms) do
    with {:ok, identity} <-
           WorkIdentity.for_handle(jit.pool_id, jit.scale_set_id, jit.work_handle),
         :ok <- ensure_retired_placement_terminal(identity.placement_id, ctx, now_ms) do
      confirm_retirement_and_release(
        jit.pool_id,
        jit.scale_set_id,
        jit.work_handle,
        ctx,
        jit.ownership_revision
      )
    end
  end

  defp reconcile_jit(jit, ctx, now_ms, now_unix_ms) do
    case Map.get(ctx.policies, jit.pool_id) do
      nil ->
        retire_and_release(
          jit.pool_id,
          jit.scale_set_id,
          jit.work_handle,
          ctx,
          Map.get(jit, :ownership_revision)
        )

      %PoolPolicy{} = policy ->
        with {:ok, identity} <-
               WorkIdentity.for_handle(jit.pool_id, jit.scale_set_id, jit.work_handle) do
          case PlacementLedger.get(ctx.placement_ledger, identity.placement_id) do
            {:ok, %PlacementTombstone{}} ->
              retire_and_release(
                jit.pool_id,
                jit.scale_set_id,
                jit.work_handle,
                ctx,
                Map.get(jit, :ownership_revision)
              )

            {:ok, %Placement{} = placement} ->
              reconcile_existing_jit(jit, policy, identity, placement, ctx, now_ms, now_unix_ms)

            {:error, :unknown_placement} ->
              with {:ok, active} <- recover_active(jit, policy, identity, ctx, now_ms) do
                cond do
                  active ->
                    :ok

                  jit.descriptor_available ->
                    dispatch_replay(jit, policy, identity, ctx, now_ms, now_unix_ms)

                  true ->
                    retire_and_release(
                      jit.pool_id,
                      jit.scale_set_id,
                      jit.work_handle,
                      ctx,
                      Map.get(jit, :ownership_revision)
                    )
                end
              end

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  defp ensure_retired_placement_terminal(placement_id, ctx, now_ms) do
    case PlacementLedger.get(ctx.placement_ledger, placement_id) do
      {:ok, %PlacementTombstone{}} ->
        :ok

      {:ok, %Placement{} = placement} ->
        if Placement.terminal?(placement) do
          :ok
        else
          case PlacementLedger.fail_placement(
                 ctx.placement_ledger,
                 placement_id,
                 "jit_retired",
                 now_ms: now_ms
               ) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, {:retired_placement_compensation_failed, reason}}
          end
        end

      {:error, :unknown_placement} ->
        :ok

      {:error, reason} ->
        {:error, {:retired_placement_lookup_failed, reason}}
    end
  end

  defp reconcile_existing_jit(jit, policy, identity, placement, ctx, now_ms, now_unix_ms) do
    cond do
      Placement.terminal?(placement) ->
        retire_and_release(
          jit.pool_id,
          jit.scale_set_id,
          jit.work_handle,
          ctx,
          Map.get(jit, :ownership_revision)
        )

      true ->
        case active_node(identity.placement_id, ctx.node_registry) do
          %Node{} = node ->
            adopt_active_placement(node, placement, ctx, now_ms)

          nil ->
            reconcile_inactive_placement(
              jit,
              policy,
              identity,
              placement,
              ctx,
              now_ms,
              now_unix_ms
            )
        end
    end
  end

  defp adopt_active_placement(node, placement, ctx, now_ms) do
    next_state = if placement.state == :running, do: :running, else: :observed

    cond do
      node.id != placement.node_id ->
        {:error, :placement_node_identity_conflict}

      placement.state == next_state and placement.node_generation == node.generation ->
        discard_start_command(ctx.node_mailbox, placement.command_id)

      true ->
        with {:ok, _updated} <-
               PlacementLedger.placement_update(
                 ctx.placement_ledger,
                 node.id,
                 node.generation,
                 placement.id,
                 placement.command_id,
                 next_state,
                 nil,
                 now_ms: now_ms
               ) do
          discard_start_command(ctx.node_mailbox, placement.command_id)
        end
    end
  end

  defp discard_start_command(mailbox, command_id) do
    case NodeMailbox.discard(mailbox, command_id) do
      {:ok, _command} -> :ok
      {:error, :unknown_command} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_inactive_placement(
         jit,
         policy,
         identity,
         %Placement{state: :commanded} = placement,
         ctx,
         now_ms,
         now_unix_ms
       ) do
    case NodeMailbox.get(ctx.node_mailbox, placement.command_id) do
      {:ok, _command} ->
        :ok

      {:error, :unknown_command} ->
        cond do
          not jit.descriptor_available ->
            fail_and_retire(placement, jit, "jit_descriptor_unavailable", ctx, now_ms)

          true ->
            replay_commanded(jit, policy, identity, placement, ctx, now_ms, now_unix_ms)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_inactive_placement(
         _jit,
         _policy,
         _identity,
         %Placement{},
         _ctx,
         _now_ms,
         _now_unix_ms
       ),
       do: :ok

  defp replay_commanded(jit, policy, identity, placement, ctx, now_ms, now_unix_ms) do
    node = Enum.find(NodeRegistry.snapshot(ctx.node_registry), &(&1.id == placement.node_id))

    case node do
      nil ->
        {:blocked, jit.pool_id}

      %Node{generation: generation} when generation > placement.node_generation ->
        fail_and_retire(placement, jit, "node_generation_lost", ctx, now_ms)

      %Node{generation: generation} when generation < placement.node_generation ->
        {:blocked, jit.pool_id}

      %Node{} ->
        with {:ok, offer} <-
               OfferLedger.reserve_assigned(
                 ctx.offer_ledger,
                 %{
                   id: identity.offer_id,
                   pool_id: policy.id,
                   scale_set_id: jit.scale_set_id,
                   node_id: placement.node_id,
                   node_generation: placement.node_generation,
                   resources: placement.resources,
                   expires_at_ms: now_ms + ctx.offer_ttl_ms
                 },
                 jit.work_handle,
                 now_ms: now_ms
               ) do
          case ScaleSetClient.issue_jit(
                 ctx.scale_set_client,
                 jit.pool_id,
                 jit.scale_set_id,
                 jit.work_handle,
                 identity.runner_name,
                 policy.work_folder
               ) do
            {:ok, %{descriptor: descriptor, scale_set_id: scale_set_id}}
            when scale_set_id == jit.scale_set_id ->
              dispatch(
                jit.pool_id,
                jit.scale_set_id,
                jit.work_handle,
                policy,
                identity,
                offer,
                descriptor,
                ctx,
                now_ms,
                now_unix_ms
              )

            {:ok, _} ->
              {:error, :jit_scale_set_mismatch}

            {:error, {:scaleset_error, "jit_issue_ambiguous"}} ->
              {:blocked, jit.pool_id}

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  defp fail_and_retire(placement, jit, detail_code, ctx, now_ms) do
    with {:ok, _failed} <-
           PlacementLedger.fail_placement(
             ctx.placement_ledger,
             placement.id,
             detail_code,
             now_ms: now_ms
           ),
         :ok <-
           retire_and_release(
             jit.pool_id,
             jit.scale_set_id,
             jit.work_handle,
             ctx,
             Map.get(jit, :ownership_revision)
           ) do
      :ok
    end
  end

  defp active_node(placement_id, node_registry) do
    NodeRegistry.snapshot(node_registry)
    |> Enum.find(&MapSet.member?(&1.active_placements, placement_id))
  end

  defp recover_active(jit, policy, identity, ctx, now_ms) do
    node =
      NodeRegistry.snapshot(ctx.node_registry)
      |> Enum.find(&MapSet.member?(&1.active_placements, identity.placement_id))

    case node do
      nil ->
        {:ok, false}

      %Node{} ->
        attrs = %{
          id: identity.placement_id,
          command_id: identity.command_id,
          idempotency_key: identity.idempotency_key,
          node_id: node.id,
          node_generation: node.generation,
          work_id: identity.work_id,
          pool_id: jit.pool_id,
          resources: policy.resources
        }

        with {:ok, placement} <-
               PlacementLedger.begin_placement(ctx.placement_ledger, attrs, now_ms: now_ms),
             {:ok, _} <-
               PlacementLedger.placement_update(
                 ctx.placement_ledger,
                 node.id,
                 node.generation,
                 placement.id,
                 placement.command_id,
                 :observed,
                 nil,
                 now_ms: now_ms
               ) do
          {:ok, true}
        end
    end
  end

  defp dispatch_replay(jit, policy, identity, ctx, now_ms, now_unix_ms) do
    case ensure_offer(policy, identity, jit.scale_set_id, jit.work_handle, ctx, now_ms) do
      {:ok, offer} ->
        case ScaleSetClient.issue_jit(
               ctx.scale_set_client,
               jit.pool_id,
               jit.scale_set_id,
               jit.work_handle,
               identity.runner_name,
               policy.work_folder
             ) do
          {:ok, %{descriptor: descriptor, scale_set_id: scale_set_id}}
          when scale_set_id == jit.scale_set_id ->
            dispatch(
              jit.pool_id,
              jit.scale_set_id,
              jit.work_handle,
              policy,
              identity,
              offer,
              descriptor,
              ctx,
              now_ms,
              now_unix_ms
            )

          {:ok, _} ->
            {:error, :jit_scale_set_mismatch}

          {:error, {:scaleset_error, "jit_issue_ambiguous"}} ->
            {:blocked, jit.pool_id}

          {:error, reason} ->
            {:error, reason}
        end

      {:blocked, _reason} ->
        {:blocked, jit.pool_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_acquired_handle(pool, handle, ctx, now_ms, now_unix_ms) do
    case Map.get(ctx.policies, pool.pool_id) do
      nil ->
        :blocked

      %PoolPolicy{} = policy ->
        with {:ok, identity} <- WorkIdentity.for_handle(pool.pool_id, pool.scale_set_id, handle) do
          case PlacementLedger.get(ctx.placement_ledger, identity.placement_id) do
            {:ok, %PlacementTombstone{}} ->
              :blocked

            {:ok, %Placement{}} ->
              :ok

            {:error, :unknown_placement} ->
              issue_new(pool, handle, policy, identity, ctx, now_ms, now_unix_ms)

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  defp issue_new(pool, handle, policy, identity, ctx, now_ms, now_unix_ms) do
    case ensure_offer(policy, identity, pool.scale_set_id, handle, ctx, now_ms) do
      {:ok, offer} ->
        case ScaleSetClient.issue_jit(
               ctx.scale_set_client,
               pool.pool_id,
               pool.scale_set_id,
               handle,
               identity.runner_name,
               policy.work_folder
             ) do
          {:ok, %{descriptor: descriptor, scale_set_id: scale_set_id}}
          when scale_set_id == pool.scale_set_id ->
            dispatch(
              pool.pool_id,
              pool.scale_set_id,
              handle,
              policy,
              identity,
              offer,
              descriptor,
              ctx,
              now_ms,
              now_unix_ms
            )

          {:ok, _} ->
            {:error, :jit_scale_set_mismatch}

          {:error, {:scaleset_error, "jit_issue_ambiguous"}} ->
            :blocked

          {:error, {:scaleset_error, "work_handle_not_available"}} ->
            case release_offer_id(ctx.offer_ledger, offer.id) do
              :ok -> :stale
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:blocked, _reason} ->
        :blocked

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_offer(policy, identity, scale_set_id, handle, ctx, now_ms) do
    case OfferLedger.assign_next(ctx.offer_ledger, policy.id, handle, now_ms: now_ms) do
      {:ok, offer} ->
        {:ok, offer}

      {:error, :no_offer_available} ->
        with {:ok, requirement} <- PoolPolicy.work_requirement(policy, identity.work_id),
             {:ok, result} <- Scheduler.schedule([requirement], scheduler_opts(ctx)) do
          case result.placements do
            [placement] ->
              OfferLedger.reserve_assigned(
                ctx.offer_ledger,
                %{
                  id: identity.offer_id,
                  pool_id: policy.id,
                  scale_set_id: scale_set_id,
                  node_id: placement.node_id,
                  node_generation: placement.node_generation,
                  resources: policy.resources,
                  expires_at_ms: now_ms + ctx.offer_ttl_ms
                },
                handle,
                now_ms: now_ms
              )

            [] ->
              reason =
                case List.first(result.unplaced) do
                  nil -> "infeasible"
                  item -> item.reason
                end

              {:blocked, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch(
         pool_id,
         scale_set_id,
         handle,
         policy,
         identity,
         offer,
         descriptor,
         ctx,
         now_ms,
         now_unix_ms
       ) do
    attrs = %{
      placement_id: identity.placement_id,
      command_id: identity.command_id,
      idempotency_key: identity.idempotency_key,
      work_id: identity.work_id,
      pool_id: pool_id,
      node_id: offer.node_id,
      resources: policy.resources,
      runner_name: identity.runner_name,
      execution_backend: policy.required_backend,
      jit_config: descriptor,
      issued_at_unix_ms: now_unix_ms,
      expires_at_unix_ms: now_unix_ms + @command_ttl_ms,
      offer_id: offer.id,
      work_handle: handle
    }

    case PlacementCoordinator.dispatch(ctx.placement_coordinator, attrs,
           now_ms: now_ms,
           now_unix_ms: now_unix_ms
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        case ScaleSetClient.retire_jit(ctx.scale_set_client, pool_id, scale_set_id, handle) do
          {:ok, _} ->
            with {:ok, _} <-
                   PlacementLedger.fail_placement(
                     ctx.placement_ledger,
                     identity.placement_id,
                     "placement_dispatch_failed",
                     now_ms: now_ms
                   ),
                 :ok <- release_offer_id(ctx.offer_ledger, offer.id),
                 :ok <-
                   PlacementLedger.release_terminal_fence(
                     ctx.placement_ledger,
                     identity.placement_id
                   ),
                 {:ok, _} <-
                   ScaleSetClient.confirm_jit_retirement(
                     ctx.scale_set_client,
                     pool_id,
                     scale_set_id,
                     handle
                   ) do
              {:error, {:placement_dispatch_failed, reason}}
            else
              {:error, compensation_reason} ->
                {:error, {:placement_dispatch_compensation_failed, reason, compensation_reason}}
            end

          {:error, retire_reason} ->
            {:error, {:placement_dispatch_and_retire_failed, reason, retire_reason}}
        end
    end
  end

  defp retire_and_release(pool_id, scale_set_id, handle, ctx, proof_ownership_revision) do
    case ScaleSetClient.retire_jit(
           ctx.scale_set_client,
           pool_id,
           scale_set_id,
           handle,
           proof_ownership_revision
         ) do
      {:ok, _} ->
        confirm_retirement_and_release(
          pool_id,
          scale_set_id,
          handle,
          ctx,
          proof_ownership_revision
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp confirm_retirement_and_release(
         pool_id,
         scale_set_id,
         handle,
         ctx,
         proof_ownership_revision
       ) do
    with :ok <- release_offer_handle(ctx.offer_ledger, pool_id, handle),
         {:ok, identity} <- WorkIdentity.for_handle(pool_id, scale_set_id, handle),
         :ok <-
           PlacementLedger.release_terminal_fence(
             ctx.placement_ledger,
             identity.placement_id
           ),
         {:ok, _} <-
           ScaleSetClient.confirm_jit_retirement(
             ctx.scale_set_client,
             pool_id,
             scale_set_id,
             handle,
             proof_ownership_revision
           ) do
      :ok
    else
      {:error, {:offer_release_failed, _reason} = release_error} ->
        {:error, release_error}

      {:error, reason} ->
        {:error, {:jit_retirement_confirmation_pending, reason}}
    end
  end

  defp release_offer_handle(ledger, pool_id, handle) do
    case OfferLedger.find_by_handle(ledger, pool_id, handle) do
      {:ok, offer} -> release_offer_id(ledger, offer.id)
      {:error, :unknown_offer} -> :ok
      {:error, reason} -> {:error, {:offer_release_failed, reason}}
    end
  end

  defp release_offer_id(ledger, offer_id) do
    case OfferLedger.release(ledger, offer_id) do
      {:ok, _} -> :ok
      {:error, :unknown_offer} -> :ok
      {:error, reason} -> {:error, {:offer_release_failed, reason}}
    end
  end

  defp scheduler_opts(ctx) do
    [
      node_registry: ctx.node_registry,
      placement_ledger: ctx.placement_ledger,
      offer_ledger: ctx.offer_ledger,
      scheduler_client: ctx.scheduler_client
    ]
  end
end
