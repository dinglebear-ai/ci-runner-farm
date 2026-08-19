defmodule CrfController.PlacementLedger do
  use GenServer

  alias CrfController.{Placement, PlacementStateStore}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def begin_placement(server \\ __MODULE__, attrs, opts \\ []) do
    GenServer.call(server, {:begin, attrs, Keyword.get(opts, :now_ms, now_ms())})
  end

  def command_ack(
        server \\ __MODULE__,
        node_id,
        generation,
        command_id,
        idempotency_key,
        status,
        detail_code,
        opts \\ []
      ) do
    GenServer.call(
      server,
      {:command_ack, node_id, generation, command_id, idempotency_key, status, detail_code,
       Keyword.get(opts, :now_ms, now_ms())}
    )
  end

  def placement_update(
        server \\ __MODULE__,
        node_id,
        generation,
        placement_id,
        command_id,
        state,
        detail_code,
        opts \\ []
      ) do
    GenServer.call(
      server,
      {:placement_update, node_id, generation, placement_id, command_id, state, detail_code,
       Keyword.get(opts, :now_ms, now_ms())}
    )
  end

  def get(server \\ __MODULE__, placement_id), do: GenServer.call(server, {:get, placement_id})

  def fail_placement(server \\ __MODULE__, placement_id, detail_code, opts \\ []) do
    GenServer.call(
      server,
      {:fail_placement, placement_id, detail_code, Keyword.get(opts, :now_ms, now_ms())}
    )
  end

  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    state_path = Keyword.get(opts, :state_path)

    case PlacementStateStore.load(state_path) do
      {:ok, placements} ->
        commands = Map.new(Map.values(placements), &{&1.command_id, &1.id})
        {:ok, %{placements: placements, commands: commands, state_path: state_path}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:begin, attrs, now_ms}, _from, state) do
    with {:ok, incoming} <- Placement.new(attrs, now_ms),
         {:ok, placement} <- reconcile_begin(state, incoming),
         {:ok, next_state} <- persist_placement(state, placement) do
      {:reply, {:ok, placement}, next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:command_ack, node_id, generation, command_id, idempotency_key, status, detail_code,
         now_ms},
        _from,
        state
      ) do
    with {:ok, placement_id} <- fetch_command(state, command_id),
         %Placement{} = placement <- Map.get(state.placements, placement_id),
         :ok <- command_identity(placement, node_id, generation, command_id, idempotency_key),
         {:ok, updated} <- Placement.command_ack(placement, status, detail_code, now_ms),
         {:ok, next_state} <- persist_placement(state, updated) do
      {:reply, {:ok, updated}, next_state}
    else
      nil -> {:reply, {:error, :unknown_placement}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:placement_update, node_id, generation, placement_id, command_id, next_state,
         detail_code, now_ms},
        _from,
        state
      ) do
    with %Placement{} = placement <- Map.get(state.placements, placement_id),
         {:ok, placement} <-
           placement_update_identity(placement, node_id, generation, command_id, now_ms),
         {:ok, updated} <- Placement.advance(placement, next_state, detail_code, now_ms),
         {:ok, persisted_state} <- persist_placement(state, updated) do
      {:reply, {:ok, updated}, persisted_state}
    else
      nil -> {:reply, {:error, :unknown_placement}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fail_placement, placement_id, detail_code, now_ms}, _from, state) do
    with %Placement{} = placement <- Map.get(state.placements, placement_id),
         {:ok, updated} <- Placement.advance(placement, :failed, detail_code, now_ms),
         {:ok, next_state} <- persist_placement(state, updated) do
      {:reply, {:ok, updated}, next_state}
    else
      nil -> {:reply, {:error, :unknown_placement}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, placement_id}, _from, state) do
    case Map.fetch(state.placements, placement_id) do
      {:ok, placement} -> {:reply, {:ok, placement}, state}
      :error -> {:reply, {:error, :unknown_placement}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    placements = state.placements |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, placements, state}
  end

  defp reconcile_begin(state, %Placement{} = incoming) do
    existing = Map.get(state.placements, incoming.id)
    command_owner = Map.get(state.commands, incoming.command_id)

    cond do
      is_nil(existing) and is_nil(command_owner) ->
        {:ok, incoming}

      match?(%Placement{}, existing) and Placement.same_command?(existing, incoming) and
          command_owner == incoming.id ->
        {:ok, existing}

      not is_nil(command_owner) and command_owner != incoming.id ->
        {:error, :command_id_conflict}

      true ->
        {:error, :placement_conflict}
    end
  end

  defp command_identity(placement, node_id, generation, command_id, idempotency_key) do
    cond do
      placement.node_id != node_id -> {:error, :node_identity_mismatch}
      placement.node_generation != generation -> {:error, :generation_mismatch}
      placement.command_id != command_id -> {:error, :command_id_mismatch}
      placement.idempotency_key != idempotency_key -> {:error, :idempotency_key_mismatch}
      true -> :ok
    end
  end

  defp placement_update_identity(placement, node_id, generation, command_id, now_ms) do
    cond do
      placement.node_id != node_id ->
        {:error, :node_identity_mismatch}

      placement.command_id != command_id ->
        {:error, :command_id_mismatch}

      generation < placement.node_generation ->
        {:error, :generation_mismatch}

      true ->
        Placement.adopt_generation(placement, node_id, generation, now_ms)
    end
  end

  defp fetch_command(state, command_id) do
    case Map.fetch(state.commands, command_id) do
      {:ok, placement_id} -> {:ok, placement_id}
      :error -> {:error, :unknown_command}
    end
  end

  defp persist_placement(state, %Placement{} = placement) do
    next_state = put_placement(state, placement)

    case PlacementStateStore.persist(next_state.state_path, next_state.placements) do
      :ok -> {:ok, next_state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_placement(state, %Placement{} = placement) do
    %{
      state
      | placements: Map.put(state.placements, placement.id, placement),
        commands: Map.put(state.commands, placement.command_id, placement.id)
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
