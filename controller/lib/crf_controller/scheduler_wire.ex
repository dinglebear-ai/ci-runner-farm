defmodule CrfController.SchedulerWire do
  alias CrfController.{Identifier, Node, Resources}

  @protocol_version 1
  @max_items 4096
  @max_wire_message_bytes 256 * 1024
  @oses [:linux, :windows, :macos, :other]
  @arches [:x86_64, :arm64, :other]
  @backends [:container, :native_process, :virtual_machine]
  @reasons ["invalid_request", "no_eligible_node", "insufficient_resources"]

  def encode_request(request_id, requests, nodes)
      when is_binary(request_id) and is_list(requests) and is_list(nodes) do
    with true <- Identifier.valid?(request_id),
         true <- length(requests) <= @max_items and length(nodes) <= @max_items,
         {:ok, requests} <- encode_requests(requests),
         {:ok, nodes} <- encode_nodes(nodes) do
      payload = %{
        "protocol_version" => @protocol_version,
        "request_id" => request_id,
        "requests" => requests,
        "nodes" => nodes
      }

      encoded = payload |> :json.encode() |> IO.iodata_to_binary()

      if byte_size(encoded) <= @max_wire_message_bytes,
        do: {:ok, encoded},
        else: {:error, :scheduler_message_too_large}
    else
      false -> {:error, :invalid_scheduler_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def encode_request(_, _, _), do: {:error, :invalid_scheduler_request}

  def decode_response(binary, expected_request_id)
      when is_binary(binary) and is_binary(expected_request_id) and
             byte_size(binary) <= @max_wire_message_bytes do
    with {:ok, decoded} <- decode_json(binary),
         :ok <-
           exact_keys(decoded, ["protocol_version", "request_id", "status", "code", "result"]),
         true <- decoded["protocol_version"] == @protocol_version do
      decode_status(decoded, expected_request_id)
    else
      false -> {:error, :unsupported_scheduler_protocol}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_response(_, _), do: {:error, :scheduler_message_too_large}

  defp encode_requests(requests) do
    requests
    |> Enum.reduce_while({:ok, []}, fn request, {:ok, acc} ->
      case encode_work(request) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_result()
  end

  defp encode_nodes(nodes) do
    nodes
    |> Enum.reduce_while({:ok, []}, fn
      %Node{} = node, {:ok, acc} -> {:cont, {:ok, [node_map(node) | acc]}}
      _, _ -> {:halt, {:error, :invalid_scheduler_node}}
    end)
    |> reverse_result()
  end

  defp encode_work(request) when is_map(request) do
    with work_id when is_binary(work_id) <- Map.get(request, :work_id),
         true <- Identifier.valid?(work_id),
         pool_id when is_binary(pool_id) <- Map.get(request, :pool_id),
         true <- Identifier.valid?(pool_id),
         {:ok, resources} <- Resources.new(Map.get(request, :resources)),
         true <- resources.cpu_millis > 0 and resources.memory_bytes > 0,
         {:ok, os} <- optional_enum(Map.get(request, :required_os), @oses, :invalid_required_os),
         {:ok, arch} <-
           optional_enum(Map.get(request, :required_arch), @arches, :invalid_required_arch),
         {:ok, backend} <-
           optional_enum(
             Map.get(request, :required_backend),
             @backends,
             :invalid_required_backend
           ),
         {:ok, capabilities} <- capabilities(Map.get(request, :required_capabilities, [])) do
      {:ok,
       %{
         "work_id" => work_id,
         "pool_id" => pool_id,
         "resources" => resources_map(resources),
         "required_os" => nullable_atom(os),
         "required_arch" => nullable_atom(arch),
         "required_backend" => nullable_atom(backend),
         "required_capabilities" => capabilities
       }}
    else
      false -> {:error, :invalid_scheduler_work}
      nil -> {:error, :invalid_scheduler_work}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_scheduler_work}
    end
  end

  defp encode_work(_), do: {:error, :invalid_scheduler_work}

  defp node_map(%Node{} = node) do
    %{
      "node_id" => node.id,
      "generation" => node.generation,
      "os" => Atom.to_string(node.os),
      "arch" => Atom.to_string(node.arch),
      "execution_backends" =>
        node.execution_backends |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
      "capabilities" => node.capabilities |> Enum.sort(),
      "total" => resources_map(node.total),
      "available" => resources_map(node.available),
      "draining" => node.draining
    }
  end

  defp decode_status(%{"status" => "ok"} = response, expected_request_id) do
    with true <- response["request_id"] == expected_request_id,
         true <- response["code"] == :null,
         {:ok, result} <- decode_result(response["result"]) do
      {:ok, result}
    else
      false -> {:error, :scheduler_response_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_status(%{"status" => "error"} = response, expected_request_id) do
    request_id = response["request_id"]
    code = response["code"]

    cond do
      request_id not in [:null, expected_request_id] -> {:error, :scheduler_response_mismatch}
      not is_binary(code) or not Identifier.valid?(code) -> {:error, :invalid_scheduler_response}
      response["result"] != :null -> {:error, :invalid_scheduler_response}
      true -> {:error, {:scheduler_error, code}}
    end
  end

  defp decode_status(_, _), do: {:error, :invalid_scheduler_response}

  defp decode_result(result) when is_map(result) do
    with :ok <- exact_keys(result, ["placements", "unplaced"]),
         {:ok, placements} <- decode_placements(result["placements"]),
         {:ok, unplaced} <- decode_unplaced(result["unplaced"]) do
      {:ok, %{placements: placements, unplaced: unplaced}}
    end
  end

  defp decode_result(_), do: {:error, :invalid_scheduler_response}

  defp decode_placements(values) when is_list(values) and length(values) <= @max_items do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      with true <- is_map(value),
           :ok <-
             exact_keys(value, ["work_id", "pool_id", "node_id", "node_generation", "reserved"]),
           true <- Identifier.valid?(value["work_id"]),
           true <- Identifier.valid?(value["pool_id"]),
           true <- Identifier.valid?(value["node_id"]),
           generation when is_integer(generation) and generation > 0 <- value["node_generation"],
           {:ok, resources} <- Resources.new(atomize_resources(value["reserved"])),
           true <- resources.cpu_millis > 0 and resources.memory_bytes > 0 do
        placement = %{
          work_id: value["work_id"],
          pool_id: value["pool_id"],
          node_id: value["node_id"],
          node_generation: generation,
          reserved: resources
        }

        {:cont, {:ok, [placement | acc]}}
      else
        _ -> {:halt, {:error, :invalid_scheduler_response}}
      end
    end)
    |> reverse_result()
  end

  defp decode_placements(_), do: {:error, :invalid_scheduler_response}

  defp decode_unplaced(values) when is_list(values) and length(values) <= @max_items do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      with true <- is_map(value),
           :ok <- exact_keys(value, ["work_id", "reason"]),
           true <- Identifier.valid?(value["work_id"]),
           reason when reason in @reasons <- value["reason"] do
        {:cont, {:ok, [%{work_id: value["work_id"], reason: reason} | acc]}}
      else
        _ -> {:halt, {:error, :invalid_scheduler_response}}
      end
    end)
    |> reverse_result()
  end

  defp decode_unplaced(_), do: {:error, :invalid_scheduler_response}

  defp decode_json(binary) do
    try do
      case :json.decode(binary) do
        decoded when is_map(decoded) -> {:ok, decoded}
        _ -> {:error, :invalid_scheduler_json}
      end
    rescue
      _ -> {:error, :invalid_scheduler_json}
    catch
      _, _ -> {:error, :invalid_scheduler_json}
    end
  end

  defp exact_keys(map, expected) when is_map(map) do
    if MapSet.new(Map.keys(map)) == MapSet.new(expected),
      do: :ok,
      else: {:error, :unexpected_scheduler_fields}
  end

  defp optional_enum(nil, _allowed, _error), do: {:ok, nil}

  defp optional_enum(value, allowed, error) do
    if value in allowed, do: {:ok, value}, else: {:error, error}
  end

  defp capabilities(values) when is_list(values) and length(values) <= 128 do
    if Enum.all?(values, &Identifier.valid?/1),
      do: {:ok, values |> MapSet.new() |> Enum.sort()},
      else: {:error, :invalid_required_capabilities}
  end

  defp capabilities(_), do: {:error, :invalid_required_capabilities}

  defp nullable_atom(nil), do: :null
  defp nullable_atom(value), do: Atom.to_string(value)

  defp resources_map(%Resources{} = resources) do
    %{"cpu_millis" => resources.cpu_millis, "memory_bytes" => resources.memory_bytes}
  end

  defp atomize_resources(%{"cpu_millis" => cpu, "memory_bytes" => memory}) do
    %{cpu_millis: cpu, memory_bytes: memory}
  end

  defp atomize_resources(_), do: %{}

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result(error), do: error
end
