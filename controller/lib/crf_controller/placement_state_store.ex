defmodule CrfController.PlacementStateStore do
  import Bitwise

  alias CrfController.{Placement, PlacementTombstone}

  @schema_version 2
  @legacy_schema_version 1
  @max_state_bytes 16 * 1024 * 1024
  @max_records 65_536
  @states %{
    "commanded" => :commanded,
    "accepted" => :accepted,
    "starting" => :starting,
    "observed" => :observed,
    "running" => :running,
    "finished" => :finished,
    "failed" => :failed,
    "cancelled" => :cancelled
  }
  @terminal_states Map.take(@states, ["finished", "failed", "cancelled"])

  def load(nil), do: {:ok, %{placements: %{}, tombstones: %{}}}

  def load(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute do
      if File.exists?(path), do: read(path), else: {:ok, %{placements: %{}, tombstones: %{}}}
    else
      false -> {:error, :invalid_placement_state_path}
    end
  end

  def load(_), do: {:error, :invalid_placement_state_path}

  def persist(nil, placements, tombstones) when is_map(placements) and is_map(tombstones), do: :ok

  def persist(path, placements, tombstones)
      when is_binary(path) and is_map(placements) and is_map(tombstones) do
    with true <- Path.type(path) == :absolute,
         true <- map_size(placements) + map_size(tombstones) <= @max_records,
         :ok <- validate_disjoint(placements, tombstones),
         {:ok, encoded} <- encode(placements, tombstones),
         true <- byte_size(encoded) <= @max_state_bytes do
      atomic_write(path, encoded)
    else
      false -> {:error, :invalid_placement_state}
      {:error, reason} -> {:error, reason}
    end
  end

  def persist(_, _, _), do: {:error, :invalid_placement_state}

  defp read(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size in 1..@max_state_bytes,
         true <- secure_state_mode?(stat.mode),
         {:ok, binary} <- File.read(path),
         {:ok, decoded} <- decode_json(binary),
         {:ok, state} <- decode_state(decoded) do
      {:ok, state}
    else
      false -> {:error, :invalid_placement_state}
      {:error, _reason} -> {:error, :invalid_placement_state}
    end
  end

  defp encode(placements, tombstones) do
    records =
      placements
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&placement_map/1)

    compact =
      tombstones
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&tombstone_map/1)

    try do
      {:ok,
       :json.encode(%{
         "schema_version" => @schema_version,
         "placements" => records,
         "tombstones" => compact
       })
       |> IO.iodata_to_binary()}
    rescue
      _ -> {:error, :placement_state_encode_failed}
    catch
      _, _ -> {:error, :placement_state_encode_failed}
    end
  end

  defp decode_json(binary) do
    try do
      case :json.decode(binary) do
        %{"schema_version" => @legacy_schema_version, "placements" => placements} = state
        when map_size(state) == 2 and is_list(placements) and length(placements) <= @max_records ->
          {:ok, {:v1, placements}}

        %{
          "schema_version" => @schema_version,
          "placements" => placements,
          "tombstones" => tombstones
        } = state
        when map_size(state) == 3 and is_list(placements) and is_list(tombstones) and
               length(placements) + length(tombstones) <= @max_records ->
          {:ok, {:v2, placements, tombstones}}

        _ ->
          {:error, :invalid_placement_state}
      end
    rescue
      _ -> {:error, :invalid_placement_state}
    catch
      _, _ -> {:error, :invalid_placement_state}
    end
  end

  defp decode_state({:v1, records}) do
    with {:ok, placements} <- decode_placements(records) do
      Enum.reduce_while(placements, {:ok, %{placements: %{}, tombstones: %{}}}, fn {id, placement},
                                                                                   {:ok, state} ->
        if Placement.terminal?(placement) do
          case PlacementTombstone.from_placement(placement) do
            {:ok, tombstone} ->
              {:cont, {:ok, put_in(state, [:tombstones, id], tombstone)}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, put_in(state, [:placements, id], placement)}}
        end
      end)
    end
  end

  defp decode_state({:v2, placement_records, tombstone_records}) do
    with {:ok, placements, placement_commands} <- decode_live_placements(placement_records),
         {:ok, tombstones, tombstone_commands} <- decode_tombstones(tombstone_records),
         true <-
           MapSet.disjoint?(MapSet.new(Map.keys(placements)), MapSet.new(Map.keys(tombstones))),
         true <- MapSet.disjoint?(placement_commands, tombstone_commands) do
      {:ok, %{placements: placements, tombstones: tombstones}}
    else
      false -> {:error, :invalid_placement_state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_placements(records) do
    Enum.reduce_while(records, {:ok, %{}, MapSet.new()}, fn record, {:ok, acc, commands} ->
      case decode_placement(record) do
        {:ok, placement} ->
          cond do
            Map.has_key?(acc, placement.id) ->
              {:halt, {:error, :duplicate_placement_id}}

            MapSet.member?(commands, placement.command_id) ->
              {:halt, {:error, :duplicate_command_id}}

            true ->
              {:cont,
               {:ok, Map.put(acc, placement.id, placement),
                MapSet.put(commands, placement.command_id)}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, placements, _commands} -> {:ok, placements}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_live_placements(records) do
    Enum.reduce_while(records, {:ok, %{}, MapSet.new()}, fn record, {:ok, acc, commands} ->
      case decode_placement(record) do
        {:ok, placement} ->
          cond do
            Placement.terminal?(placement) ->
              {:halt, {:error, :terminal_placement_not_compacted}}

            Map.has_key?(acc, placement.id) ->
              {:halt, {:error, :duplicate_placement_id}}

            MapSet.member?(commands, placement.command_id) ->
              {:halt, {:error, :duplicate_command_id}}

            true ->
              {:cont,
               {:ok, Map.put(acc, placement.id, placement),
                MapSet.put(commands, placement.command_id)}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_tombstones(records) do
    Enum.reduce_while(records, {:ok, %{}, MapSet.new()}, fn record, {:ok, acc, commands} ->
      case decode_tombstone(record) do
        {:ok, tombstone} ->
          cond do
            Map.has_key?(acc, tombstone.id) ->
              {:halt, {:error, :duplicate_placement_id}}

            MapSet.member?(commands, tombstone.command_id) ->
              {:halt, {:error, :duplicate_command_id}}

            true ->
              {:cont,
               {:ok, Map.put(acc, tombstone.id, tombstone),
                MapSet.put(commands, tombstone.command_id)}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_placement(record) when is_map(record) do
    expected = [
      "id",
      "command_id",
      "idempotency_key",
      "node_id",
      "node_generation",
      "work_id",
      "pool_id",
      "resources",
      "state",
      "detail_code",
      "updated_at_ms"
    ]

    with true <- MapSet.new(Map.keys(record)) == MapSet.new(expected),
         state when is_atom(state) <- Map.get(@states, record["state"]),
         detail <- nullable_string(record["detail_code"]),
         true <- detail != :invalid,
         updated_at when is_integer(updated_at) <- record["updated_at_ms"],
         %{"cpu_millis" => cpu, "memory_bytes" => memory} <- record["resources"],
         {:ok, initial} <-
           Placement.new(
             %{
               id: record["id"],
               command_id: record["command_id"],
               idempotency_key: record["idempotency_key"],
               node_id: record["node_id"],
               node_generation: record["node_generation"],
               work_id: record["work_id"],
               pool_id: record["pool_id"],
               resources: %{cpu_millis: cpu, memory_bytes: memory}
             },
             updated_at
           ),
         {:ok, placement} <- restore_state(initial, state, detail, updated_at) do
      {:ok, placement}
    else
      _ -> {:error, :invalid_placement_state}
    end
  end

  defp decode_placement(_), do: {:error, :invalid_placement_state}

  defp decode_tombstone([
         id,
         command_id,
         idempotency_sha256,
         node_id,
         node_generation,
         state_value,
         detail_value
       ]) do
    detail = nullable_string(detail_value)

    tombstone = %PlacementTombstone{
      id: id,
      command_id: command_id,
      idempotency_sha256: idempotency_sha256,
      node_id: node_id,
      node_generation: node_generation,
      state: Map.get(@terminal_states, state_value),
      detail_code: if(detail == :invalid, do: nil, else: detail)
    }

    if detail != :invalid and PlacementTombstone.valid?(tombstone) do
      {:ok, tombstone}
    else
      {:error, :invalid_placement_state}
    end
  end

  defp decode_tombstone(_), do: {:error, :invalid_placement_state}

  defp restore_state(placement, :commanded, nil, _updated_at), do: {:ok, placement}

  defp restore_state(placement, state, detail, updated_at) do
    Placement.advance(placement, state, detail, updated_at)
  end

  defp nullable_string(:null), do: nil
  defp nullable_string(nil), do: nil
  defp nullable_string(value) when is_binary(value), do: value
  defp nullable_string(_), do: :invalid

  defp placement_map(%Placement{} = placement) do
    %{
      "id" => placement.id,
      "command_id" => placement.command_id,
      "idempotency_key" => placement.idempotency_key,
      "node_id" => placement.node_id,
      "node_generation" => placement.node_generation,
      "work_id" => placement.work_id,
      "pool_id" => placement.pool_id,
      "resources" => %{
        "cpu_millis" => placement.resources.cpu_millis,
        "memory_bytes" => placement.resources.memory_bytes
      },
      "state" => Atom.to_string(placement.state),
      "detail_code" => if(is_nil(placement.detail_code), do: :null, else: placement.detail_code),
      "updated_at_ms" => placement.updated_at_ms
    }
  end

  defp tombstone_map(%PlacementTombstone{} = tombstone) do
    [
      tombstone.id,
      tombstone.command_id,
      tombstone.idempotency_sha256,
      tombstone.node_id,
      tombstone.node_generation,
      Atom.to_string(tombstone.state),
      if(is_nil(tombstone.detail_code), do: :null, else: tombstone.detail_code)
    ]
  end

  defp validate_disjoint(placements, tombstones) do
    placement_ids = MapSet.new(Map.keys(placements))
    tombstone_ids = MapSet.new(Map.keys(tombstones))

    placement_commands = placements |> Map.values() |> Enum.map(& &1.command_id) |> MapSet.new()
    tombstone_commands = tombstones |> Map.values() |> Enum.map(& &1.command_id) |> MapSet.new()

    cond do
      not MapSet.disjoint?(placement_ids, tombstone_ids) ->
        {:error, :duplicate_placement_id}

      not MapSet.disjoint?(placement_commands, tombstone_commands) ->
        {:error, :duplicate_command_id}

      Enum.any?(Map.values(placements), &Placement.terminal?/1) ->
        {:error, :terminal_placement_not_compacted}

      Enum.any?(Map.values(tombstones), &(not PlacementTombstone.valid?(&1))) ->
        {:error, :invalid_placement_state}

      true ->
        :ok
    end
  end

  defp secure_state_mode?(mode) do
    case :os.type() do
      {:win32, _} -> true
      _ -> (mode &&& 0o777) == 0o600
    end
  end

  defp atomic_write(path, encoded) do
    directory = Path.dirname(path)
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(directory),
         {:ok, file} <-
           :file.open(String.to_charlist(temporary), [:write, :binary, :raw, :exclusive]) do
      result =
        try do
          with :ok <- :file.write(file, encoded),
               :ok <- :file.sync(file),
               :ok <- File.chmod(temporary, 0o600),
               :ok <- :file.close(file),
               :ok <- File.rename(temporary, path),
               :ok <- File.chmod(path, 0o600) do
            :ok
          else
            {:error, _reason} -> {:error, :placement_state_persist_failed}
          end
        after
          _ = :file.close(file)
        end

      _ = File.rm(temporary)
      result
    else
      {:error, _reason} ->
        _ = File.rm(temporary)
        {:error, :placement_state_persist_failed}
    end
  end
end
