defmodule CrfController.PeerIdentity do
  alias CrfController.Identifier

  @enforce_keys [:node_id, :certificate_sha256]
  defstruct [:node_id, :certificate_sha256]

  @type t :: %__MODULE__{node_id: String.t(), certificate_sha256: String.t()}

  @spec from_authenticated_certificate(String.t(), binary()) :: {:ok, t()} | {:error, atom()}
  def from_authenticated_certificate(node_id, certificate_der)
      when is_binary(certificate_der) and byte_size(certificate_der) > 0 do
    if Identifier.valid?(node_id) do
      fingerprint = :crypto.hash(:sha256, certificate_der) |> Base.encode16(case: :lower)
      {:ok, %__MODULE__{node_id: node_id, certificate_sha256: fingerprint}}
    else
      {:error, :invalid_node_id}
    end
  end

  def from_authenticated_certificate(_node_id, _certificate_der),
    do: {:error, :invalid_certificate}
end
