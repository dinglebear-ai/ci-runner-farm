defmodule CrfController.PlacementCoordinator do
  use GenServer

  alias CrfController.{
    CapacityView,
    Node,
    NodeCommand,
    NodeMailbox,
    NodeRegistry,
    Offer,
    OfferLedger,
    Placement,
    PlacementLedger,
    PlacementTombstone,
    Resources,
    Secret
  }

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def dispatch(server \\ __MODULE__, attrs, opts \\ []) do
    GenServer.call(
      server,
      {:dispatch, attrs, Keyword.get(opts, :now_ms, now_ms()),
       Keyword.get(opts, :now_unix_ms, now_unix_ms())}
    )
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       node_registry: Keyword.get(opts, :node_registry, NodeRegistry),
       placement_ledger: Keyword.get(opts, :placement_ledger, PlacementLedger),
       offer_ledger: Keyword.get(opts, :offer_ledger, OfferLedger),
       node_mailbox: Keyword.get(opts, :node_mailbox, NodeMailbox)
     }}
  end

  @impl true
  def handle_call({:dispatch, attrs, now_ms, now_unix_ms}, _from, state) do
    reply = dispatch_now(attrs, now_ms, now_unix_ms, state)
    {:reply, reply, state}
  end

  defp dispatch_now(attrs, now_ms, now_unix_ms, state) when is_map(attrs) do
    with {:ok, node_id} <- fetch_string(attrs, :node_id, :invalid_node_id),
         {:ok, %Node{} = node} <- find_node(state.node_registry, node_id),
         :ok <- node_eligible(node, attrs),
         {:ok, placement} <- candidate_placement(attrs, node, now_ms),
         {:ok, command} <- candidate_command(attrs, placement),
         :ok <- command_current(command, now_unix_ms),
         result <- existing_or_new(placement, command, node, attrs, now_ms, now_unix_ms, state) do
      result
    end
  end

  defp dispatch_now(_, _now_ms, _now_unix_ms, _state), do: {:error, :invalid_dispatch}

  defp existing_or_new(placement, command, node, attrs, now_ms, now_unix_ms, state) do
    case PlacementLedger.get(state.placement_ledger, placement.id) do
      {:ok, %PlacementTombstone{}} ->
        {:error, :placement_terminal}

      {:ok, %Placement{} = existing} ->
        cond do
          not Placement.same_command?(existing, placement) ->
            {:error, :placement_conflict}

          true ->
            with :ok <- ensure_offer_consumed(attrs, existing, node, state) do
              if existing.state == :commanded do
                case NodeMailbox.enqueue(state.node_mailbox, command, now_unix_ms: now_unix_ms) do
                  {:ok, ^command} -> {:ok, %{placement: existing, command: command, replay: true}}
                  {:error, reason} -> {:error, reason}
                end
              else
                {:ok, %{placement: existing, command: command, replay: true}}
              end
            end
        end

      {:error, :unknown_placement} ->
        dispatch_new(placement, command, node, attrs, now_ms, now_unix_ms, state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_new(placement, command, node, attrs, now_ms, now_unix_ms, state) do
    placements = PlacementLedger.snapshot(state.placement_ledger)

    with {:ok, offer_id, work_handle, offers} <- offer_context(attrs, placement, node, state),
         {:ok, effective_available} <-
           CapacityView.effective_available(node, placements, offers, offer_id),
         true <- Resources.fits?(effective_available, placement.resources),
         {:ok, stored} <-
           PlacementLedger.begin_placement(state.placement_ledger, placement_attrs(placement),
             now_ms: now_ms
           ) do
      case consume_offer(offer_id, work_handle, state) do
        :ok ->
          enqueue_command(stored, command, now_ms, now_unix_ms, state)

        {:error, reason} ->
          _ =
            PlacementLedger.fail_placement(
              state.placement_ledger,
              placement.id,
              "offer_consume_failed",
              now_ms: now_ms
            )

          {:error, reason}
      end
    else
      false -> {:error, :insufficient_node_capacity}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_command(stored, command, now_ms, now_unix_ms, state) do
    case NodeMailbox.enqueue(state.node_mailbox, command, now_unix_ms: now_unix_ms) do
      {:ok, ^command} ->
        {:ok, %{placement: stored, command: command, replay: false}}

      {:error, reason} ->
        _ =
          PlacementLedger.fail_placement(
            state.placement_ledger,
            stored.id,
            "mailbox_enqueue_failed",
            now_ms: now_ms
          )

        {:error, reason}
    end
  end

  defp offer_context(attrs, placement, node, state) do
    offers = OfferLedger.snapshot(state.offer_ledger)

    case Map.get(attrs, :offer_id) do
      nil ->
        {:ok, nil, nil, offers}

      offer_id when is_binary(offer_id) ->
        with {:ok, work_handle} <-
               positive_integer(Map.get(attrs, :work_handle), :invalid_work_handle),
             {:ok, %Offer{} = offer} <- OfferLedger.get(state.offer_ledger, offer_id),
             :ok <- validate_offer(offer, placement, node, work_handle) do
          {:ok, offer_id, work_handle, offers}
        end

      _ ->
        {:error, :invalid_offer_id}
    end
  end

  defp ensure_offer_consumed(attrs, placement, node, state) do
    case Map.get(attrs, :offer_id) do
      nil ->
        :ok

      offer_id when is_binary(offer_id) ->
        with {:ok, work_handle} <-
               positive_integer(Map.get(attrs, :work_handle), :invalid_work_handle) do
          case OfferLedger.get(state.offer_ledger, offer_id) do
            {:error, :unknown_offer} ->
              :ok

            {:ok, %Offer{} = offer} ->
              with :ok <- validate_offer(offer, placement, node, work_handle),
                   {:ok, _offer} <- OfferLedger.consume(state.offer_ledger, offer_id, work_handle) do
                :ok
              end

            {:error, reason} ->
              {:error, reason}
          end
        end

      _ ->
        {:error, :invalid_offer_id}
    end
  end

  defp consume_offer(nil, nil, _state), do: :ok

  defp consume_offer(offer_id, work_handle, state) do
    case OfferLedger.consume(state.offer_ledger, offer_id, work_handle) do
      {:ok, _offer} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_offer(%Offer{} = offer, %Placement{} = placement, %Node{} = node, work_handle) do
    cond do
      offer.state != :assigned -> {:error, :offer_not_assigned}
      offer.work_handle != work_handle -> {:error, :offer_assignment_conflict}
      offer.pool_id != placement.pool_id -> {:error, :offer_pool_mismatch}
      offer.node_id != node.id -> {:error, :offer_node_mismatch}
      offer.node_generation != node.generation -> {:error, :offer_generation_mismatch}
      offer.resources != placement.resources -> {:error, :offer_resource_mismatch}
      true -> :ok
    end
  end

  defp candidate_placement(attrs, node, now_ms) do
    Placement.new(
      %{
        id: Map.get(attrs, :placement_id),
        command_id: Map.get(attrs, :command_id),
        idempotency_key: Map.get(attrs, :idempotency_key),
        node_id: node.id,
        node_generation: node.generation,
        work_id: Map.get(attrs, :work_id),
        pool_id: Map.get(attrs, :pool_id),
        resources: Map.get(attrs, :resources)
      },
      now_ms
    )
  end

  defp candidate_command(attrs, placement) do
    with {:ok, runner_name} <- fetch_string(attrs, :runner_name, :invalid_runner_name),
         {:ok, backend} <- fetch_backend(attrs),
         %Secret{} = jit_config <- Map.get(attrs, :jit_config),
         {:ok, issued_at} <-
           positive_integer(Map.get(attrs, :issued_at_unix_ms), :invalid_timestamp),
         {:ok, expires_at} <-
           positive_integer(Map.get(attrs, :expires_at_unix_ms), :invalid_timestamp) do
      NodeCommand.start_placement(
        placement,
        runner_name,
        backend,
        jit_config,
        issued_at,
        expires_at
      )
    else
      nil -> {:error, :invalid_jit_config}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_jit_config}
    end
  end

  defp command_current(command, now_unix_ms) do
    NodeCommand.validate(command, now_unix_ms)
  end

  defp node_eligible(%Node{draining: true}, _attrs), do: {:error, :node_draining}

  defp node_eligible(%Node{} = node, attrs) do
    with {:ok, backend} <- fetch_backend(attrs),
         true <- MapSet.member?(node.execution_backends, backend) do
      :ok
    else
      false -> {:error, :execution_backend_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_node(registry, node_id) do
    case Enum.find(NodeRegistry.snapshot(registry), &(&1.id == node_id)) do
      %Node{} = node -> {:ok, node}
      nil -> {:error, :unknown_node}
    end
  end

  defp placement_attrs(%Placement{} = placement) do
    %{
      id: placement.id,
      command_id: placement.command_id,
      idempotency_key: placement.idempotency_key,
      node_id: placement.node_id,
      node_generation: placement.node_generation,
      work_id: placement.work_id,
      pool_id: placement.pool_id,
      resources: placement.resources
    }
  end

  defp fetch_backend(attrs) do
    case Map.get(attrs, :execution_backend) do
      backend when backend in [:container, :native_process, :virtual_machine] -> {:ok, backend}
      _ -> {:error, :invalid_execution_backend}
    end
  end

  defp fetch_string(attrs, key, error) do
    case Map.get(attrs, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp positive_integer(value, _error) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_, error), do: {:error, error}

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp now_unix_ms, do: System.system_time(:millisecond)
end
