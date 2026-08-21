defmodule CrfController.WorkIdentity do
  alias CrfController.Identifier

  def for_handle(pool_id, scale_set_id, work_handle)
      when is_binary(pool_id) and is_integer(scale_set_id) and scale_set_id > 0 and
             is_integer(work_handle) and work_handle > 0 do
    if Identifier.valid?(pool_id) do
      digest = digest("crf-work-v1|#{pool_id}|#{scale_set_id}|#{work_handle}")
      short = binary_part(digest, 0, 32)
      runner = binary_part(digest, 0, 24)

      {:ok,
       %{
         work_id: "work-#{short}",
         offer_id: "offer-#{short}",
         placement_id: "placement-#{short}",
         command_id: "command-#{short}",
         idempotency_key: "idem-#{digest}",
         runner_name: "crf-#{runner}"
       }}
    else
      {:error, :invalid_work_identity}
    end
  end

  def for_handle(_, _, _), do: {:error, :invalid_work_identity}

  defp digest(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
