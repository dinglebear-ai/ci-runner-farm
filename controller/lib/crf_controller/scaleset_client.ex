defmodule CrfController.ScaleSetClient do
  use GenServer

  alias CrfController.{Identifier, ScaleSetSequence, ScaleSetTransport, ScaleSetWire}

  @default_timeout_ms 30_000
  @call_timeout_ms 125_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def read_snapshot(server \\ __MODULE__),
    do: call(server, "read_snapshot", %{})

  def read_jit_state(server \\ __MODULE__),
    do: call(server, "read_jit_state", %{})

  def issue_jit(
        server \\ __MODULE__,
        pool_id,
        scale_set_id,
        work_handle,
        runner_name,
        work_folder
      ) do
    call(server, "issue_jit", %{
      "pool_id" => pool_id,
      "expected_scale_set_id" => scale_set_id,
      "work_handle" => work_handle,
      "runner_name" => runner_name,
      "work_folder" => work_folder
    })
  end

  def retire_jit(server \\ __MODULE__, pool_id, scale_set_id, work_handle) do
    call(server, "retire_jit", %{
      "pool_id" => pool_id,
      "expected_scale_set_id" => scale_set_id,
      "work_handle" => work_handle
    })
  end

  def confirm_jit_retirement(
        server \\ __MODULE__,
        pool_id,
        scale_set_id,
        work_handle,
        proof_ownership_revision \\ nil
      ) do
    payload = %{
      "pool_id" => pool_id,
      "expected_scale_set_id" => scale_set_id,
      "work_handle" => work_handle
    }

    payload =
      if is_nil(proof_ownership_revision),
        do: payload,
        else: Map.put(payload, "expected_ownership_revision", proof_ownership_revision)

    call(server, "confirm_jit_retirement", payload)
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

    state = %{
      socket_path: socket_path,
      sequence_path: sequence_path,
      controller_instance_id: controller_instance_id,
      config_revision: Keyword.get(opts, :config_revision),
      ownership_revision: Keyword.get(opts, :ownership_revision),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      sequence: 0
    }

    with :ok <- validate_state(state),
         {:ok, sequence} <- ScaleSetSequence.load(sequence_path, controller_instance_id) do
      {:ok, %{state | sequence: sequence}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:update_revisions, config_revision, ownership_revision}, _from, state) do
    updated = %{state | config_revision: config_revision, ownership_revision: ownership_revision}

    case validate_state(updated) do
      :ok -> {:reply, :ok, updated}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:call, operation, payload}, _from, state) do
    payload = add_operation_fence(operation, payload, state.ownership_revision)

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

        {:reply, result, %{state | sequence: sequence}}

      {:ok, _stale_sequence} ->
        {:reply, {:error, :scaleset_sequence_regression}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp decode_operation("issue_jit", result), do: ScaleSetWire.decode_jit_result(result)
  defp decode_operation("read_snapshot", result), do: ScaleSetWire.decode_snapshot(result)
  defp decode_operation("read_jit_state", result), do: ScaleSetWire.decode_jit_states(result)
  defp decode_operation(_operation, result), do: {:ok, result}

  defp add_operation_fence(operation, payload, ownership_revision)
       when operation in ["issue_jit", "retire_jit", "confirm_jit_retirement"] do
    Map.put_new(payload, "expected_ownership_revision", ownership_revision)
  end

  defp add_operation_fence(_operation, payload, _ownership_revision), do: payload

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
