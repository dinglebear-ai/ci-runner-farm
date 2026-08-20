defmodule CrfController.OperatorActions do
  @moduledoc "Narrow operator mutations over existing controller state owners."

  alias CrfController.{DemandCoordinator, Identifier, Node, NodeRegistry, Placement}

  def set_draining(node_id, generation, draining, server \\ NodeRegistry)

  def set_draining(node_id, generation, draining, server)
      when is_binary(node_id) and is_integer(generation) and generation > 0 and
             is_boolean(draining) do
    with true <- Identifier.valid?(node_id),
         {:ok, %Node{} = node} <- NodeRegistry.set_draining(server, node_id, generation, draining) do
      {:ok,
       %{
         node_id: node.id,
         generation: node.generation,
         draining: node.draining,
         active_placements: node.active_placements |> MapSet.to_list() |> Enum.sort()
       }}
    else
      false -> {:error, :invalid_node_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def set_draining(_, _, _, _), do: {:error, :invalid_drain_request}

  def force_abandon(placement_id, force, server \\ DemandCoordinator)

  def force_abandon(placement_id, true, server) when is_binary(placement_id) do
    with true <- Identifier.valid?(placement_id),
         {:ok, %Placement{} = placement} <-
           DemandCoordinator.force_abandon_placement(server, placement_id, force: true) do
      {:ok,
       %{
         placement_id: placement.id,
         node_id: placement.node_id,
         state: placement.state,
         detail_code: placement.detail_code
       }}
    else
      false -> {:error, :invalid_placement_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def force_abandon(placement_id, false, _server) when is_binary(placement_id),
    do: {:error, :explicit_force_required}

  def force_abandon(_, _, _), do: {:error, :invalid_force_abandon_request}
end
