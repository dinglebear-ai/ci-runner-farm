defmodule CrfController.OfferPlanner do
  alias CrfController.{OfferLedger, Placement, PlacementLedger, PoolPolicy, Scheduler}

  def trim_excess(ctx, now_ms) do
    placements = PlacementLedger.snapshot(ctx.placement_ledger)
    offers = OfferLedger.snapshot(ctx.offer_ledger, now_ms: now_ms)

    ctx.policies
    |> Enum.sort_by(fn {pool_id, _policy} -> pool_id end)
    |> Enum.reduce_while(:ok, fn {pool_id, policy}, :ok ->
      service = Enum.count(placements, &(&1.pool_id == pool_id and not Placement.terminal?(&1)))
      allowed = max(policy.max_concurrency - service, 0)
      pool_offers = Enum.filter(offers, &(&1.pool_id == pool_id))
      excess = max(length(pool_offers) - allowed, 0)

      pool_offers
      |> Enum.filter(&(&1.state == :offered))
      |> Enum.sort_by(&{-&1.created_at_ms, &1.id})
      |> Enum.take(excess)
      |> Enum.reduce_while(:ok, fn offer, :ok ->
        case OfferLedger.release(ctx.offer_ledger, offer.id) do
          {:ok, _} -> {:cont, :ok}
          {:error, :unknown_offer} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def plan(snapshot, blocked, ctx, planner, now_ms) do
    placements = PlacementLedger.snapshot(ctx.placement_ledger)
    offers = OfferLedger.snapshot(ctx.offer_ledger, now_ms: now_ms)
    health = Map.new(snapshot.pools, &{&1.pool_id, &1.session_healthy})

    needs =
      Map.new(ctx.policies, fn {pool_id, policy} ->
        service = Enum.count(placements, &(&1.pool_id == pool_id and not Placement.terminal?(&1)))
        pool_offers = Enum.count(offers, &(&1.pool_id == pool_id))

        need =
          if MapSet.member?(blocked, pool_id) or Map.get(health, pool_id, false) != true do
            0
          else
            max(policy.max_concurrency - service - pool_offers, 0)
          end

        {pool_id, need}
      end)

    {candidates, planner} = build_candidates(ctx.policies, needs, planner)

    if candidates == [] do
      {:ok, planner}
    else
      requirements = Enum.map(candidates, & &1.requirement)

      with {:ok, schedule} <- Scheduler.schedule(requirements, scheduler_opts(ctx)) do
        by_work = Map.new(candidates, &{&1.requirement.work_id, &1})

        case reserve_scheduled(schedule.placements, by_work, ctx, now_ms) do
          :ok -> {:ok, planner}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  def advertised_leases(snapshot, ctx, now_ms) do
    placements = PlacementLedger.snapshot(ctx.placement_ledger)
    offers = OfferLedger.snapshot(ctx.offer_ledger, now_ms: now_ms)

    snapshot.pools
    |> Enum.reduce_while({:ok, %{}}, fn pool, {:ok, leases} ->
      service =
        Enum.count(placements, &(&1.pool_id == pool.pool_id and not Placement.terminal?(&1)))

      pending = Enum.count(offers, &(&1.pool_id == pool.pool_id))
      advertised = service + pending

      if advertised <= 64 do
        {:cont, {:ok, Map.put(leases, pool.pool_id, advertised)}}
      else
        {:halt, {:error, :advertised_capacity_exceeds_fuse}}
      end
    end)
  end

  defp reserve_scheduled(placements, by_work, ctx, now_ms) do
    Enum.reduce_while(placements, :ok, fn placement, :ok ->
      case Map.fetch(by_work, placement.work_id) do
        {:ok, candidate} ->
          case OfferLedger.reserve(
                 ctx.offer_ledger,
                 %{
                   id: candidate.offer_id,
                   pool_id: candidate.policy.id,
                   node_id: placement.node_id,
                   node_generation: placement.node_generation,
                   resources: candidate.policy.resources,
                   expires_at_ms: now_ms + ctx.offer_ttl_ms
                 },
                 now_ms: now_ms
               ) do
            {:ok, _offer} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        :error ->
          {:halt, {:error, :scheduler_offer_identity_mismatch}}
      end
    end)
  end

  defp build_candidates(policies, needs, planner) do
    ordered = policies |> Map.values() |> Enum.sort_by(& &1.id)

    if ordered == [] do
      {[], planner}
    else
      cursor = rem(planner.cursor, length(ordered))
      rotated = Enum.drop(ordered, cursor) ++ Enum.take(ordered, cursor)

      {candidates, _needs, sequence} =
        take_candidates(
          rotated,
          needs,
          planner.max_new_offers_per_tick,
          planner.offer_sequence,
          []
        )

      next = %{
        planner
        | offer_sequence: sequence,
          cursor: rem(cursor + 1, length(ordered))
      }

      {Enum.reverse(candidates), next}
    end
  end

  defp take_candidates(_ordered, needs, 0, sequence, acc), do: {acc, needs, sequence}

  defp take_candidates(ordered, needs, remaining, sequence, acc) do
    case next_needed(ordered, needs) do
      nil ->
        {acc, needs, sequence}

      {policy, reordered} ->
        sequence = sequence + 1
        work_id = "lease-plan-#{sequence}"
        offer_id = "lease-#{sequence}"

        case PoolPolicy.work_requirement(policy, work_id) do
          {:ok, requirement} ->
            updated = Map.update!(needs, policy.id, &max(&1 - 1, 0))
            candidate = %{policy: policy, requirement: requirement, offer_id: offer_id}

            take_candidates(
              reordered,
              updated,
              remaining - 1,
              sequence,
              [candidate | acc]
            )

          {:error, _reason} ->
            {acc, needs, sequence}
        end
    end
  end

  defp next_needed(ordered, needs) do
    case Enum.split_while(ordered, &(Map.get(needs, &1.id, 0) <= 0)) do
      {_before, []} -> nil
      {before, [policy | tail]} -> {policy, tail ++ before ++ [policy]}
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
