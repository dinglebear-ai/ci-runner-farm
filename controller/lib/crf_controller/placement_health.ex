defmodule CrfController.PlacementHealth do
  alias CrfController.{Node, Placement}

  def update(placements, nodes, missing_since, now_ms, grace_ms)
      when is_list(placements) and is_list(nodes) and is_map(missing_since) and
             is_integer(now_ms) and is_integer(grace_ms) and grace_ms > 0 do
    node_by_id = Map.new(nodes, &{&1.id, &1})

    live =
      placements
      |> Enum.reject(&Placement.terminal?/1)
      |> Map.new(&{&1.id, &1})

    missing_since =
      Enum.reduce(live, %{}, fn {placement_id, placement}, acc ->
        if unavailable?(placement, Map.get(node_by_id, placement.node_id)) do
          Map.put(acc, placement_id, Map.get(missing_since, placement_id, now_ms))
        else
          acc
        end
      end)

    orphaned =
      live
      |> Map.values()
      |> Enum.filter(fn placement ->
        case Map.get(missing_since, placement.id) do
          since when is_integer(since) -> now_ms - since >= grace_ms
          nil -> false
        end
      end)
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn placement ->
        since = Map.fetch!(missing_since, placement.id)

        %{
          placement_id: placement.id,
          pool_id: placement.pool_id,
          node_id: placement.node_id,
          node_generation: placement.node_generation,
          state: placement.state,
          missing_since_ms: since,
          missing_for_ms: max(now_ms - since, 0)
        }
      end)

    %{missing_since: missing_since, orphaned: orphaned}
  end

  def orphaned?(health, placement_id) when is_map(health) and is_binary(placement_id) do
    Enum.any?(Map.get(health, :orphaned, []), &(&1.placement_id == placement_id))
  end

  defp unavailable?(%Placement{}, nil), do: true

  defp unavailable?(%Placement{} = placement, %Node{} = node) do
    cond do
      node.generation < placement.node_generation -> true
      MapSet.member?(node.active_placements, placement.id) -> false
      placement.state == :commanded and node.generation == placement.node_generation -> false
      true -> true
    end
  end
end
