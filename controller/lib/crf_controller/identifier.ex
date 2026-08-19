defmodule CrfController.Identifier do
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value) and byte_size(value) in 1..128 do
    case String.to_charlist(value) do
      [first | rest] when first in ?0..?9 or first in ?A..?Z or first in ?a..?z ->
        Enum.all?(rest, fn char ->
          char in ?0..?9 or char in ?A..?Z or char in ?a..?z or char in ~c"._:-"
        end)

      _ ->
        false
    end
  end

  def valid?(_), do: false
end
