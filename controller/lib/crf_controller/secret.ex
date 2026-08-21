defmodule CrfController.Secret do
  @max_bytes 64 * 1024

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @spec new(String.t()) :: {:ok, t()} | {:error, :invalid_secret}
  def new(value) when is_binary(value) and byte_size(value) in 1..@max_bytes do
    if valid_bytes?(value), do: {:ok, %__MODULE__{value: value}}, else: {:error, :invalid_secret}
  end

  def new(_), do: {:error, :invalid_secret}

  @spec expose(t()) :: String.t()
  def expose(%__MODULE__{value: value}), do: value

  defp valid_bytes?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte ->
      byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z or byte in ~c"._+/=:-"
    end)
  end
end

defimpl Inspect, for: CrfController.Secret do
  import Inspect.Algebra

  def inspect(_secret, _opts), do: concat(["#CrfController.Secret<", "[REDACTED]", ">"])
end
