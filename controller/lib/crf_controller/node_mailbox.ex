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
      {:ok, %{capacity: capacity, order: :queue.new(), commands: %{}}}
    else
      {:stop, :invalid_mailbox_capacity}
    end
  end

  @impl true
  def handle_call({:enqueue, command, now_unix_ms}, _from, state) do
    with :ok <- NodeCommand.validate(command, now_unix_ms) do
      case Map.get(state.commands, command.command_id) do
        nil when map_size(state.commands) < state.capacity ->
          state = %{
            state
            | order: :queue.in(command.command_id, state.order),
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

  defp next_matching(state, node_id, generation, now_unix_ms) do
    state = purge_expired(state, now_unix_ms)

    command =
      state.order
      |> :queue.to_list()
      |> Enum.find_value(fn command_id ->
        case Map.get(state.commands, command_id) do
          %NodeCommand{node_id: ^node_id, node_generation: ^generation} = command -> command
          _ -> nil
        end
      end)

    {command, state}
  end

  defp purge_expired(state, now_unix_ms) do
    expired =
      state.commands
      |> Enum.reduce(MapSet.new(), fn
        {command_id, %NodeCommand{expires_at_unix_ms: expires_at_unix_ms}}, acc
        when now_unix_ms > expires_at_unix_ms ->
          MapSet.put(acc, command_id)

        _, acc ->
          acc
      end)

    if MapSet.size(expired) == 0 do
      state
    else
      order =
        state.order
        |> :queue.to_list()
        |> Enum.reject(&MapSet.member?(expired, &1))
        |> :queue.from_list()

      %{state | order: order, commands: Map.drop(state.commands, MapSet.to_list(expired))}
    end
  end

  defp drop_command(state, command_id) do
    order =
      state.order
      |> :queue.to_list()
      |> Enum.reject(&(&1 == command_id))
      |> :queue.from_list()

    %{state | order: order, commands: Map.delete(state.commands, command_id)}
  end

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
