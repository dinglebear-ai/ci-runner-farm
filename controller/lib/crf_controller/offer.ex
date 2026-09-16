defmodule CrfController.Offer do
  alias CrfController.{Identifier, Resources}

  @max_ttl_ms 5 * 60 * 1000

  @enforce_keys [
    :id,
    :pool_id,
    :node_id,
    :node_generation,
    :resources,
    :state,
    :work_handle,
    :created_at_ms,
    :expires_at_ms
  ]
  defstruct @enforce_keys ++ [scale_set_id: nil]

  def new(attrs, now_ms) when is_map(attrs) and is_integer(now_ms) do
    with {:ok, id} <- identifier(Map.get(attrs, :id), :invalid_offer_id),
         {:ok, pool_id} <- identifier(Map.get(attrs, :pool_id), :invalid_pool_id),
         {:ok, node_id} <- identifier(Map.get(attrs, :node_id), :invalid_node_id),
         generation when is_integer(generation) and generation > 0 <-
           Map.get(attrs, :node_generation),
         {:ok, resources} <- Resources.new(Map.get(attrs, :resources)),
         true <- resources.cpu_millis > 0 and resources.memory_bytes > 0,
         scale_set_id when is_nil(scale_set_id) or (is_integer(scale_set_id) and scale_set_id > 0) <-
           Map.get(attrs, :scale_set_id),
         expires_at_ms when is_integer(expires_at_ms) <- Map.get(attrs, :expires_at_ms),
         true <- expires_at_ms > now_ms and expires_at_ms - now_ms <= @max_ttl_ms do
      {:ok,
       %__MODULE__{
         id: id,
         pool_id: pool_id,
         node_id: node_id,
         node_generation: generation,
         resources: resources,
         scale_set_id: scale_set_id,
         state: :offered,
         work_handle: nil,
         created_at_ms: now_ms,
         expires_at_ms: expires_at_ms
       }}
    else
      false -> {:error, :invalid_offer}
      nil -> {:error, :invalid_offer}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_offer}
    end
  end

  def new(_, _), do: {:error, :invalid_offer}

  def assign(%__MODULE__{state: :offered} = offer, work_handle)
      when is_integer(work_handle) and work_handle > 0,
      do: {:ok, %{offer | state: :assigned, work_handle: work_handle}}

  def assign(%__MODULE__{state: :assigned, work_handle: work_handle} = offer, work_handle),
    do: {:ok, offer}

  def assign(%__MODULE__{}, _), do: {:error, :offer_assignment_conflict}

  def expired?(%__MODULE__{state: :offered, expires_at_ms: expires_at_ms}, now_ms),
    do: now_ms > expires_at_ms

  def expired?(%__MODULE__{}, _now_ms), do: false

  def same_reservation?(%__MODULE__{} = left, %__MODULE__{} = right) do
    left.id == right.id and left.pool_id == right.pool_id and left.node_id == right.node_id and
      left.node_generation == right.node_generation and left.resources == right.resources and
      left.scale_set_id == right.scale_set_id
  end

  defp identifier(value, error) when is_binary(value) do
    if Identifier.valid?(value), do: {:ok, value}, else: {:error, error}
  end

  defp identifier(_, error), do: {:error, error}
end
