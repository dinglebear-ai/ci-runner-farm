defmodule CrfController.ScaleSetEligibility do
  @moduledoc """
  Durably records the eligibility value most recently commanded via
  `CrfController.ScaleSetClient.apply_sessions/2`, so a controller/sidecar
  restart can reassert it instead of silently inheriting whatever ambient
  eligibility the scale-set sessions already have on GitHub's side.

  Fixes the class of incident where an operator (or a raw RPC bypassing
  `runner-migration.sh`) sets eligibility once, the sidecar later restarts for
  any reason, and nothing reasserts the intended value — so jobs can route to
  a scale-set session the fleet's own migration state considers ineligible.
  """
  import Bitwise

  alias CrfController.Identifier

  @schema_version 1
  @max_state_bytes 4096

  @spec load(String.t(), String.t()) :: {:ok, boolean() | nil} | {:error, atom()}
  def load(path, controller_instance_id) do
    with :ok <- validate_args(path, controller_instance_id) do
      if File.exists?(path) do
        read_state(path, controller_instance_id)
      else
        {:ok, nil}
      end
    end
  end

  @spec persist(String.t(), String.t(), boolean()) :: :ok | {:error, atom()}
  def persist(path, controller_instance_id, eligible) when is_boolean(eligible) do
    with :ok <- validate_args(path, controller_instance_id) do
      write_state(path, controller_instance_id, eligible)
    end
  end

  defp validate_args(path, controller_instance_id) do
    cond do
      not is_binary(path) or Path.type(path) != :absolute ->
        {:error, :invalid_scaleset_eligibility_path}

      not Identifier.valid?(controller_instance_id) ->
        {:error, :invalid_controller_instance_id}

      true ->
        :ok
    end
  end

  defp read_state(path, controller_instance_id) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size in 1..@max_state_bytes,
         true <- secure_state_mode?(stat.mode),
         {:ok, binary} <- File.read(path),
         {:ok, state} <- decode_state(binary),
         true <- state["controller_instance_id"] == controller_instance_id,
         eligible when is_boolean(eligible) <- state["eligible"],
         true <- state["checksum"] == checksum(controller_instance_id, eligible) do
      {:ok, eligible}
    else
      false -> {:error, :invalid_scaleset_eligibility_state}
      {:error, _reason} -> {:error, :invalid_scaleset_eligibility_state}
      _ -> {:error, :invalid_scaleset_eligibility_state}
    end
  end

  defp write_state(path, controller_instance_id, eligible) do
    directory = Path.dirname(path)
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(directory),
         {:ok, file} <-
           :file.open(String.to_charlist(temporary), [:write, :binary, :raw, :exclusive]) do
      result =
        try do
          encoded =
            :json.encode(%{
              "schema_version" => @schema_version,
              "controller_instance_id" => controller_instance_id,
              "eligible" => eligible,
              "checksum" => checksum(controller_instance_id, eligible)
            })
            |> IO.iodata_to_binary()

          with :ok <- :file.write(file, encoded),
               :ok <- :file.sync(file),
               :ok <- File.chmod(temporary, 0o600),
               :ok <- :file.close(file),
               :ok <- File.rename(temporary, path),
               :ok <- File.chmod(path, 0o600) do
            :ok
          else
            {:error, _reason} -> {:error, :scaleset_eligibility_persist_failed}
          end
        after
          _ = :file.close(file)
        end

      _ = File.rm(temporary)
      result
    else
      {:error, _reason} ->
        _ = File.rm(temporary)
        {:error, :scaleset_eligibility_persist_failed}
    end
  end

  defp decode_state(binary) do
    try do
      case :json.decode(binary) do
        %{
          "schema_version" => @schema_version,
          "controller_instance_id" => controller_instance_id,
          "eligible" => eligible,
          "checksum" => checksum
        } = state
        when map_size(state) == 4 and is_binary(controller_instance_id) and
               is_boolean(eligible) and is_binary(checksum) ->
          {:ok, state}

        _ ->
          {:error, :invalid_scaleset_eligibility_state}
      end
    rescue
      _ -> {:error, :invalid_scaleset_eligibility_state}
    catch
      _, _ -> {:error, :invalid_scaleset_eligibility_state}
    end
  end

  defp secure_state_mode?(mode) do
    case :os.type() do
      {:win32, _} -> true
      _ -> (mode &&& 0o777) == 0o600
    end
  end

  defp checksum(controller_instance_id, eligible) do
    :crypto.hash(
      :sha256,
      "crf-scaleset-eligibility-v1|#{controller_instance_id}|#{eligible}"
    )
    |> Base.encode16(case: :lower)
  end
end
