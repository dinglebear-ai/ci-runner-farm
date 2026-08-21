defmodule CrfController.PlacementTombstone do
  alias CrfController.{Identifier, Placement}

  @terminal_states [:finished, :failed, :cancelled]

  @enforce_keys [
    :id,
    :command_id,
    :idempotency_sha256,
    :node_id,
    :node_generation,
    :state,
    :detail_code
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          command_id: String.t(),
          idempotency_sha256: String.t(),
          node_id: String.t(),
          node_generation: pos_integer(),
          state: :finished | :failed | :cancelled,
          detail_code: String.t() | nil
        }

  def from_placement(%Placement{} = placement) do
    if Placement.terminal?(placement) do
      {:ok,
       %__MODULE__{
         id: placement.id,
         command_id: placement.command_id,
         idempotency_sha256: digest(placement.idempotency_key),
         node_id: placement.node_id,
         node_generation: placement.node_generation,
         state: placement.state,
         detail_code: placement.detail_code
       }}
    else
      {:error, :placement_not_terminal}
    end
  end

  def terminal?(%__MODULE__{}), do: true

  def command_ack(
        %__MODULE__{} = tombstone,
        node_id,
        generation,
        command_id,
        idempotency_key,
        status,
        detail_code,
        _now_ms
      ) do
    with :ok <- command_identity(tombstone, node_id, generation, command_id, idempotency_key),
         :ok <- validate_detail_code(detail_code) do
      case status do
        status when status in [:accepted, :duplicate] ->
          {:ok, tombstone}

        :rejected when tombstone.state == :failed ->
          {:ok, %{tombstone | detail_code: detail_code || tombstone.detail_code}}

        :rejected ->
          {:error, :terminal_state_conflict}

        _ ->
          {:error, :invalid_ack_status}
      end
    end
  end

  def placement_update(
        %__MODULE__{} = tombstone,
        node_id,
        generation,
        command_id,
        state,
        detail_code,
        _now_ms
      ) do
    with :ok <- placement_identity(tombstone, node_id, generation, command_id),
         true <- state == tombstone.state,
         :ok <- validate_detail_code(detail_code) do
      {:ok, %{tombstone | node_generation: generation, detail_code: detail_code}}
    else
      false -> {:error, :terminal_state_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  def valid?(%__MODULE__{} = tombstone) do
    Identifier.valid?(tombstone.id) and Identifier.valid?(tombstone.command_id) and
      valid_digest?(tombstone.idempotency_sha256) and Identifier.valid?(tombstone.node_id) and
      is_integer(tombstone.node_generation) and tombstone.node_generation > 0 and
      tombstone.state in @terminal_states and valid_detail_code?(tombstone.detail_code)
  end

  def digest(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.url_encode64(padding: false)
  end

  defp command_identity(tombstone, node_id, generation, command_id, idempotency_key) do
    cond do
      tombstone.node_id != node_id ->
        {:error, :node_identity_mismatch}

      tombstone.node_generation != generation ->
        {:error, :generation_mismatch}

      tombstone.command_id != command_id ->
        {:error, :command_id_mismatch}

      tombstone.idempotency_sha256 != digest(idempotency_key) ->
        {:error, :idempotency_key_mismatch}

      true ->
        :ok
    end
  end

  defp placement_identity(tombstone, node_id, generation, command_id) do
    cond do
      tombstone.node_id != node_id -> {:error, :node_identity_mismatch}
      tombstone.command_id != command_id -> {:error, :command_id_mismatch}
      generation < tombstone.node_generation -> {:error, :generation_mismatch}
      true -> :ok
    end
  end

  defp validate_detail_code(value) do
    if valid_detail_code?(value), do: :ok, else: {:error, :invalid_detail_code}
  end

  defp valid_detail_code?(nil), do: true
  defp valid_detail_code?(value), do: Identifier.valid?(value)

  defp valid_digest?(value) when is_binary(value) and byte_size(value) == 43 do
    match?({:ok, <<_::256>>}, Base.url_decode64(value, padding: false))
  end

  defp valid_digest?(_), do: false
end
