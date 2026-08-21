defmodule CrfController.CapacityView do
  alias CrfController.{Node, Offer, Placement, Resources}

  @spec effective_available(Node.t(), [Placement.t()]) :: {:ok, Resources.t()} | {:error, atom()}
  def effective_available(%Node{} = node, placements) when is_list(placements),
    do: effective_available(node, placements, [], nil)

  def effective_available(%Node{} = node, placements, offers)
      when is_list(placements) and is_list(offers),
      do: effective_available(node, placements, offers, nil)

  def effective_available(%Node{} = node, placements, offers, exclude_offer_id)
      when is_list(placements) and is_list(offers) do
    reservations =
      placement_reservations(node, placements) ++
        offer_reservations(node, offers, exclude_offer_id)

    Enum.reduce_while(reservations, {:ok, node.available}, fn requested, {:ok, available} ->
      case subtract(available, requested) do
        {:ok, remaining} -> {:cont, {:ok, remaining}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec effective_nodes([Node.t()], [Placement.t()]) :: {:ok, [Node.t()]} | {:error, atom()}
  def effective_nodes(nodes, placements) when is_list(nodes) and is_list(placements),
    do: effective_nodes(nodes, placements, [])

  def effective_nodes(nodes, placements, offers)
      when is_list(nodes) and is_list(placements) and is_list(offers) do
    nodes
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case effective_available(node, placements, offers) do
        {:ok, available} -> {:cont, {:ok, [%{node | available: available} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      error -> error
    end
  end

  defp placement_reservations(node, placements) do
    placements
    |> Enum.filter(fn placement ->
      placement.node_id == node.id and placement.node_generation == node.generation and
        not Placement.terminal?(placement) and
        not MapSet.member?(node.active_placements, placement.id)
    end)
    |> Enum.map(& &1.resources)
  end

  defp offer_reservations(node, offers, exclude_offer_id) do
    offers
    |> Enum.filter(fn
      %Offer{} = offer ->
        offer.node_id == node.id and offer.node_generation == node.generation and
          offer.id != exclude_offer_id

      _ ->
        false
    end)
    |> Enum.map(& &1.resources)
  end

  defp subtract(%Resources{} = available, %Resources{} = requested) do
    if Resources.fits?(available, requested) do
      {:ok,
       %Resources{
         cpu_millis: available.cpu_millis - requested.cpu_millis,
         memory_bytes: available.memory_bytes - requested.memory_bytes
       }}
    else
      {:error, :controller_reservation_exceeds_node_available}
    end
  end
end
