defmodule CrfController.Placement do
  alias CrfController.{Identifier, Resources}

  @terminal_states [:finished, :failed, :cancelled]
  @ordered_states [:commanded, :accepted, :starting, :observed, :running]

  @enforce_keys [
    :id,
    :command_id,
    :idempotency_key,
    :node_id,
    :node_generation,
    :work_id,
    :pool_id,
    :resources,
    :state,
    :detail_code,
    :updated_at_ms
  ]
  defstruct @enforce_keys

  @type state ::
          :commanded
          | :accepted
          | :starting
          | :observed
          | :running
          | :finished
          | :failed
          | :cancelled
  @type t :: %__MODULE__{
          id: String.t(),
          command_id: String.t(),
          idempotency_key: String.t(),
          node_id: String.t(),
          node_generation: pos_integer(),
          work_id: String.t(),
          pool_id: String.t(),
          resources: Resources.t(),
          state: state(),
          detail_code: String.t() | nil,
          updated_at_ms: integer()
        }

  @spec new(map(), integer()) :: {:ok, t()} | {:error, atom()}
  def new(attrs, now_ms) when is_map(attrs) and is_integer(now_ms) do
    with {:ok, id} <- fetch_identifier(attrs, :id),
         {:ok, command_id} <- fetch_identifier(attrs, :command_id),
         {:ok, idempotency_key} <- fetch_identifier(attrs, :idempotency_key),
         {:ok, node_id} <- fetch_identifier(attrs, :node_id),
         {:ok, node_generation} <- positive_integer(Map.get(attrs, :node_generation)),
         {:ok, work_id} <- fetch_identifier(attrs, :work_id),
         {:ok, pool_id} <- fetch_identifier(attrs, :pool_id),
         {:ok, resources} <- Resources.new(Map.get(attrs, :resources)),
         true <- resources.cpu_millis > 0 and resources.memory_bytes > 0 do
      {:ok,
       %__MODULE__{
         id: id,
         command_id: command_id,
         idempotency_key: idempotency_key,
         node_id: node_id,
         node_generation: node_generation,
         work_id: work_id,
         pool_id: pool_id,
         resources: resources,
         state: :commanded,
         detail_code: nil,
         updated_at_ms: now_ms
       }}
    else
      false -> {:error, :invalid_resources}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(_, _), do: {:error, :invalid_placement}

  @spec command_ack(t(), atom(), String.t() | nil, integer()) :: {:ok, t()} | {:error, atom()}
  def command_ack(%__MODULE__{} = placement, status, detail_code, now_ms) do
    with :ok <- validate_detail_code(detail_code) do
      case status do
        status when status in [:accepted, :duplicate] ->
          acknowledge_success(placement, detail_code, now_ms)

        :rejected ->
          advance(placement, :failed, detail_code || "command_rejected", now_ms)

        _ ->
          {:error, :invalid_ack_status}
      end
    end
  end

  @spec advance(t(), state(), String.t() | nil, integer()) :: {:ok, t()} | {:error, atom()}
  def advance(%__MODULE__{} = placement, next_state, detail_code, now_ms)
      when is_integer(now_ms) do
    with :ok <- validate_state(next_state),
         :ok <- validate_detail_code(detail_code),
         :ok <- transition_allowed(placement.state, next_state) do
      {:ok, %{placement | state: next_state, detail_code: detail_code, updated_at_ms: now_ms}}
    end
  end

  def adopt_generation(%__MODULE__{} = placement, node_id, generation, now_ms)
      when is_binary(node_id) and is_integer(generation) and is_integer(now_ms) do
    cond do
      placement.node_id != node_id -> {:error, :node_identity_mismatch}
      generation < placement.node_generation -> {:error, :generation_mismatch}
      generation == placement.node_generation -> {:ok, placement}
      true -> {:ok, %{placement | node_generation: generation, updated_at_ms: now_ms}}
    end
  end

  def adopt_generation(%__MODULE__{}, _node_id, _generation, _now_ms),
    do: {:error, :generation_mismatch}

  def terminal?(%__MODULE__{state: state}), do: state in @terminal_states

  def same_command?(%__MODULE__{} = left, %__MODULE__{} = right) do
    left.id == right.id and left.command_id == right.command_id and
      left.idempotency_key == right.idempotency_key and left.node_id == right.node_id and
      left.node_generation == right.node_generation and left.work_id == right.work_id and
      left.pool_id == right.pool_id and left.resources == right.resources
  end

  defp acknowledge_success(%__MODULE__{state: :commanded} = placement, detail_code, now_ms),
    do: advance(placement, :accepted, detail_code, now_ms)

  defp acknowledge_success(%__MODULE__{} = placement, _detail_code, _now_ms), do: {:ok, placement}

  defp transition_allowed(current, next) when current == next, do: :ok

  defp transition_allowed(current, next) when current in @terminal_states do
    if current == next, do: :ok, else: {:error, :terminal_state_conflict}
  end

  defp transition_allowed(current, next) when next in @terminal_states do
    if current in @ordered_states, do: :ok, else: {:error, :invalid_transition}
  end

  defp transition_allowed(current, next) do
    with current_index when is_integer(current_index) <-
           Enum.find_index(@ordered_states, &(&1 == current)),
         next_index when is_integer(next_index) <- Enum.find_index(@ordered_states, &(&1 == next)),
         true <- next_index >= current_index do
      :ok
    else
      _ -> {:error, :invalid_transition}
    end
  end

  defp validate_state(state) do
    if state in @ordered_states or state in @terminal_states,
      do: :ok,
      else: {:error, :invalid_placement_state}
  end

  defp validate_detail_code(nil), do: :ok

  defp validate_detail_code(value) do
    if Identifier.valid?(value), do: :ok, else: {:error, :invalid_detail_code}
  end

  defp fetch_identifier(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        if Identifier.valid?(value),
          do: {:ok, value},
          else: {:error, String.to_atom("invalid_#{key}")}

      :error ->
        {:error, String.to_atom("invalid_#{key}")}
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_), do: {:error, :invalid_node_generation}
end
