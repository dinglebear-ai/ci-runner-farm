defmodule CrfController.PeerAuthorizer do
  alias CrfController.{Identifier, PeerIdentity}

  @enforce_keys [:by_fingerprint]
  defstruct [:by_fingerprint]

  @type t :: %__MODULE__{by_fingerprint: %{String.t() => String.t()}}

  @spec new([{String.t(), String.t()}]) :: {:ok, t()} | {:error, atom()}
  def new(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {fingerprint, node_id}, {:ok, acc} ->
      with {:ok, fingerprint} <- normalize_fingerprint(fingerprint),
           true <- Identifier.valid?(node_id) do
        if Map.has_key?(acc, fingerprint) do
          {:halt, {:error, :duplicate_or_invalid_identity}}
        else
          {:cont, {:ok, Map.put(acc, fingerprint, node_id)}}
        end
      else
        false -> {:halt, {:error, :duplicate_or_invalid_identity}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, by_fingerprint} when map_size(by_fingerprint) > 0 ->
        {:ok, %__MODULE__{by_fingerprint: by_fingerprint}}

      {:ok, _} ->
        {:error, :empty_authorizer}

      error ->
        error
    end
  end

  def new(_), do: {:error, :invalid_authorizer}

  def empty, do: %__MODULE__{by_fingerprint: %{}}

  @spec authorize(t(), binary()) :: {:ok, PeerIdentity.t()} | {:error, atom()}
  def authorize(%__MODULE__{} = authorizer, certificate_der)
      when is_binary(certificate_der) and byte_size(certificate_der) > 0 do
    fingerprint = :crypto.hash(:sha256, certificate_der) |> Base.encode16(case: :lower)

    case Map.fetch(authorizer.by_fingerprint, fingerprint) do
      {:ok, node_id} -> PeerIdentity.from_authenticated_certificate(node_id, certificate_der)
      :error -> {:error, :unauthorized_certificate}
    end
  end

  def authorize(%__MODULE__{}, _), do: {:error, :invalid_certificate}

  @spec authorize_identity(t(), PeerIdentity.t()) :: :ok | {:error, atom()}
  def authorize_identity(
        %__MODULE__{} = authorizer,
        %PeerIdentity{node_id: node_id, certificate_sha256: fingerprint}
      ) do
    case Map.fetch(authorizer.by_fingerprint, fingerprint) do
      {:ok, ^node_id} -> :ok
      {:ok, _different_node} -> {:error, :authenticated_identity_mismatch}
      :error -> {:error, :unauthorized_certificate}
    end
  end

  defp normalize_fingerprint(value) when is_binary(value) and byte_size(value) == 64 do
    normalized = String.downcase(value)

    valid? =
      normalized
      |> :binary.bin_to_list()
      |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)

    if valid?, do: {:ok, normalized}, else: {:error, :invalid_fingerprint}
  end

  defp normalize_fingerprint(_), do: {:error, :invalid_fingerprint}
end
