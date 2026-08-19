defmodule CrfController.ScaleSetSequence do
  import Bitwise

  alias CrfController.Identifier

  @schema_version 1
  @max_state_bytes 4096

  def load(path, controller_instance_id) do
    with :ok <- validate_args(path, controller_instance_id) do
      if File.exists?(path) do
        read_state(path, controller_instance_id)
      else
        {:ok, 0}
      end
    end
  end

  def reserve(path, controller_instance_id) do
    with :ok <- validate_args(path, controller_instance_id),
         {:ok, current} <- load(path, controller_instance_id),
         next when is_integer(next) <- safe_increment(current),
         :ok <- persist(path, controller_instance_id, next) do
      {:ok, next}
    else
      nil -> {:error, :scaleset_sequence_exhausted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_args(path, controller_instance_id) do
    cond do
      not is_binary(path) or Path.type(path) != :absolute ->
        {:error, :invalid_scaleset_sequence_path}

      not Identifier.valid?(controller_instance_id) ->
        {:error, :invalid_controller_instance_id}

      true ->
        :ok
    end
  end

  defp read_state(path, controller_instance_id) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size in 1..@max_state_bytes,
         true <- (stat.mode &&& 0o777) == 0o600,
         {:ok, binary} <- File.read(path),
         {:ok, state} <- decode_state(binary),
         true <- state["controller_instance_id"] == controller_instance_id,
         sequence when is_integer(sequence) and sequence >= 0 <- state["sequence"],
         true <- state["checksum"] == checksum(controller_instance_id, sequence) do
      {:ok, sequence}
    else
      false -> {:error, :invalid_scaleset_sequence_state}
      {:error, _reason} -> {:error, :invalid_scaleset_sequence_state}
      _ -> {:error, :invalid_scaleset_sequence_state}
    end
  end

  defp persist(path, controller_instance_id, sequence) do
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
              "sequence" => sequence,
              "checksum" => checksum(controller_instance_id, sequence)
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
            {:error, _reason} -> {:error, :scaleset_sequence_persist_failed}
          end
        after
          _ = :file.close(file)
        end

      _ = File.rm(temporary)
      result
    else
      {:error, _reason} ->
        _ = File.rm(temporary)
        {:error, :scaleset_sequence_persist_failed}
    end
  end

  defp decode_state(binary) do
    try do
      case :json.decode(binary) do
        %{
          "schema_version" => @schema_version,
          "controller_instance_id" => controller_instance_id,
          "sequence" => sequence,
          "checksum" => checksum
        } = state
        when map_size(state) == 4 and is_binary(controller_instance_id) and
               is_integer(sequence) and is_binary(checksum) ->
          {:ok, state}

        _ ->
          {:error, :invalid_scaleset_sequence_state}
      end
    rescue
      _ -> {:error, :invalid_scaleset_sequence_state}
    catch
      _, _ -> {:error, :invalid_scaleset_sequence_state}
    end
  end

  defp safe_increment(sequence) when sequence < 18_446_744_073_709_551_615, do: sequence + 1
  defp safe_increment(_), do: nil

  defp checksum(controller_instance_id, sequence) do
    :crypto.hash(:sha256, "crf-scaleset-sequence-v1|#{controller_instance_id}|#{sequence}")
    |> Base.encode16(case: :lower)
  end
end
