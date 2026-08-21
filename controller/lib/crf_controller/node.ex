defmodule CrfController.Node do
  alias CrfController.{Identifier, Resources}

  @operating_systems [:linux, :windows, :macos, :other]
  @architectures [:x86_64, :arm64, :other]
  @execution_backends [:container, :native_process, :virtual_machine]

  @enforce_keys [
    :id,
    :generation,
    :os,
    :arch,
    :execution_backends,
    :capabilities,
    :total,
    :available,
    :active_placements,
    :draining,
    :last_seen_ms
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          generation: pos_integer(),
          os: atom(),
          arch: atom(),
          execution_backends: MapSet.t(atom()),
          capabilities: MapSet.t(String.t()),
          total: Resources.t(),
          available: Resources.t(),
          active_placements: MapSet.t(String.t()),
          draining: boolean(),
          last_seen_ms: integer()
        }

  @spec new(map(), integer()) :: {:ok, t()} | {:error, atom()}
  def new(attrs, now_ms) when is_map(attrs) and is_integer(now_ms) do
    with {:ok, id} <- fetch_identifier(attrs, :id),
         {:ok, generation} <- fetch_generation(attrs),
         {:ok, os} <- fetch_enum(attrs, :os, @operating_systems),
         {:ok, arch} <- fetch_enum(attrs, :arch, @architectures),
         {:ok, execution_backends} <- fetch_backends(attrs),
         {:ok, capabilities} <- fetch_capabilities(attrs),
         {:ok, total} <- Resources.new(Map.get(attrs, :total)),
         :ok <- positive_resources(total),
         {:ok, available} <- Resources.new(Map.get(attrs, :available)),
         true <- Resources.fits?(total, available) do
      {:ok,
       %__MODULE__{
         id: id,
         generation: generation,
         os: os,
         arch: arch,
         execution_backends: execution_backends,
         capabilities: capabilities,
         total: total,
         available: available,
         active_placements: MapSet.new(),
         draining: Map.get(attrs, :draining, false) == true,
         last_seen_ms: now_ms
       }}
    else
      false -> {:error, :available_exceeds_total}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(_, _), do: {:error, :invalid_node}

  @spec heartbeat(t(), pos_integer(), map() | Resources.t(), MapSet.t(String.t()), integer()) ::
          {:ok, t()} | {:error, atom()}
  def heartbeat(
        %__MODULE__{generation: generation} = node,
        generation,
        available,
        %MapSet{} = active_placements,
        now_ms
      )
      when is_integer(now_ms) do
    with {:ok, available} <- Resources.new(available),
         true <- Resources.fits?(node.total, available),
         true <- Enum.all?(active_placements, &Identifier.valid?/1) do
      {:ok,
       %{
         node
         | available: available,
           active_placements: active_placements,
           last_seen_ms: now_ms
       }}
    else
      false -> {:error, :invalid_heartbeat}
      {:error, reason} -> {:error, reason}
    end
  end

  def heartbeat(%__MODULE__{}, _generation, _available, _active_placements, _now_ms),
    do: {:error, :generation_mismatch}

  @spec set_draining(t(), pos_integer(), boolean()) :: {:ok, t()} | {:error, :generation_mismatch}
  def set_draining(%__MODULE__{generation: generation} = node, generation, draining)
      when is_boolean(draining),
      do: {:ok, %{node | draining: draining}}

  def set_draining(%__MODULE__{}, _generation, _draining), do: {:error, :generation_mismatch}

  defp fetch_identifier(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        if Identifier.valid?(value), do: {:ok, value}, else: {:error, :invalid_node_id}

      _ ->
        {:error, :invalid_node_id}
    end
  end

  defp fetch_generation(attrs) do
    case Map.fetch(attrs, :generation) do
      {:ok, generation} when is_integer(generation) and generation > 0 -> {:ok, generation}
      _ -> {:error, :invalid_generation}
    end
  end

  defp fetch_enum(attrs, key, allowed) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        if value in allowed, do: {:ok, value}, else: {:error, String.to_atom("invalid_#{key}")}

      _ ->
        {:error, String.to_atom("invalid_#{key}")}
    end
  end

  defp fetch_backends(attrs) do
    backends = Map.get(attrs, :execution_backends, [])

    if is_list(backends) and backends != [] and Enum.all?(backends, &(&1 in @execution_backends)) do
      {:ok, MapSet.new(backends)}
    else
      {:error, :invalid_execution_backends}
    end
  end

  defp fetch_capabilities(attrs) do
    capabilities = Map.get(attrs, :capabilities, [])

    if is_list(capabilities) and Enum.all?(capabilities, &Identifier.valid?/1) do
      {:ok, MapSet.new(capabilities)}
    else
      {:error, :invalid_capabilities}
    end
  end

  defp positive_resources(%Resources{cpu_millis: cpu_millis, memory_bytes: memory_bytes})
       when cpu_millis > 0 and memory_bytes > 0,
       do: :ok

  defp positive_resources(_), do: {:error, :invalid_resources}
end
