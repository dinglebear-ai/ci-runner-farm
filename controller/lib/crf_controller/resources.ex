defmodule CrfController.Resources do
  @enforce_keys [:cpu_millis, :memory_bytes]
  defstruct [:cpu_millis, :memory_bytes]

  @type t :: %__MODULE__{cpu_millis: non_neg_integer(), memory_bytes: non_neg_integer()}

  @spec new(map() | t()) :: {:ok, t()} | {:error, :invalid_resources}
  def new(%__MODULE__{} = resources), do: validate(resources)

  def new(%{cpu_millis: cpu_millis, memory_bytes: memory_bytes}) do
    validate(%__MODULE__{cpu_millis: cpu_millis, memory_bytes: memory_bytes})
  end

  def new(_), do: {:error, :invalid_resources}

  @spec fits?(t(), t()) :: boolean()
  def fits?(%__MODULE__{} = available, %__MODULE__{} = requested) do
    available.cpu_millis >= requested.cpu_millis and
      available.memory_bytes >= requested.memory_bytes
  end

  defp validate(%__MODULE__{cpu_millis: cpu_millis, memory_bytes: memory_bytes} = resources)
       when is_integer(cpu_millis) and cpu_millis >= 0 and is_integer(memory_bytes) and
              memory_bytes >= 0,
       do: {:ok, resources}

  defp validate(_), do: {:error, :invalid_resources}
end
