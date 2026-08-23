defmodule CrfController.PlacementLedger do
  use GenServer

  alias CrfController.{Placement, PlacementStateStore, PlacementTombstone}

  @default_checkpoint_bytes 1_048_576

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

  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)
  def tombstone_snapshot(server \\ __MODULE__), do: GenServer.call(server, :tombstone_snapshot)

  def prune_before_generation(server \\ __MODULE__, node_id, generation) do
    GenServer.call(server, {:prune_before_generation, node_id, generation})
  end

  @impl true
  def init(opts) do
    state_path = Keyword.get(opts, :state_path)
    record_capacity = Keyword.get(opts, :record_capacity, 65_536)
    checkpoint_bytes = Keyword.get(opts, :checkpoint_bytes, @default_checkpoint_bytes)

    with true <- is_integer(checkpoint_bytes) and checkpoint_bytes in 65_536..16_777_216,
         {:ok, %{placements: placements, tombstones: tombstones}} <-
           PlacementStateStore.load(state_path) do
      commands =
        Map.new(
          Map.values(placements) ++ Map.values(tombstones),
          &{&1.command_id, &1.id}
        )

      state = %{
        placements: placements,
        tombstones: tombstones,
        commands: commands,
        record_capacity: record_capacity,
        checkpoint_bytes: checkpoint_bytes,
        state_path: state_path
      }

      # Recovery and schema migration are cold-path operations. Folding any
      # replayed journal into a fresh snapshot here bounds future replay time.
      with :ok <- checkpoint_state(state), do: {:ok, state}
    else
      false -> {:stop, :invalid_placement_checkpoint_bytes}
      {:error, reason} -> {:stop, reason}
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

  def handle_call({:prune_before_generation, node_id, generation}, _from, state)
      when is_binary(node_id) and is_integer(generation) and generation > 0 do
    retained =
      Map.reject(state.tombstones, fn {_id, tombstone} ->
        tombstone.node_id == node_id and tombstone.node_generation < generation
      end)

    if map_size(retained) == map_size(state.tombstones) do
      {:reply, :ok, state}
    else
      next_state = %{state | tombstones: retained} |> rebuild_commands()

      case PlacementStateStore.append(
             state.state_path,
             {:prune_before_generation, node_id, generation}
           ) do
        :ok ->
          # The prune is now authoritative in the WAL. A checkpoint failure is
          # non-ambiguous: recovery replays this record after any stale puts.
          _ = checkpoint_state(next_state)
          {:reply, :ok, next_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(
        {:command_ack, node_id, generation, command_id, idempotency_key, status, detail_code,
         now_ms},
        _from,
        state
      ) do
    with {:ok, placement_id} <- fetch_command(state, command_id),
         {:ok, record} <- fetch_record(state, placement_id) do
      result =
        case record do
          %Placement{} = placement ->
            with :ok <-
                   command_identity(
                     placement,
                     node_id,
                     generation,
                     command_id,
                     idempotency_key
                   ),
                 {:ok, updated} <- Placement.command_ack(placement, status, detail_code, now_ms),
                 {:ok, next_state} <- persist_placement(state, updated) do
              {:ok, updated, next_state}
            end

          %PlacementTombstone{} = tombstone ->
            with {:ok, updated} <-
                   PlacementTombstone.command_ack(
                     tombstone,
                     node_id,
                     generation,
                     command_id,
                     idempotency_key,
                     status,
                     detail_code,
                     now_ms
                   ),
                 {:ok, next_state} <- persist_tombstone(state, updated) do
              {:ok, updated, next_state}
            end
        end

      case result do
        {:ok, value, next_state} -> {:reply, {:ok, value}, next_state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:placement_update, node_id, generation, placement_id, command_id, next_state,
         detail_code, now_ms},
        _from,
        state
      ) do
    with {:ok, record} <- fetch_record(state, placement_id) do
      result =
        case record do
          %Placement{} = placement ->
            with {:ok, placement} <-
                   placement_update_identity(placement, node_id, generation, command_id, now_ms),
                 {:ok, updated} <- Placement.advance(placement, next_state, detail_code, now_ms),
                 {:ok, persisted_state} <- persist_placement(state, updated) do
              {:ok, updated, persisted_state}
            end

          %PlacementTombstone{} = tombstone ->
            with {:ok, updated} <-
                   PlacementTombstone.placement_update(
                     tombstone,
                     node_id,
                     generation,
                     command_id,
                     next_state,
                     detail_code,
                     now_ms
                   ),
                 {:ok, persisted_state} <- persist_tombstone(state, updated) do
              {:ok, updated, persisted_state}
            end
        end

      case result do
        {:ok, value, next_state} -> {:reply, {:ok, value}, next_state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fail_placement, placement_id, detail_code, now_ms}, _from, state) do
    case fetch_record(state, placement_id) do
      {:ok, %Placement{} = placement} ->
        with {:ok, updated} <- Placement.advance(placement, :failed, detail_code, now_ms),
             {:ok, next_state} <- persist_placement(state, updated) do
          {:reply, {:ok, updated}, next_state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:ok, %PlacementTombstone{}} ->
        {:reply, {:error, :placement_terminal}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, placement_id}, _from, state) do
    {:reply, fetch_record(state, placement_id), state}
  end

  def handle_call(:snapshot, _from, state) do
    placements = state.placements |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, placements, state}
  end

  def handle_call(:tombstone_snapshot, _from, state) do
    tombstones = state.tombstones |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, tombstones, state}
  end

  defp reconcile_begin(state, %Placement{} = incoming) do
    existing = Map.get(state.placements, incoming.id)
    tombstone = Map.get(state.tombstones, incoming.id)
    command_owner = Map.get(state.commands, incoming.command_id)

    cond do
      match?(%PlacementTombstone{}, tombstone) ->
        {:error, :placement_terminal}

      is_nil(existing) and is_nil(command_owner) and
          PlacementStateStore.capacity_available?(
            state.placements,
            state.tombstones,
            state.record_capacity
          ) ->
        {:ok, incoming}

      is_nil(existing) and is_nil(command_owner) ->
        {:error, :placement_state_capacity}

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

  defp fetch_record(state, placement_id) do
    case Map.fetch(state.placements, placement_id) do
      {:ok, placement} ->
        {:ok, placement}

      :error ->
        case Map.fetch(state.tombstones, placement_id) do
          {:ok, tombstone} -> {:ok, tombstone}
          :error -> {:error, :unknown_placement}
        end
    end
  end

  defp persist_placement(state, %Placement{} = placement) do
    next_state =
      if Placement.terminal?(placement) do
        {:ok, tombstone} = PlacementTombstone.from_placement(placement)
        put_tombstone(state, tombstone)
      else
        put_placement(state, placement)
      end

    record =
      Map.get(next_state.placements, placement.id) ||
        Map.fetch!(next_state.tombstones, placement.id)

    case append_record(next_state, record) do
      :ok -> {:ok, maybe_checkpoint(next_state)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_tombstone(state, %PlacementTombstone{} = tombstone) do
    next_state = put_tombstone(state, tombstone)

    case append_record(next_state, tombstone) do
      :ok -> {:ok, maybe_checkpoint(next_state)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_record(state, record) do
    PlacementStateStore.append(state.state_path, {:put, record})
  end

  defp checkpoint_state(state) do
    PlacementStateStore.checkpoint(state.state_path, state.placements, state.tombstones)
  end

  defp maybe_checkpoint(state) do
    if PlacementStateStore.journal_size(state.state_path) >= state.checkpoint_bytes do
      # The journal record is already durable. A checkpoint failure must not turn
      # an acknowledged mutation into an ambiguous error; recovery will replay it.
      _ = checkpoint_state(state)
    end

    state
  end

  defp rebuild_commands(state) do
    commands =
      Map.new(
        Map.values(state.placements) ++ Map.values(state.tombstones),
        &{&1.command_id, &1.id}
      )

    %{state | commands: commands}
  end

  defp put_placement(state, %Placement{} = placement) do
    %{
      state
      | placements: Map.put(state.placements, placement.id, placement),
        commands: Map.put(state.commands, placement.command_id, placement.id)
    }
  end

  defp put_tombstone(state, %PlacementTombstone{} = tombstone) do
    %{
      state
      | placements: Map.delete(state.placements, tombstone.id),
        tombstones: Map.put(state.tombstones, tombstone.id, tombstone),
        commands: Map.put(state.commands, tombstone.command_id, tombstone.id)
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
