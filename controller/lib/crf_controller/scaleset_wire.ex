defmodule CrfController.ScaleSetWire do
  alias CrfController.{Identifier, Secret}

  @schema_version 1
  @max_frame_bytes 1024 * 1024
  @operations ~w(apply_sessions publish_capacity_leases issue_jit retire_jit confirm_jit_retirement read_snapshot read_jit_state reconcile_owned delete_owned)

  def encode_request(
        request_id,
        operation,
        config_revision,
        ownership_revision,
        controller_id,
        sequence,
        payload
      )
      when is_binary(request_id) and is_binary(operation) and is_binary(config_revision) and
             is_binary(ownership_revision) and is_binary(controller_id) and is_integer(sequence) and
             sequence > 0 and is_map(payload) do
    with true <- Identifier.valid?(request_id),
         true <- operation in @operations,
         true <- revision?(config_revision),
         true <- revision?(ownership_revision),
         true <- Identifier.valid?(controller_id) do
      encoded =
        %{
          "schema_version" => @schema_version,
          "request_id" => request_id,
          "operation" => operation,
          "config_revision" => config_revision,
          "ownership_revision" => ownership_revision,
          "controller_instance_id" => controller_id,
          "sequence" => sequence,
          "payload" => payload
        }
        |> :json.encode()
        |> IO.iodata_to_binary()

      if byte_size(encoded) <= @max_frame_bytes,
        do: {:ok, encoded},
        else: {:error, :scaleset_request_too_large}
    else
      false -> {:error, :invalid_scaleset_request}
    end
  end

  def encode_request(_, _, _, _, _, _, _), do: {:error, :invalid_scaleset_request}

  def decode_response(binary, expected_request_id)
      when is_binary(binary) and is_binary(expected_request_id) and
             byte_size(binary) <= @max_frame_bytes do
    with {:ok, decoded} <- decode_json(binary),
         :ok <- allowed_keys(decoded),
         true <- decoded["schema_version"] == @schema_version,
         true <- is_boolean(decoded["ok"]) do
      decode_response_body(decoded, expected_request_id)
    else
      false -> {:error, :invalid_scaleset_response}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_response(_, _), do: {:error, :scaleset_response_too_large}

  def decode_jit_result(result) when is_map(result) do
    with :ok <- exact_keys(result, ["descriptor", "scale_set_id"]),
         descriptor when is_binary(descriptor) <- result["descriptor"],
         {:ok, secret} <- Secret.new(descriptor),
         scale_set_id when is_integer(scale_set_id) and scale_set_id > 0 <- result["scale_set_id"] do
      {:ok, %{descriptor: secret, scale_set_id: scale_set_id}}
    else
      _ -> {:error, :invalid_jit_response}
    end
  end

  def decode_jit_result(_), do: {:error, :invalid_jit_response}

  def decode_jit_states(%{"states" => states})
      when is_list(states) and length(states) <= 131_072 do
    states
    |> Enum.reduce_while({:ok, []}, fn state, {:ok, acc} ->
      with :ok <-
             exact_keys(state, [
               "pool_id",
               "scale_set_id",
               "work_handle",
               "state",
               "ownership_revision",
               "descriptor_available"
             ]),
           true <- Identifier.valid?(state["pool_id"]),
           scale_set_id when is_integer(scale_set_id) and scale_set_id > 0 <-
             state["scale_set_id"],
           work_handle when is_integer(work_handle) and work_handle > 0 <- state["work_handle"],
           lifecycle
           when lifecycle in ["issue_started", "issued", "retirement_started", "retired"] <-
             state["state"],
           true <- revision?(state["ownership_revision"]),
           true <- is_boolean(state["descriptor_available"]) do
        decoded = %{
          pool_id: state["pool_id"],
          scale_set_id: scale_set_id,
          work_handle: work_handle,
          state: lifecycle,
          ownership_revision: state["ownership_revision"],
          descriptor_available: state["descriptor_available"]
        }

        {:cont, {:ok, [decoded | acc]}}
      else
        _ -> {:halt, {:error, :invalid_jit_state_response}}
      end
    end)
    |> reverse_result()
  end

  def decode_jit_states(_), do: {:error, :invalid_jit_state_response}

  def decode_snapshot(result, now \\ DateTime.utc_now())

  def decode_snapshot(result, now) when is_map(result) do
    with :ok <-
           exact_keys(result, [
             "schema_version",
             "controller_instance_id",
             "config_revision",
             "ownership_revision",
             "sequence",
             "observed_at",
             "valid_until",
             "pools"
           ]),
         true <- result["schema_version"] == @schema_version,
         true <- Identifier.valid?(result["controller_instance_id"]),
         true <- revision?(result["config_revision"]) and revision?(result["ownership_revision"]),
         sequence when is_integer(sequence) and sequence >= 0 <- result["sequence"],
         {:ok, observed_at} <- parse_time(result["observed_at"]),
         {:ok, valid_until} <- parse_time(result["valid_until"]),
         :ok <- fresh(observed_at, valid_until, now, 30_000),
         {:ok, pools} <- decode_pools(result["pools"], now) do
      {:ok,
       %{
         controller_instance_id: result["controller_instance_id"],
         config_revision: result["config_revision"],
         ownership_revision: result["ownership_revision"],
         sequence: sequence,
         observed_at: observed_at,
         valid_until: valid_until,
         pools: pools
       }}
    else
      false -> {:error, :invalid_scaleset_snapshot}
      _ -> {:error, :invalid_scaleset_snapshot}
    end
  end

  def decode_snapshot(_, _), do: {:error, :invalid_scaleset_snapshot}

  defp decode_response_body(%{"ok" => true} = decoded, expected_request_id) do
    if decoded["request_id"] == expected_request_id and is_nil(decoded["code"]) and
         is_nil(decoded["error"]) do
      {:ok, Map.get(decoded, "result")}
    else
      {:error, :scaleset_response_mismatch}
    end
  end

  defp decode_response_body(%{"ok" => false} = decoded, expected_request_id) do
    request_id = Map.get(decoded, "request_id")
    code = Map.get(decoded, "code")

    cond do
      request_id not in [nil, "", expected_request_id] -> {:error, :scaleset_response_mismatch}
      not is_binary(code) or not Identifier.valid?(code) -> {:error, :invalid_scaleset_response}
      code == "sequence_regression" -> decode_sequence_regression(decoded)
      true -> {:error, {:scaleset_error, code}}
    end
  end

  defp decode_sequence_regression(%{"result" => %{"last_sequence" => sequence} = result})
       when map_size(result) == 1 and is_integer(sequence) and sequence > 0 and
              sequence < 18_446_744_073_709_551_615,
       do: {:error, {:scaleset_sequence_regression, sequence}}

  defp decode_sequence_regression(_), do: {:error, :invalid_scaleset_response}

  defp allowed_keys(map) when is_map(map) do
    allowed = MapSet.new(["schema_version", "request_id", "ok", "code", "error", "result"])

    if MapSet.subset?(MapSet.new(Map.keys(map)), allowed),
      do: :ok,
      else: {:error, :unexpected_scaleset_fields}
  end

  defp decode_pools(pools, now) when is_list(pools) and length(pools) <= 8 do
    pools
    |> Enum.reduce_while({:ok, []}, fn pool, {:ok, acc} ->
      case decode_pool(pool, now) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  defp decode_pools(_, _), do: {:error, :invalid_scaleset_snapshot}

  defp decode_pool(pool, now) when is_map(pool) do
    with :ok <-
           exact_keys(pool, [
             "pool_id",
             "scale_set_id",
             "assigned_jobs",
             "advertised_capacity",
             "last_message_id",
             "session_healthy",
             "acquired_handles",
             "fast_lane_state",
             "fast_lane_long_threshold_ms",
             "fast_lane_hold_duration_ms",
             "fast_lane_reserved_slots",
             "fast_lane_hold_until_ms",
             "observed_at",
             "valid_until"
           ]),
         true <- Identifier.valid?(pool["pool_id"]),
         scale_set_id when is_integer(scale_set_id) and scale_set_id >= 0 <- pool["scale_set_id"],
         assigned when is_integer(assigned) and assigned >= 0 <- pool["assigned_jobs"],
         capacity when is_integer(capacity) and capacity >= 0 <- pool["advertised_capacity"],
         last_message_id when is_integer(last_message_id) and last_message_id >= 0 <-
           pool["last_message_id"],
         true <- is_boolean(pool["session_healthy"]),
         {:ok, handles} <- handles(pool["acquired_handles"]),
         fast_lane_state when fast_lane_state in ["inactive", "holding", "borrow_pending"] <-
           pool["fast_lane_state"],
         fast_lane_threshold when is_integer(fast_lane_threshold) <-
           pool["fast_lane_long_threshold_ms"],
         fast_lane_hold_duration when is_integer(fast_lane_hold_duration) <-
           pool["fast_lane_hold_duration_ms"],
         fast_lane_reserved_slots when is_integer(fast_lane_reserved_slots) <-
           pool["fast_lane_reserved_slots"],
         fast_lane_hold_until when is_integer(fast_lane_hold_until) <-
           pool["fast_lane_hold_until_ms"],
         :ok <-
           fast_lane(
             fast_lane_state,
             fast_lane_threshold,
             fast_lane_hold_duration,
             fast_lane_reserved_slots,
             fast_lane_hold_until,
             capacity,
             now
           ),
         {:ok, observed_at} <- parse_time(pool["observed_at"]),
         {:ok, valid_until} <- parse_time(pool["valid_until"]),
         :ok <- pool_fresh(observed_at, valid_until, now) do
      {:ok,
       %{
         pool_id: pool["pool_id"],
         scale_set_id: scale_set_id,
         assigned_jobs: assigned,
         advertised_capacity: capacity,
         last_message_id: last_message_id,
         session_healthy: pool["session_healthy"],
         acquired_handles: handles,
         fast_lane_state: fast_lane_state,
         fast_lane_long_threshold_ms: fast_lane_threshold,
         fast_lane_hold_duration_ms: fast_lane_hold_duration,
         fast_lane_reserved_slots: fast_lane_reserved_slots,
         fast_lane_hold_until_ms: fast_lane_hold_until,
         observed_at: observed_at,
         valid_until: valid_until
       }}
    else
      _ -> {:error, :invalid_scaleset_snapshot}
    end
  end

  defp decode_pool(_, _), do: {:error, :invalid_scaleset_snapshot}

  defp handles(values) when is_list(values) and length(values) <= 64 do
    if Enum.all?(values, &(is_integer(&1) and &1 > 0)) and
         length(Enum.uniq(values)) == length(values),
       do: {:ok, values},
       else: {:error, :invalid_scaleset_snapshot}
  end

  defp handles(_), do: {:error, :invalid_scaleset_snapshot}

  defp fast_lane("inactive", 0, 0, 0, 0, _capacity, _now), do: :ok

  defp fast_lane(state, threshold, hold_duration, reserved_slots, hold_until, capacity, now)
       when state in ["inactive", "holding", "borrow_pending"] and
              threshold >= 240_000 and threshold <= 480_000 and
              hold_duration >= 5_000 and hold_duration <= 30_000 and
              reserved_slots >= 1 and reserved_slots <= 4 and
              capacity > reserved_slots do
    max_hold_until = DateTime.to_unix(DateTime.add(now, 120, :second), :millisecond)

    cond do
      state == "inactive" and hold_until == 0 -> :ok
      state != "inactive" and hold_until > 0 and hold_until <= max_hold_until -> :ok
      true -> {:error, :invalid_scaleset_snapshot}
    end
  end

  defp fast_lane(_, _, _, _, _, _, _), do: {:error, :invalid_scaleset_snapshot}

  defp fresh(observed_at, valid_until, now, max_ttl_ms) do
    cond do
      DateTime.compare(observed_at, DateTime.add(now, 5, :second)) == :gt ->
        {:error, :snapshot_from_future}

      DateTime.compare(valid_until, now) != :gt ->
        {:error, :snapshot_expired}

      DateTime.diff(valid_until, observed_at, :millisecond) > max_ttl_ms ->
        {:error, :snapshot_ttl_too_long}

      true ->
        :ok
    end
  end

  defp pool_fresh(%DateTime{year: 1}, _valid_until, _now), do: :ok

  defp pool_fresh(observed_at, valid_until, now),
    do: fresh(observed_at, valid_until, now, 120_000)

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> {:ok, time}
      _ -> {:error, :invalid_time}
    end
  end

  defp parse_time(_), do: {:error, :invalid_time}

  defp decode_json(binary) do
    try do
      case :json.decode(binary) do
        decoded when is_map(decoded) -> {:ok, decoded}
        _ -> {:error, :invalid_scaleset_json}
      end
    rescue
      _ -> {:error, :invalid_scaleset_json}
    catch
      _, _ -> {:error, :invalid_scaleset_json}
    end
  end

  defp exact_keys(map, expected) when is_map(map) do
    if MapSet.new(Map.keys(map)) == MapSet.new(expected),
      do: :ok,
      else: {:error, :unexpected_scaleset_fields}
  end

  defp revision?(value) when is_binary(value) and byte_size(value) == 64 do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp revision?(_), do: false
  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result(error), do: error
end
