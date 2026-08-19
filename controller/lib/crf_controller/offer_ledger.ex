defmodule CrfController.OfferLedger do
  use GenServer

  alias CrfController.Offer

  @default_capacity 4096
  @max_capacity 65_536

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def reserve(server \\ __MODULE__, attrs, opts \\ []) do
    GenServer.call(server, {:reserve, attrs, Keyword.get(opts, :now_ms, now_ms())})
  end

  def assign_next(server \\ __MODULE__, pool_id, work_handle, opts \\ []) do
    GenServer.call(
      server,
      {:assign_next, pool_id, work_handle, Keyword.get(opts, :now_ms, now_ms())}
    )
  end

  def reserve_assigned(server \\ __MODULE__, attrs, work_handle, opts \\ []) do
    GenServer.call(
      server,
      {:reserve_assigned, attrs, work_handle, Keyword.get(opts, :now_ms, now_ms())}
    )
  end

  def consume(server \\ __MODULE__, offer_id, work_handle) do
    GenServer.call(server, {:consume, offer_id, work_handle})
  end

  def release(server \\ __MODULE__, offer_id), do: GenServer.call(server, {:release, offer_id})
  def get(server \\ __MODULE__, offer_id), do: GenServer.call(server, {:get, offer_id})

  def find_by_handle(server \\ __MODULE__, pool_id, work_handle) do
    GenServer.call(server, {:find_by_handle, pool_id, work_handle})
  end

  def snapshot(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:snapshot, Keyword.get(opts, :now_ms, now_ms())})
  end

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    if is_integer(capacity) and capacity in 1..@max_capacity do
      {:ok, %{capacity: capacity, offers: %{}}}
    else
      {:stop, :invalid_offer_capacity}
    end
  end

  @impl true
  def handle_call({:reserve, attrs, now_ms}, _from, state) do
    state = prune(state, now_ms)

    with {:ok, incoming} <- Offer.new(attrs, now_ms) do
      case Map.get(state.offers, incoming.id) do
        nil when map_size(state.offers) < state.capacity ->
          state = put_offer(state, incoming)
          {:reply, {:ok, incoming}, state}

        nil ->
          {:reply, {:error, :offer_ledger_full}, state}

        %Offer{} = existing ->
          if Offer.same_reservation?(existing, incoming),
            do: {:reply, {:ok, existing}, state},
            else: {:reply, {:error, :offer_conflict}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reserve_assigned, attrs, work_handle, now_ms}, _from, state) do
    state = prune(state, now_ms)

    with {:ok, incoming} <- Offer.new(attrs, now_ms),
         {:ok, incoming} <- Offer.assign(incoming, work_handle) do
      case Map.get(state.offers, incoming.id) do
        %Offer{} = existing when existing == incoming ->
          {:reply, {:ok, existing}, state}

        %Offer{} ->
          {:reply, {:error, :offer_conflict}, state}

        nil ->
          with :ok <- handle_available(state, incoming.pool_id, work_handle),
               true <- map_size(state.offers) < state.capacity do
            {:reply, {:ok, incoming}, put_offer(state, incoming)}
          else
            false -> {:reply, {:error, :offer_ledger_full}, state}
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:assign_next, pool_id, work_handle, now_ms}, _from, state) do
    state = prune(state, now_ms)

    case find_handle(state, pool_id, work_handle) do
      %Offer{} = existing ->
        {:reply, {:ok, existing}, state}

      nil ->
        offer =
          state.offers
          |> Map.values()
          |> Enum.filter(&(&1.pool_id == pool_id and &1.state == :offered))
          |> Enum.min_by(&{&1.created_at_ms, &1.id}, fn -> nil end)

        case offer do
          nil ->
            {:reply, {:error, :no_offer_available}, state}

          %Offer{} ->
            case Offer.assign(offer, work_handle) do
              {:ok, assigned} -> {:reply, {:ok, assigned}, put_offer(state, assigned)}
              {:error, reason} -> {:reply, {:error, reason}, state}
            end
        end
    end
  end

  def handle_call({:consume, offer_id, work_handle}, _from, state) do
    case Map.get(state.offers, offer_id) do
      %Offer{state: :assigned, work_handle: ^work_handle} = offer ->
        {:reply, {:ok, offer}, %{state | offers: Map.delete(state.offers, offer_id)}}

      %Offer{} ->
        {:reply, {:error, :offer_assignment_conflict}, state}

      nil ->
        {:reply, {:error, :unknown_offer}, state}
    end
  end

  def handle_call({:release, offer_id}, _from, state) do
    case Map.pop(state.offers, offer_id) do
      {nil, _} -> {:reply, {:error, :unknown_offer}, state}
      {offer, offers} -> {:reply, {:ok, offer}, %{state | offers: offers}}
    end
  end

  def handle_call({:get, offer_id}, _from, state) do
    case Map.fetch(state.offers, offer_id) do
      {:ok, offer} -> {:reply, {:ok, offer}, state}
      :error -> {:reply, {:error, :unknown_offer}, state}
    end
  end

  def handle_call({:find_by_handle, pool_id, work_handle}, _from, state) do
    case find_handle(state, pool_id, work_handle) do
      nil -> {:reply, {:error, :unknown_offer}, state}
      offer -> {:reply, {:ok, offer}, state}
    end
  end

  def handle_call({:snapshot, now_ms}, _from, state) do
    state = prune(state, now_ms)
    offers = state.offers |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, offers, state}
  end

  defp handle_available(state, pool_id, work_handle) do
    if is_nil(find_handle(state, pool_id, work_handle)),
      do: :ok,
      else: {:error, :work_handle_already_offered}
  end

  defp find_handle(state, pool_id, work_handle) do
    Enum.find(Map.values(state.offers), fn offer ->
      offer.pool_id == pool_id and offer.work_handle == work_handle
    end)
  end

  defp prune(state, now_ms) do
    offers =
      state.offers
      |> Enum.reject(fn {_id, offer} -> Offer.expired?(offer, now_ms) end)
      |> Map.new()

    %{state | offers: offers}
  end

  defp put_offer(state, %Offer{} = offer),
    do: %{state | offers: Map.put(state.offers, offer.id, offer)}

  defp now_ms, do: System.monotonic_time(:millisecond)
end
