defmodule CrfController.PlacementStateStore do
  import Bitwise

  alias CrfController.{Placement, PlacementTombstone}

  @schema_version 3
  @previous_schema_version 2
  @legacy_schema_version 1
  @max_state_bytes 16 * 1024 * 1024
  @max_records 65_536
  @max_journal_record_bytes 64 * 1024
  @max_journal_bytes 32 * 1024 * 1024
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
      base =
        if File.exists?(path), do: read(path), else: {:ok, %{placements: %{}, tombstones: %{}}}

      with {:ok, state} <- base, do: replay_journal(path, state)
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

  def append(nil, _record), do: :ok

  def append(path, record) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, payload} <- encode_journal_record(record),
         true <- byte_size(payload) <= @max_journal_record_bytes,
         :ok <- append_frame(journal_path(path), payload) do
      :ok
    else
      false -> {:error, :invalid_placement_state}
      {:error, reason} -> {:error, reason}
    end
  end

  def append(_, _), do: {:error, :invalid_placement_state}

  def checkpoint(nil, _placements, _tombstones), do: :ok

  def checkpoint(path, placements, tombstones) do
    with :ok <- persist(path, placements, tombstones),
         :ok <- remove_journal(path) do
      :ok
    end
  end

  def journal_size(nil), do: 0

  def journal_size(path) do
    case File.stat(journal_path(path)) do
      {:ok, stat} -> stat.size
      {:error, :enoent} -> 0
      {:error, _reason} -> 0
    end
  end

  def compact(placements, tombstones) when is_map(placements) and is_map(tombstones) do
    %{placements: placements, tombstones: tombstones}
  end

  def capacity_available?(placements, tombstones, limit \\ @max_records)
      when is_map(placements) and is_map(tombstones) and is_integer(limit) and limit > 0,
      do: map_size(placements) + map_size(tombstones) < min(limit, @max_records)

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

  defp encode_journal_record({:put, %Placement{} = placement}) do
    encode_journal_map(%{"op" => "put_placement", "record" => placement_map(placement)})
  end

  defp encode_journal_record({:put, %PlacementTombstone{} = tombstone}) do
    encode_journal_map(%{"op" => "put_tombstone", "record" => tombstone_map(tombstone)})
  end

  defp encode_journal_record({:prune_before_generation, node_id, generation})
       when is_binary(node_id) and byte_size(node_id) in 1..128 and is_integer(generation) and
              generation > 0 do
    encode_journal_map(%{
      "op" => "prune_before_generation",
      "node_id" => node_id,
      "generation" => generation
    })
  end

  defp encode_journal_record(_), do: {:error, :invalid_placement_state}

  defp encode_journal_map(record) do
    try do
      {:ok, :json.encode(record) |> IO.iodata_to_binary()}
    rescue
      _ -> {:error, :placement_state_encode_failed}
    end
  end

  defp replay_journal(path, state) do
    journal = journal_path(path)

    case File.stat(journal) do
      {:ok, stat}
      when stat.type == :regular and stat.size <= @max_journal_bytes ->
        if secure_state_mode?(stat.mode) do
          with {:ok, binary} <- File.read(journal), do: replay_frames(binary, state)
        else
          {:error, :invalid_placement_state}
        end

      {:error, :enoent} ->
        {:ok, state}

      _ ->
        {:error, :invalid_placement_state}
    end
  end

  defp replay_frames(<<>>, state), do: {:ok, state}
  # A crash may leave only the final frame incomplete. No acknowledged update can
  # have returned before its complete frame was synced, so ignoring that tail is safe.
  defp replay_frames(binary, state) when byte_size(binary) < 36, do: {:ok, state}

  defp replay_frames(<<length::unsigned-big-integer-size(32), rest::binary>>, state)
       when length in 1..@max_journal_record_bytes do
    frame_bytes = length + 32

    if byte_size(rest) < frame_bytes do
      {:ok, state}
    else
      <<digest::binary-size(32), payload::binary-size(^length), tail::binary>> = rest

      with true <- :crypto.hash(:sha256, payload) == digest,
           {:ok, next_state} <- apply_journal_record(payload, state) do
        replay_frames(tail, next_state)
      else
        _ -> {:error, :invalid_placement_state}
      end
    end
  end

  defp replay_frames(_binary, _state), do: {:error, :invalid_placement_state}

  defp apply_journal_record(payload, state) do
    try do
      case :json.decode(payload) do
        %{"op" => "put_placement", "record" => record} = value when map_size(value) == 2 ->
          with {:ok, placement} <- decode_placement(record) do
            {:ok,
             %{
               placements: Map.put(state.placements, placement.id, placement),
               tombstones: Map.delete(state.tombstones, placement.id)
             }}
          end

        %{"op" => "put_tombstone", "record" => record} = value when map_size(value) == 2 ->
          with {:ok, tombstone} <- decode_tombstone(record, @schema_version) do
            {:ok,
             %{
               placements: Map.delete(state.placements, tombstone.id),
               tombstones: Map.put(state.tombstones, tombstone.id, tombstone)
             }}
          end

        %{
          "op" => "prune_before_generation",
          "node_id" => node_id,
          "generation" => generation
        } = value
        when map_size(value) == 3 and is_binary(node_id) and byte_size(node_id) in 1..128 and
               is_integer(generation) and generation > 0 ->
          {:ok,
           %{
             state
             | tombstones:
                 Map.reject(state.tombstones, fn {_id, tombstone} ->
                   tombstone.node_id == node_id and tombstone.node_generation < generation
                 end)
           }}

        _ ->
          {:error, :invalid_placement_state}
      end
    rescue
      _ -> {:error, :invalid_placement_state}
    end
  end

  defp append_frame(path, payload) do
    directory = Path.dirname(path)
    journal_exists? = File.exists?(path)

    frame = [
      <<byte_size(payload)::unsigned-big-integer-size(32)>>,
      :crypto.hash(:sha256, payload),
      payload
    ]

    with :ok <- File.mkdir_p(directory),
         {:ok, file} <- :file.open(String.to_charlist(path), [:append, :binary, :raw]) do
      try do
        with :ok <- File.chmod(path, 0o600),
             :ok <- :file.write(file, frame),
             :ok <- :file.sync(file),
             :ok <- File.chmod(path, 0o600),
             :ok <- sync_new_journal_directory(directory, journal_exists?) do
          :ok
        else
          {:error, _reason} -> {:error, :placement_state_persist_failed}
        end
      after
        _ = :file.close(file)
      end
    else
      {:error, _reason} -> {:error, :placement_state_persist_failed}
    end
  end

  defp sync_new_journal_directory(_directory, true), do: :ok
  defp sync_new_journal_directory(directory, false), do: sync_directory(directory)

  defp remove_journal(path) do
    case File.rm(journal_path(path)) do
      :ok -> sync_directory(Path.dirname(path))
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :placement_state_persist_failed}
    end
  end

  defp journal_path(path), do: path <> ".wal"

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
          "schema_version" => version,
          "placements" => placements,
          "tombstones" => tombstones
        } = state
        when version in [@previous_schema_version, @schema_version] and map_size(state) == 3 and
               is_list(placements) and is_list(tombstones) and
               length(placements) + length(tombstones) <= @max_records ->
          {:ok, {version, placements, tombstones}}

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

  defp decode_state({version, placement_records, tombstone_records})
       when version in [@previous_schema_version, @schema_version] do
    with {:ok, placements, placement_commands} <- decode_live_placements(placement_records),
         {:ok, tombstones, tombstone_commands} <- decode_tombstones(tombstone_records, version),
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

  defp decode_tombstones(records, version) do
    Enum.reduce_while(records, {:ok, %{}, MapSet.new()}, fn record, {:ok, acc, commands} ->
      case decode_tombstone(record, version) do
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

  defp decode_tombstone(
         [
           id,
           command_id,
           idempotency_sha256,
           node_id,
           node_generation,
           state_value,
           detail_value,
           updated_at_ms
         ],
         @schema_version
       ) do
    detail = nullable_string(detail_value)

    tombstone = %PlacementTombstone{
      id: id,
      command_id: command_id,
      idempotency_sha256: idempotency_sha256,
      node_id: node_id,
      node_generation: node_generation,
      state: Map.get(@terminal_states, state_value),
      detail_code: if(detail == :invalid, do: nil, else: detail),
      updated_at_ms: updated_at_ms
    }

    if detail != :invalid and PlacementTombstone.valid?(tombstone) do
      {:ok, tombstone}
    else
      {:error, :invalid_placement_state}
    end
  end

  defp decode_tombstone(
         [id, command_id, digest, node_id, generation, state, detail],
         @previous_schema_version
       ) do
    decode_tombstone(
      [id, command_id, digest, node_id, generation, state, detail, 0],
      @schema_version
    )
  end

  defp decode_tombstone(_, _), do: {:error, :invalid_placement_state}

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
      if(is_nil(tombstone.detail_code), do: :null, else: tombstone.detail_code),
      tombstone.updated_at_ms
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
               :ok <- File.chmod(path, 0o600),
               :ok <- sync_directory(directory) do
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

  defp sync_directory(directory) do
    case :os.type() do
      {:win32, _} ->
        :ok

      _ ->
        case :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
          {:ok, directory_file} ->
            try do
              :file.sync(directory_file)
            after
              _ = :file.close(directory_file)
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
