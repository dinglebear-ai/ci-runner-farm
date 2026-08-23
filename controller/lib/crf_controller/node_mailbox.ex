defmodule CrfController.NodeMailbox do
  use GenServer

  alias CrfController.NodeCommand

  @default_capacity 4096
  @max_capacity 65_536

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def enqueue(server \\ __MODULE__, %NodeCommand{} = command, opts \\ []) do
    GenServer.call(server, {:enqueue, command, Keyword.get(opts, :now_unix_ms, now_unix_ms())})
  end

  def next_for(server \\ __MODULE__, node_id, generation, opts \\ []) do
    GenServer.call(
      server,
      {:next_for, node_id, generation, Keyword.get(opts, :now_unix_ms, now_unix_ms())}
    )
  end

  def prepare_ack(
        server \\ __MODULE__,
        node_id,
        generation,
        command_id,
        idempotency_key,
        status
      ) do
    GenServer.call(
      server,
      {:prepare_ack, node_id, generation, command_id, idempotency_key, status}
    )
  end

  def commit_ack(server \\ __MODULE__, command_id, idempotency_key) do
    GenServer.call(server, {:commit_ack, command_id, idempotency_key})
  end

  def ack(
        server \\ __MODULE__,
        node_id,
        generation,
        command_id,
        idempotency_key,
        status
      ) do
    with {:ok, command} <-
           prepare_ack(server, node_id, generation, command_id, idempotency_key, status),
         {:ok, ^command} <- commit_ack(server, command_id, idempotency_key) do
      {:ok, command}
    end
  end

  def get(command_id), do: get(__MODULE__, command_id)
  def get(server, command_id), do: GenServer.call(server, {:get, command_id})

  def discard(command_id), do: discard(__MODULE__, command_id)
  def discard(server, command_id), do: GenServer.call(server, {:discard, command_id})

  def size(server \\ __MODULE__), do: GenServer.call(server, :size)

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    if is_integer(capacity) and capacity in 1..@max_capacity do
      {:ok,
       %{capacity: capacity, node_queues: %{}, queue_counts: %{}, queue_stale: %{}, commands: %{}}}
    else
      {:stop, :invalid_mailbox_capacity}
    end
  end

  @impl true
  def handle_call({:enqueue, command, now_unix_ms}, _from, state) do
    with :ok <- NodeCommand.validate(command, now_unix_ms) do
      case Map.get(state.commands, command.command_id) do
        nil when map_size(state.commands) < state.capacity ->
          node_key = {command.node_id, command.node_generation}

          Process.send_after(
            self(),
            {:expire_command, command.command_id, command.expires_at_unix_ms},
            max(command.expires_at_unix_ms - now_unix_ms + 1, 0)
          )

          state = %{
            state
            | node_queues:
                Map.update(
                  state.node_queues,
                  node_key,
                  :queue.from_list([command.command_id]),
                  &:queue.in(command.command_id, &1)
                ),
              queue_counts: Map.update(state.queue_counts, node_key, 1, &(&1 + 1)),
              commands: Map.put(state.commands, command.command_id, command)
          }

          {:reply, {:ok, command}, state}

        nil ->
          {:reply, {:error, :mailbox_full}, state}

        %NodeCommand{} = existing when existing == command ->
          {:reply, {:ok, existing}, state}

        %NodeCommand{} ->
          {:reply, {:error, :command_id_conflict}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:next_for, node_id, generation, now_unix_ms}, _from, state) do
    {command, state} = next_matching(state, node_id, generation, now_unix_ms)
    {:reply, {:ok, command}, state}
  end

  def handle_call(
        {:prepare_ack, node_id, generation, command_id, idempotency_key, status},
        _from,
        state
      ) do
    case Map.get(state.commands, command_id) do
      %NodeCommand{} = command ->
        with :ok <- command_identity(command, node_id, generation, idempotency_key),
             true <- status in [:accepted, :duplicate, :rejected] do
          {:reply, {:ok, command}, state}
        else
          false -> {:reply, {:error, :invalid_ack_status}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      nil ->
        {:reply, {:error, :unknown_command}, state}
    end
  end

  def handle_call({:commit_ack, command_id, idempotency_key}, _from, state) do
    case Map.get(state.commands, command_id) do
      %NodeCommand{idempotency_key: ^idempotency_key} = command ->
        {:reply, {:ok, command}, drop_command(state, command_id)}

      %NodeCommand{} ->
        {:reply, {:error, :idempotency_key_mismatch}, state}

      nil ->
        {:reply, {:error, :unknown_command}, state}
    end
  end

  def handle_call({:get, command_id}, _from, state) do
    case Map.fetch(state.commands, command_id) do
      {:ok, command} -> {:reply, {:ok, command}, state}
      :error -> {:reply, {:error, :unknown_command}, state}
    end
  end

  def handle_call({:discard, command_id}, _from, state) do
    case Map.get(state.commands, command_id) do
      %NodeCommand{} = command -> {:reply, {:ok, command}, drop_command(state, command_id)}
      nil -> {:reply, {:error, :unknown_command}, state}
    end
  end

  def handle_call(:size, _from, state), do: {:reply, map_size(state.commands), state}

  @impl true
  def handle_info({:expire_command, command_id, expires_at}, state) do
    state =
      case Map.get(state.commands, command_id) do
        %NodeCommand{expires_at_unix_ms: ^expires_at} -> drop_command(state, command_id)
        _ -> state
      end

    {:noreply, state}
  end

  defp next_matching(state, node_id, generation, now_unix_ms) do
    key = {node_id, generation}
    queue = Map.get(state.node_queues, key, :queue.new())
    next_in_node_queue(state, key, queue, now_unix_ms)
  end

  defp next_in_node_queue(state, key, queue, now_unix_ms) do
    case :queue.out(queue) do
      {{:value, command_id}, rest} ->
        case Map.get(state.commands, command_id) do
          nil ->
            next_in_node_queue(state, key, rest, now_unix_ms)

          %NodeCommand{expires_at_unix_ms: expires_at} when now_unix_ms > expires_at ->
            state
            |> drop_command(command_id)
            |> next_matching(elem(key, 0), elem(key, 1), now_unix_ms)

          %NodeCommand{} = command ->
            {command, put_node_queue(state, key, queue)}
        end

      {:empty, _queue} ->
        {nil, %{state | node_queues: Map.delete(state.node_queues, key)}}
    end
  end

  defp drop_command(state, command_id) do
    case Map.get(state.commands, command_id) do
      nil ->
        state

      %NodeCommand{} = command ->
        key = {command.node_id, command.node_generation}
        commands = Map.delete(state.commands, command_id)
        remaining = Map.fetch!(state.queue_counts, key) - 1

        if remaining == 0 do
          %{
            state
            | commands: commands,
              node_queues: Map.delete(state.node_queues, key),
              queue_counts: Map.delete(state.queue_counts, key),
              queue_stale: Map.delete(state.queue_stale, key)
          }
        else
          stale = Map.get(state.queue_stale, key, 0) + 1

          state = %{
            state
            | commands: commands,
              queue_counts: Map.put(state.queue_counts, key, remaining)
          }

          if stale >= max(remaining, 64) do
            queue =
              :queue.filter(
                &Map.has_key?(commands, &1),
                Map.fetch!(state.node_queues, key)
              )

            %{
              state
              | node_queues: Map.put(state.node_queues, key, queue),
                queue_stale: Map.delete(state.queue_stale, key)
            }
          else
            %{state | queue_stale: Map.put(state.queue_stale, key, stale)}
          end
        end
    end
  end

  defp put_node_queue(state, key, queue),
    do: %{state | node_queues: Map.put(state.node_queues, key, queue)}

  defp command_identity(command, node_id, generation, idempotency_key) do
    cond do
      command.node_id != node_id -> {:error, :node_identity_mismatch}
      command.node_generation != generation -> {:error, :generation_mismatch}
      command.idempotency_key != idempotency_key -> {:error, :idempotency_key_mismatch}
      true -> :ok
    end
  end

  defp now_unix_ms, do: System.system_time(:millisecond)
end
