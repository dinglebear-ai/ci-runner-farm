defmodule CrfController.TlsOptions do
  @spec server(keyword()) :: {:ok, keyword()} | {:error, atom()}
  def server(opts) when is_list(opts) do
    with {:ok, certfile} <- required_path(opts, :certfile),
         {:ok, keyfile} <- required_path(opts, :keyfile),
         {:ok, cacertfile} <- required_path(opts, :cacertfile) do
      {:ok,
       [
         verify: :verify_peer,
         fail_if_no_peer_cert: true,
         versions: [:"tlsv1.3"],
         cacertfile: String.to_charlist(cacertfile),
         certs_keys: [
           %{
             certfile: String.to_charlist(certfile),
             keyfile: String.to_charlist(keyfile)
           }
         ]
       ]}
    end
  end

  def server(_), do: {:error, :invalid_tls_options}

  defp required_path(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, String.to_atom("missing_#{key}")}
    end
  end
end
