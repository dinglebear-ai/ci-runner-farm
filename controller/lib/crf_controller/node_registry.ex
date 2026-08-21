defmodule CrfController.NodeRegistry do
  use GenServer

  alias CrfController.Node

  @default_stale_after_ms 15_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def register(server \\ __MODULE__, attrs, opts \\ []) do
    GenServer.call(server, {:register, attrs, Keyword.get(opts, :now_ms, now_ms())})
  end

  def heartbeat(server \\ __MODULE__, node_id, generation, available, opts \\ []) do
    GenServer.call(
      server,
      {:heartbeat, node_id, generation, available,
       Keyword.get(opts, :active_placements, MapSet.new()), Keyword.get(opts, :now_ms, now_ms())}
    )
  end

  def set_draining(server \\ __MODULE__, node_id, generation, draining) do
    GenServer.call(server, {:set_draining, node_id, generation, draining})
  end

  def get(node_id), do: get(__MODULE__, node_id)
  def get(server, node_id), do: GenServer.call(server, {:get, node_id})

  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  def prune_stale(server \\ __MODULE__, now_ms \\ now_ms()) do
    GenServer.call(server, {:prune_stale, now_ms})
  end

  @impl true
  def init(opts) do
    stale_after_ms = Keyword.get(opts, :stale_after_ms, @default_stale_after_ms)

    if not is_integer(stale_after_ms) or stale_after_ms < 100 do
      {:stop, :invalid_stale_after_ms}
    else
      state = %{nodes: %{}, stale_after_ms: stale_after_ms}
      schedule_prune(stale_after_ms)
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:register, attrs, now_ms}, _from, state) do
    with {:ok, incoming} <- Node.new(attrs, now_ms),
         {:ok, node} <- reconcile_registration(state.nodes[incoming.id], incoming) do
      {:reply, {:ok, node}, put_in(state, [:nodes, node.id], node)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:heartbeat, node_id, generation, available, active_placements, now_ms},
        _from,
        state
      ) do
    with %Node{} = node <- Map.get(state.nodes, node_id),
         {:ok, updated} <-
           Node.heartbeat(node, generation, available, active_placements, now_ms) do
      {:reply, {:ok, updated}, put_in(state, [:nodes, node_id], updated)}
    else
      nil -> {:reply, {:error, :unknown_node}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_draining, node_id, generation, draining}, _from, state) do
    with %Node{} = node <- Map.get(state.nodes, node_id),
         {:ok, updated} <- Node.set_draining(node, generation, draining) do
      {:reply, {:ok, updated}, put_in(state, [:nodes, node_id], updated)}
    else
      nil -> {:reply, {:error, :unknown_node}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, node_id}, _from, state) do
    case Map.fetch(state.nodes, node_id) do
      {:ok, node} -> {:reply, {:ok, node}, state}
      :error -> {:reply, {:error, :unknown_node}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    nodes = state.nodes |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, nodes, state}
  end

  def handle_call({:prune_stale, now_ms}, _from, state) do
    {removed, nodes} = prune(state.nodes, now_ms, state.stale_after_ms)
    {:reply, removed, %{state | nodes: nodes}}
  end

  @impl true
  def handle_info(:prune, state) do
    {_removed, nodes} = prune(state.nodes, now_ms(), state.stale_after_ms)
    schedule_prune(state.stale_after_ms)
    {:noreply, %{state | nodes: nodes}}
  end

  defp reconcile_registration(nil, %Node{} = incoming), do: {:ok, incoming}

  defp reconcile_registration(
         %Node{generation: current_generation},
         %Node{generation: incoming_generation}
       )
       when incoming_generation < current_generation,
       do: {:error, :stale_generation}

  defp reconcile_registration(
         %Node{generation: generation} = current,
         %Node{generation: generation} = incoming
       ) do
    if same_incarnation?(current, incoming) do
      {:ok,
       %{
         incoming
         | draining: current.draining,
           active_placements: current.active_placements
       }}
    else
      {:error, :generation_conflict}
    end
  end

  defp reconcile_registration(%Node{} = current, %Node{} = incoming) do
    {:ok, %{incoming | draining: current.draining}}
  end

  defp same_incarnation?(left, right) do
    left.id == right.id and left.generation == right.generation and left.os == right.os and
      left.arch == right.arch and left.execution_backends == right.execution_backends and
      left.capabilities == right.capabilities and left.total == right.total
  end

  defp prune(nodes, now_ms, stale_after_ms) do
    Enum.reduce(nodes, {[], %{}}, fn {id, node}, {removed, kept} ->
      if now_ms - node.last_seen_ms > stale_after_ms do
        {[id | removed], kept}
      else
        {removed, Map.put(kept, id, node)}
      end
    end)
    |> then(fn {removed, kept} -> {Enum.sort(removed), kept} end)
  end

  defp schedule_prune(stale_after_ms) do
    Process.send_after(self(), :prune, max(div(stale_after_ms, 2), 100))
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
