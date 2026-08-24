defmodule CrfController.ScaleSetClient do
  use GenServer

  require Logger

  alias CrfController.{
    Identifier,
    ScaleSetEligibility,
    ScaleSetSequence,
    ScaleSetTransport,
    ScaleSetWire
  }

  @default_timeout_ms 30_000
  @call_timeout_ms 125_000
  # Reasserting persisted eligibility is a slow-moving safety net, not a fast
  # control loop (contrast DemandCoordinator's 100ms-60s reconcile_tick) — its
  # job is to catch drift after a restart or an out-of-band RPC, not to react
  # to live traffic.
  @default_reconcile_interval_ms 5 * 60 * 1_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def read_snapshot(server \\ __MODULE__),
    do: call(server, "read_snapshot", %{})

  def read_jit_state(server \\ __MODULE__),
    do: call(server, "read_jit_state", %{})

  def issue_jit(server \\ __MODULE__, pool_id, work_handle, runner_name, work_folder) do
    call(server, "issue_jit", %{
      "pool_id" => pool_id,
      "work_handle" => work_handle,
      "runner_name" => runner_name,
      "work_folder" => work_folder
    })
  end

  def retire_jit(server \\ __MODULE__, pool_id, work_handle) do
    call(server, "retire_jit", %{"pool_id" => pool_id, "work_handle" => work_handle})
  end

  def publish_capacity_leases(server \\ __MODULE__, leases) when is_map(leases) do
    call(server, "publish_capacity_leases", %{"leases" => leases})
  end

  def apply_sessions(server \\ __MODULE__, eligible) when is_boolean(eligible) do
    call(server, "apply_sessions", %{"eligible" => eligible})
  end

  def update_revisions(server \\ __MODULE__, config_revision, ownership_revision) do
    GenServer.call(server, {:update_revisions, config_revision, ownership_revision})
  end

  defp call(server, operation, payload) do
    GenServer.call(server, {:call, operation, payload}, @call_timeout_ms)
  end

  @impl true
  def init(opts) do
    socket_path = Keyword.get(opts, :socket_path)
    controller_instance_id = Keyword.get(opts, :controller_instance_id)

    sequence_path =
      Keyword.get_lazy(opts, :sequence_path, fn ->
        if is_binary(socket_path), do: socket_path <> ".sequence", else: nil
      end)

    eligibility_path =
      Keyword.get_lazy(opts, :eligibility_path, fn ->
        if is_binary(socket_path), do: socket_path <> ".eligibility", else: nil
      end)

    state = %{
      socket_path: socket_path,
      sequence_path: sequence_path,
      eligibility_path: eligibility_path,
      controller_instance_id: controller_instance_id,
      config_revision: Keyword.get(opts, :config_revision),
      ownership_revision: Keyword.get(opts, :ownership_revision),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      reconcile_interval_ms:
        Keyword.get(opts, :reconcile_interval_ms, @default_reconcile_interval_ms),
      sequence: 0,
      # Last eligibility value this client successfully commanded (or loaded
      # from a prior run's persisted intent). `nil` means "never explicitly
      # commanded" — reconciliation stays a no-op until a real caller sets it,
      # so a fresh deployment never gets an opinionated default injected.
      last_known_eligible: nil
    }

    with :ok <- validate_state(state),
         {:ok, sequence} <- ScaleSetSequence.load(sequence_path, controller_instance_id),
         {:ok, last_known_eligible} <-
           ScaleSetEligibility.load(eligibility_path, controller_instance_id) do
      state = %{state | sequence: sequence, last_known_eligible: last_known_eligible}
      {:ok, state, {:continue, :reassert_eligibility}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:reassert_eligibility, state) do
    {:noreply, reconcile_eligibility(state, schedule_next_tick: true)}
  end

  @impl true
  def handle_info(:reconcile_eligibility_tick, state) do
    {:noreply, reconcile_eligibility(state, schedule_next_tick: true)}
  end

  # Reassert the last commanded eligibility (a no-op if nothing has ever been
  # commanded). Failures are logged, not raised — the sidecar may simply not
  # be up yet right after a restart, and the periodic tick will retry.
  defp reconcile_eligibility(%{last_known_eligible: nil} = state, opts),
    do: maybe_schedule_tick(state, opts)

  defp reconcile_eligibility(%{last_known_eligible: eligible} = state, opts) do
    case perform_call(state, "apply_sessions", %{"eligible" => eligible}) do
      {{:ok, _result}, next_state} ->
        maybe_schedule_tick(next_state, opts)

      {{:error, reason}, next_state} ->
        Logger.warning(
          "scaleset eligibility reconciliation failed, will retry on next tick",
          reason: inspect(reason),
          eligible: eligible
        )

        maybe_schedule_tick(next_state, opts)
    end
  end

  defp maybe_schedule_tick(state, schedule_next_tick: true) do
    Process.send_after(self(), :reconcile_eligibility_tick, state.reconcile_interval_ms)
    state
  end

  defp maybe_schedule_tick(state, _opts), do: state

  @impl true
  def handle_call({:update_revisions, config_revision, ownership_revision}, _from, state) do
    updated = %{state | config_revision: config_revision, ownership_revision: ownership_revision}

    case validate_state(updated) do
      :ok -> {:reply, :ok, updated}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:call, operation, payload}, _from, state) do
    {result, next_state} = perform_call(state, operation, payload)
    {:reply, result, next_state}
  end

  # Shared by the public GenServer call path and the internal eligibility
  # reconciler, so both go through the same sequencing and persistence.
  defp perform_call(state, operation, payload) do
    case ScaleSetSequence.reserve(state.sequence_path, state.controller_instance_id) do
      {:ok, sequence} when sequence > state.sequence ->
        request_id = "scaleset-#{sequence}"

        result =
          with {:ok, request} <-
                 ScaleSetWire.encode_request(
                   request_id,
                   operation,
                   state.config_revision,
                   state.ownership_revision,
                   state.controller_instance_id,
                   sequence,
                   payload
                 ),
               {:ok, response} <-
                 ScaleSetTransport.call(state.socket_path, request, state.timeout_ms),
               {:ok, decoded} <- ScaleSetWire.decode_response(response, request_id) do
            decode_operation(operation, decoded)
          end

        next_state =
          record_commanded_eligibility(%{state | sequence: sequence}, operation, payload, result)

        {result, next_state}

      {:ok, _stale_sequence} ->
        {{:error, :scaleset_sequence_regression}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  # Persist the eligibility this call successfully commanded, so a future
  # restart (or periodic tick) reasserts it instead of drifting to whatever
  # the scale-set session's ambient state happens to be.
  defp record_commanded_eligibility(
         state,
         "apply_sessions",
         %{"eligible" => eligible},
         {:ok, _result}
       )
       when is_boolean(eligible) do
    case ScaleSetEligibility.persist(
           state.eligibility_path,
           state.controller_instance_id,
           eligible
         ) do
      :ok ->
        %{state | last_known_eligible: eligible}

      {:error, reason} ->
        Logger.warning(
          "failed to persist commanded scale-set eligibility; a restart may not reassert it",
          reason: inspect(reason),
          eligible: eligible
        )

        state
    end
  end

  defp record_commanded_eligibility(state, _operation, _payload, _result), do: state

  defp decode_operation("issue_jit", result), do: ScaleSetWire.decode_jit_result(result)
  defp decode_operation("read_snapshot", result), do: ScaleSetWire.decode_snapshot(result)
  defp decode_operation("read_jit_state", result), do: ScaleSetWire.decode_jit_states(result)
  defp decode_operation(_operation, result), do: {:ok, result}

  defp validate_state(state) do
    cond do
      not is_binary(state.socket_path) or Path.type(state.socket_path) != :absolute ->
        {:error, :invalid_scaleset_socket}

      not Identifier.valid?(state.controller_instance_id) ->
        {:error, :invalid_controller_instance_id}

      not is_binary(state.sequence_path) or Path.type(state.sequence_path) != :absolute ->
        {:error, :invalid_scaleset_sequence_path}

      not revision?(state.config_revision) or not revision?(state.ownership_revision) ->
        {:error, :invalid_scaleset_revision}

      not is_integer(state.timeout_ms) or state.timeout_ms <= 0 or state.timeout_ms > 120_000 ->
        {:error, :invalid_scaleset_timeout}

      true ->
        :ok
    end
  end

  defp revision?(value) when is_binary(value) and byte_size(value) == 64 do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp revision?(_), do: false
end
