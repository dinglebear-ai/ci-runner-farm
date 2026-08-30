defmodule CrfController.Ingress do
  use GenServer

  alias CrfController.{
    NodeCommand,
    NodeMailbox,
    NodeRegistry,
    OperatorProjection,
    PeerIdentity,
    PlacementLedger,
    Wire
  }

  @default_ledger_capacity 4096
  @max_ledger_capacity 65_536

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def ingest(server \\ __MODULE__, %PeerIdentity{} = peer, binary, opts \\ []) do
    GenServer.call(
      server,
      {:ingest, peer, binary, Keyword.get(opts, :now_ms, now_ms()),
       Keyword.get(opts, :now_unix_ms, now_unix_ms())}
    )
  end

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :ledger_capacity, @default_ledger_capacity)

    if not is_integer(capacity) or capacity < 1 or capacity > @max_ledger_capacity do
      {:stop, :invalid_ledger_capacity}
    else
      {:ok,
       %{
         node_registry: Keyword.get(opts, :node_registry, NodeRegistry),
         placement_ledger: Keyword.get(opts, :placement_ledger, PlacementLedger),
         node_mailbox: Keyword.get(opts, :node_mailbox, NodeMailbox),
         capacity: capacity,
         order: :queue.new(),
         messages: %{},
         controller_instance_id: Keyword.get(opts, :controller_instance_id, "controller")
       }}
    end
  end

  @impl true
  def handle_call({:ingest, peer, binary, now_ms, now_unix_ms}, _from, state) do
    case Wire.decode_node_envelope(binary, peer) do
      {:ok, envelope} -> handle_envelope(envelope, binary, now_ms, now_unix_ms, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_envelope(envelope, binary, now_ms, now_unix_ms, state) do
    key = {envelope.node_id, envelope.node_generation, envelope.message_id}
    fingerprint = :crypto.hash(:sha256, binary)

    case Map.get(state.messages, key) do
      %{fingerprint: ^fingerprint, response: response} ->
        {:reply, {:ok, response}, state}

      %{fingerprint: _different} ->
        {:reply,
         response(envelope.message_id, :rejected, :message_id_conflict, nil, nil, now_unix_ms),
         state}

      nil ->
        outcome = route(envelope, now_ms, state)
        command = pending_command(outcome, envelope, state, now_unix_ms)

        projection = operator_projection(outcome, envelope, state, now_unix_ms)

        case encode_outcome(envelope.message_id, outcome, command, projection, now_unix_ms) do
          {:ok, response} ->
            state = remember(state, key, fingerprint, response)
            {:reply, {:ok, response}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  defp route(%{payload: {:register, node, _agent_version}}, now_ms, state) do
    attrs = %{
      id: node.id,
      generation: node.generation,
      os: node.os,
      arch: node.arch,
      execution_backends: node.execution_backends,
      capabilities: node.capabilities,
      total: node.total,
      available: node.available,
      draining: false
    }

    NodeRegistry.register(state.node_registry, attrs, now_ms: now_ms)
    |> normalize()
  end

  defp route(
         %{
           node_id: node_id,
           node_generation: generation,
           payload: {:heartbeat, available, active_placements}
         },
         now_ms,
         state
       ) do
    normalize(
      NodeRegistry.heartbeat(state.node_registry, node_id, generation, available,
        active_placements: active_placements,
        now_ms: now_ms
      )
    )
  end

  defp route(
         %{
           node_id: node_id,
           node_generation: generation,
           payload: {:command_ack, command_id, idempotency_key, status, detail_code}
         },
         now_ms,
         state
       ) do
    with :ok <- registered_generation(state.node_registry, node_id, generation),
         {:ok, command} <-
           NodeMailbox.prepare_ack(
             state.node_mailbox,
             node_id,
             generation,
             command_id,
             idempotency_key,
             status
           ),
         :accepted <-
           apply_command_ack(command, node_id, generation, status, detail_code, now_ms, state),
         {:ok, ^command} <-
           NodeMailbox.commit_ack(state.node_mailbox, command_id, idempotency_key) do
      :accepted
    else
      {:rejected, reason} -> {:rejected, reason}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp route(
         %{
           node_id: node_id,
           node_generation: generation,
           payload: {:placement_update, placement_id, command_id, placement_state, detail_code}
         },
         now_ms,
         state
       ) do
    with :ok <- registered_generation(state.node_registry, node_id, generation) do
      normalize(
        PlacementLedger.placement_update(
          state.placement_ledger,
          node_id,
          generation,
          placement_id,
          command_id,
          placement_state,
          detail_code,
          now_ms: now_ms
        )
      )
    else
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp apply_command_ack(
         %NodeCommand{
           command_id: command_id,
           idempotency_key: idempotency_key,
           payload:
             {:start_placement, _placement_id, _work_id, _pool_id, _runner_name, _resources,
              _backend, _jit_config}
         },
         node_id,
         generation,
         status,
         detail_code,
         now_ms,
         state
       ) do
    normalize(
      PlacementLedger.command_ack(
        state.placement_ledger,
        node_id,
        generation,
        command_id,
        idempotency_key,
        status,
        detail_code,
        now_ms: now_ms
      )
    )
  end

  defp apply_command_ack(
         %NodeCommand{},
         _node_id,
         _generation,
         _status,
         _detail_code,
         _now_ms,
         _state
       ),
       do: :accepted

  defp normalize({:ok, _value}), do: :accepted
  defp normalize({:error, reason}) when is_atom(reason), do: {:rejected, reason}

  defp pending_command(:accepted, envelope, state, now_unix_ms) do
    case NodeMailbox.next_for(
           state.node_mailbox,
           envelope.node_id,
           envelope.node_generation,
           now_unix_ms: now_unix_ms
         ) do
      {:ok, command} -> command
      {:error, _reason} -> nil
    end
  end

  defp pending_command({:rejected, _reason}, _envelope, _state, _now_unix_ms), do: nil

  defp encode_outcome(message_id, :accepted, command, projection, now_unix_ms),
    do: response(message_id, :accepted, nil, command, projection, now_unix_ms)

  defp encode_outcome(message_id, {:rejected, reason}, _command, _projection, now_unix_ms),
    do: response(message_id, :rejected, reason, nil, nil, now_unix_ms)

  defp response(message_id, status, code, command, projection, now_unix_ms) do
    Wire.encode_response(message_id, status, code, command, projection, now_unix_ms)
  end

  defp operator_projection(:accepted, envelope, state, now_unix_ms) do
    with {:ok, node} <- NodeRegistry.get(state.node_registry, envelope.node_id),
         true <- MapSet.member?(node.capabilities, "operator-projection-v1") do
      OperatorProjection.build(state.controller_instance_id, now_unix_ms)
    else
      _ -> nil
    end
  end

  defp operator_projection(_, _, _, _), do: nil

  defp remember(state, key, fingerprint, response) do
    {order, messages} = evict_if_full(state.order, state.messages, state.capacity)

    %{
      state
      | order: :queue.in(key, order),
        messages: Map.put(messages, key, %{fingerprint: fingerprint, response: response})
    }
  end

  defp evict_if_full(order, messages, capacity) when map_size(messages) < capacity,
    do: {order, messages}

  defp evict_if_full(order, messages, _capacity) do
    case :queue.out(order) do
      {{:value, oldest}, rest} -> {rest, Map.delete(messages, oldest)}
      {:empty, rest} -> {rest, %{}}
    end
  end

  defp registered_generation(node_registry, node_id, generation) do
    case NodeRegistry.get(node_registry, node_id) do
      {:ok, %{generation: ^generation}} -> :ok
      {:ok, _node} -> {:error, :generation_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp now_unix_ms, do: System.system_time(:millisecond)
end
