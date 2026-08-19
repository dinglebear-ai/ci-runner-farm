defmodule CrfController.Framing do
  @max_payload_bytes 256 * 1024
  @header_bytes 4

  def max_payload_bytes, do: @max_payload_bytes

  @spec encode(binary()) :: {:ok, binary()} | {:error, atom()}
  def encode(payload)
      when is_binary(payload) and byte_size(payload) > 0 and
             byte_size(payload) <= @max_payload_bytes do
    {:ok, <<byte_size(payload)::unsigned-big-integer-size(32), payload::binary>>}
  end

  def encode(_), do: {:error, :invalid_frame_payload}

  @spec decode(binary()) :: {:ok, binary()} | {:error, atom()}
  def decode(<<length::unsigned-big-integer-size(32), payload::binary>>)
      when length > 0 and length <= @max_payload_bytes and byte_size(payload) == length,
      do: {:ok, payload}

  def decode(_), do: {:error, :invalid_frame}

  @spec header_bytes() :: pos_integer()
  def header_bytes, do: @header_bytes
end
