defmodule CrfController.PoolPolicy do
  alias CrfController.{Identifier, Resources}

  @oses [:linux, :windows, :macos, :other]
  @arches [:x86_64, :arm64, :other]
  @backends [:container, :native_process, :virtual_machine]

  @enforce_keys [
    :id,
    :max_concurrency,
    :resources,
    :required_os,
    :required_arch,
    :required_backend,
    :required_capabilities,
    :work_folder
  ]
  defstruct @enforce_keys ++ [preferred_cpu_millis: nil]

  def new(attrs) when is_map(attrs) do
    with id when is_binary(id) <- Map.get(attrs, :id),
         true <- Identifier.valid?(id),
         max when is_integer(max) and max in 1..64 <- Map.get(attrs, :max_concurrency),
         {:ok, resources} <- Resources.new(Map.get(attrs, :resources)),
         true <- resources.cpu_millis > 0 and resources.memory_bytes > 0,
         preferred_cpu when is_integer(preferred_cpu) <-
           Map.get(attrs, :preferred_cpu_millis, resources.cpu_millis),
         true <- preferred_cpu >= resources.cpu_millis,
         {:ok, os} <- optional_enum(Map.get(attrs, :required_os), @oses, :invalid_pool_os),
         {:ok, arch} <- optional_enum(Map.get(attrs, :required_arch), @arches, :invalid_pool_arch),
         backend when backend in @backends <- Map.get(attrs, :required_backend),
         {:ok, capabilities} <- capabilities(Map.get(attrs, :required_capabilities, [])),
         work_folder when is_binary(work_folder) <- Map.get(attrs, :work_folder, "_work"),
         true <- valid_work_folder?(work_folder) do
      {:ok,
       %__MODULE__{
         id: id,
         max_concurrency: max,
         resources: resources,
         preferred_cpu_millis: preferred_cpu,
         required_os: os,
         required_arch: arch,
         required_backend: backend,
         required_capabilities: capabilities,
         work_folder: work_folder
       }}
    else
      false -> {:error, :invalid_pool_policy}
      nil -> {:error, :invalid_pool_policy}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_pool_policy}
    end
  end

  def new(_), do: {:error, :invalid_pool_policy}

  def work_requirement(%__MODULE__{} = policy, work_id) when is_binary(work_id) do
    if Identifier.valid?(work_id) do
      {:ok,
       %{
         work_id: work_id,
         pool_id: policy.id,
         resources: policy.resources,
         preferred_cpu_millis: policy.preferred_cpu_millis,
         required_os: policy.required_os,
         required_arch: policy.required_arch,
         required_backend: policy.required_backend,
         required_capabilities: MapSet.to_list(policy.required_capabilities)
       }}
    else
      {:error, :invalid_work_id}
    end
  end

  defp optional_enum(nil, _allowed, _error), do: {:ok, nil}

  defp optional_enum(value, allowed, error),
    do: if(value in allowed, do: {:ok, value}, else: {:error, error})

  defp capabilities(values) when is_list(values) and length(values) <= 128 do
    if Enum.all?(values, &Identifier.valid?/1),
      do: {:ok, MapSet.new(values)},
      else: {:error, :invalid_pool_capabilities}
  end

  defp capabilities(_), do: {:error, :invalid_pool_capabilities}

  defp valid_work_folder?(value) when byte_size(value) in 1..64 do
    bytes = :binary.bin_to_list(value)

    case bytes do
      [first | rest] ->
        work_first?(first) and Enum.all?(rest, &work_rest?/1)

      [] ->
        false
    end
  end

  defp valid_work_folder?(_), do: false

  defp work_first?(byte), do: ascii_alnum?(byte) or byte == ?_
  defp work_rest?(byte), do: work_first?(byte) or byte in [?., ?-]

  defp ascii_alnum?(byte),
    do: byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z
end
