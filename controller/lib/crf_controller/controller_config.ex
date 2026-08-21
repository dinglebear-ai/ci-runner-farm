defmodule CrfController.ControllerConfig do
  import Bitwise

  alias CrfController.{Identifier, PeerAuthorizer, PoolPolicy}

  @schema_version 1
  @max_config_bytes 1_048_576
  @top_keys [
    "schema_version",
    "scheduler",
    "state",
    "node_registry",
    "scaleset",
    "sidecar",
    "tls",
    "demand"
  ]

  @enforce_keys [
    :scheduler_opts,
    :placement_opts,
    :node_registry_opts,
    :scaleset_opts,
    :sidecar_opts,
    :tls_opts,
    :demand_opts
  ]
  defstruct @enforce_keys

  def load(path) when is_binary(path) do
    with :ok <- absolute_path(path, :invalid_controller_config_path),
         {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size in 1..@max_config_bytes,
         true <- secure_config_mode?(stat.mode),
         {:ok, binary} <- File.read(path),
         {:ok, decoded} <- decode_json(binary),
         {:ok, config} <- parse(decoded) do
      {:ok, config}
    else
      false -> {:error, :invalid_controller_config_file}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_controller_config_file}
    end
  end

  def load(_), do: {:error, :invalid_controller_config_path}

  def parse(config) when is_map(config) do
    with :ok <- exact_keys(config, @top_keys),
         true <- config["schema_version"] == @schema_version,
         {:ok, scheduler_opts} <- scheduler(config["scheduler"]),
         {:ok, placement_opts} <- state(config["state"]),
         {:ok, node_registry_opts} <- node_registry(config["node_registry"]),
         {:ok, scaleset_opts} <- scaleset(config["scaleset"]),
         {:ok, sidecar_opts} <- sidecar(config["sidecar"], scaleset_opts[:socket_path]),
         {:ok, tls_opts} <- tls(config["tls"]),
         {:ok, demand_opts} <- demand(config["demand"]) do
      {:ok,
       %__MODULE__{
         scheduler_opts: scheduler_opts,
         placement_opts: placement_opts,
         node_registry_opts: node_registry_opts,
         scaleset_opts: scaleset_opts,
         sidecar_opts: sidecar_opts,
         tls_opts: tls_opts,
         demand_opts: demand_opts
       }}
    else
      false -> {:error, :unsupported_controller_config_version}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_controller_config}
    end
  end

  def parse(_), do: {:error, :invalid_controller_config}

  defp scheduler(map) when is_map(map) do
    with :ok <- exact_keys(map, ["executable", "request_timeout_ms"]),
         {:ok, executable} <-
           required_absolute_file(map, "executable", :invalid_scheduler_executable),
         {:ok, timeout} <-
           integer(map, "request_timeout_ms", 100..30_000, :invalid_scheduler_timeout) do
      {:ok, [executable: executable, request_timeout_ms: timeout]}
    end
  end

  defp scheduler(_), do: {:error, :invalid_scheduler_config}

  defp state(map) when is_map(map) do
    with :ok <- exact_keys(map, ["placement_path"]),
         {:ok, path} <-
           required_absolute_path(map, "placement_path", :invalid_placement_state_path) do
      {:ok, [state_path: path]}
    end
  end

  defp state(_), do: {:error, :invalid_state_config}

  defp node_registry(map) when is_map(map) do
    with :ok <- exact_keys(map, ["stale_after_ms"]),
         {:ok, stale_after_ms} <-
           integer(map, "stale_after_ms", 100..300_000, :invalid_stale_after_ms) do
      {:ok, [stale_after_ms: stale_after_ms]}
    end
  end

  defp node_registry(_), do: {:error, :invalid_node_registry_config}

  defp scaleset(map) when is_map(map) do
    keys = [
      "socket_path",
      "sequence_path",
      "controller_instance_id",
      "config_revision",
      "ownership_revision",
      "timeout_ms"
    ]

    with :ok <- exact_keys(map, keys),
         {:ok, socket_path} <-
           required_absolute_path(map, "socket_path", :invalid_scaleset_socket),
         {:ok, sequence_path} <-
           required_absolute_path(map, "sequence_path", :invalid_scaleset_sequence_path),
         {:ok, controller_id} <-
           identifier(map, "controller_instance_id", :invalid_controller_instance_id),
         {:ok, config_revision} <- revision(map["config_revision"]),
         {:ok, ownership_revision} <- revision(map["ownership_revision"]),
         {:ok, timeout_ms} <- integer(map, "timeout_ms", 100..120_000, :invalid_scaleset_timeout) do
      {:ok,
       [
         socket_path: socket_path,
         sequence_path: sequence_path,
         controller_instance_id: controller_id,
         config_revision: config_revision,
         ownership_revision: ownership_revision,
         timeout_ms: timeout_ms
       ]}
    end
  end

  defp scaleset(_), do: {:error, :invalid_scaleset_config}

  defp sidecar(nil, _socket_path), do: {:ok, nil}
  defp sidecar(:null, _socket_path), do: {:ok, nil}

  defp sidecar(map, socket_path) when is_map(map) do
    keys = ["executable", "runtime_config", "compatibility", "startup_timeout_ms"]

    with :ok <- exact_keys(map, keys),
         {:ok, executable} <-
           required_absolute_file(map, "executable", :invalid_scaleset_sidecar_executable),
         {:ok, runtime_config} <-
           required_private_file(map, "runtime_config", :invalid_scaleset_runtime_config),
         {:ok, compatibility} <-
           required_private_file(map, "compatibility", :invalid_scaleset_compatibility),
         {:ok, startup_timeout_ms} <-
           integer(
             map,
             "startup_timeout_ms",
             100..120_000,
             :invalid_scaleset_sidecar_timeout
           ) do
      {:ok,
       [
         executable: executable,
         socket_path: socket_path,
         runtime_config: runtime_config,
         compatibility: compatibility,
         startup_timeout_ms: startup_timeout_ms
       ]}
    end
  end

  defp sidecar(_value, _socket_path), do: {:error, :invalid_scaleset_sidecar_config}

  defp tls(map) when is_map(map) do
    keys = ["port", "certfile", "keyfile", "cacertfile", "handshake_timeout_ms", "peers"]

    with :ok <- exact_keys(map, keys),
         {:ok, port} <- integer(map, "port", 0..65_535, :invalid_tls_port),
         {:ok, certfile} <- required_absolute_file(map, "certfile", :invalid_tls_certfile),
         {:ok, keyfile} <- required_absolute_file(map, "keyfile", :invalid_tls_keyfile),
         {:ok, cacertfile} <- required_absolute_file(map, "cacertfile", :invalid_tls_cacertfile),
         {:ok, handshake} <-
           integer(map, "handshake_timeout_ms", 1..120_000, :invalid_tls_handshake_timeout),
         {:ok, peers} <- peers(map["peers"]),
         {:ok, _authorizer} <- PeerAuthorizer.new(peers) do
      {:ok,
       [
         port: port,
         certfile: certfile,
         keyfile: keyfile,
         cacertfile: cacertfile,
         handshake_timeout: handshake,
         peers: peers
       ]}
    end
  end

  defp tls(_), do: {:error, :invalid_tls_config}

  defp demand(map) when is_map(map) do
    keys = [
      "auto_reconcile",
      "reconcile_interval_ms",
      "offer_ttl_ms",
      "placement_loss_grace_ms",
      "max_new_offers_per_tick",
      "pools"
    ]

    with :ok <- exact_keys(map, keys),
         auto when is_boolean(auto) <- map["auto_reconcile"],
         {:ok, interval} <-
           integer(map, "reconcile_interval_ms", 100..60_000, :invalid_reconcile_interval),
         {:ok, ttl} <- integer(map, "offer_ttl_ms", 1_000..300_000, :invalid_offer_ttl),
         {:ok, loss_grace} <-
           integer(
             map,
             "placement_loss_grace_ms",
             1_000..86_400_000,
             :invalid_placement_loss_grace
           ),
         {:ok, max_new} <- integer(map, "max_new_offers_per_tick", 1..64, :invalid_offer_limit),
         {:ok, policies} <- pools(map["pools"]) do
      {:ok,
       [
         policies: policies,
         scale_set_client: CrfController.ScaleSetClient,
         scheduler_client: CrfController.SchedulerClient,
         auto_reconcile: auto,
         reconcile_interval_ms: interval,
         offer_ttl_ms: ttl,
         placement_loss_grace_ms: loss_grace,
         max_new_offers_per_tick: max_new
       ]}
    else
      nil -> {:error, :invalid_auto_reconcile}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_demand_config}
    end
  end

  defp demand(_), do: {:error, :invalid_demand_config}

  defp pools(values) when is_list(values) and length(values) in 1..8 do
    values
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn value, {:ok, acc, ids} ->
      with {:ok, attrs} <- pool_attrs(value),
           {:ok, policy} <- PoolPolicy.new(attrs),
           false <- MapSet.member?(ids, policy.id) do
        {:cont, {:ok, [policy | acc], MapSet.put(ids, policy.id)}}
      else
        true -> {:halt, {:error, :duplicate_pool_policy}}
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, :invalid_pool_policy}}
      end
    end)
    |> case do
      {:ok, policies, _ids} -> {:ok, Enum.reverse(policies)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pools(_), do: {:error, :invalid_pool_policies}

  defp pool_attrs(map) when is_map(map) do
    keys = [
      "id",
      "max_concurrency",
      "resources",
      "required_os",
      "required_arch",
      "required_backend",
      "required_capabilities",
      "work_folder"
    ]

    with :ok <- exact_keys(map, keys),
         {:ok, resources} <- resources(map["resources"]),
         {:ok, os} <-
           enum(
             map["required_os"],
             %{"linux" => :linux, "windows" => :windows, "macos" => :macos, "other" => :other},
             true
           ),
         {:ok, arch} <-
           enum(
             map["required_arch"],
             %{"x86_64" => :x86_64, "arm64" => :arm64, "other" => :other},
             true
           ),
         {:ok, backend} <-
           enum(
             map["required_backend"],
             %{
               "container" => :container,
               "native_process" => :native_process,
               "virtual_machine" => :virtual_machine
             },
             false
           ) do
      {:ok,
       %{
         id: map["id"],
         max_concurrency: map["max_concurrency"],
         resources: resources,
         required_os: os,
         required_arch: arch,
         required_backend: backend,
         required_capabilities: map["required_capabilities"],
         work_folder: map["work_folder"]
       }}
    end
  end

  defp pool_attrs(_), do: {:error, :invalid_pool_policy}

  defp resources(map) when is_map(map) do
    with :ok <- exact_keys(map, ["cpu_millis", "memory_bytes"]),
         cpu when is_integer(cpu) <- map["cpu_millis"],
         memory when is_integer(memory) <- map["memory_bytes"] do
      {:ok, %{cpu_millis: cpu, memory_bytes: memory}}
    else
      _ -> {:error, :invalid_pool_resources}
    end
  end

  defp resources(_), do: {:error, :invalid_pool_resources}

  defp peers(values) when is_list(values) and length(values) in 1..1024 do
    Enum.reduce_while(values, {:ok, []}, fn peer, {:ok, acc} ->
      with true <- is_map(peer),
           :ok <- exact_keys(peer, ["fingerprint", "node_id"]),
           {:ok, fingerprint} <- fingerprint(peer["fingerprint"]),
           true <- Identifier.valid?(peer["node_id"]) do
        {:cont, {:ok, [{fingerprint, peer["node_id"]} | acc]}}
      else
        _ -> {:halt, {:error, :invalid_tls_peer}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp peers(_), do: {:error, :invalid_tls_peers}

  defp exact_keys(map, keys) when is_map(map) do
    if MapSet.new(Map.keys(map)) == MapSet.new(keys),
      do: :ok,
      else: {:error, :unexpected_controller_config_fields}
  end

  defp required_absolute_path(map, key, error) do
    case map[key] do
      value when is_binary(value) ->
        case absolute_path(value, error) do
          :ok -> {:ok, value}
          other -> other
        end

      _ ->
        {:error, error}
    end
  end

  defp required_absolute_file(map, key, error) do
    with {:ok, path} <- required_absolute_path(map, key, error),
         true <- File.regular?(path) do
      {:ok, path}
    else
      false -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp required_private_file(map, key, error) do
    with {:ok, path} <- required_absolute_path(map, key, error),
         {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and secure_private_file_mode?(stat.mode) do
      {:ok, path}
    else
      false -> {:error, error}
      {:error, _reason} -> {:error, error}
    end
  end

  defp absolute_path(path, error) when is_binary(path),
    do: if(Path.type(path) == :absolute, do: :ok, else: {:error, error})

  defp integer(map, key, range, error) do
    case map[key] do
      value when is_integer(value) -> if(value in range, do: {:ok, value}, else: {:error, error})
      _ -> {:error, error}
    end
  end

  defp identifier(map, key, error) do
    value = map[key]
    if Identifier.valid?(value), do: {:ok, value}, else: {:error, error}
  end

  defp enum(nil, _values, true), do: {:ok, nil}
  defp enum(:null, _values, true), do: {:ok, nil}

  defp enum(value, values, _nullable) do
    case Map.fetch(values, value) do
      {:ok, mapped} -> {:ok, mapped}
      :error -> {:error, :invalid_pool_policy}
    end
  end

  defp revision(value),
    do: if(hex64?(value), do: {:ok, value}, else: {:error, :invalid_scaleset_revision})

  defp fingerprint(value),
    do: if(hex64?(value), do: {:ok, String.downcase(value)}, else: {:error, :invalid_fingerprint})

  defp hex64?(value) when is_binary(value) and byte_size(value) == 64 do
    value
    |> String.downcase()
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp hex64?(_), do: false

  defp decode_json(binary) do
    try do
      case :json.decode(binary) do
        map when is_map(map) -> {:ok, map}
        _ -> {:error, :invalid_controller_config_json}
      end
    rescue
      _ -> {:error, :invalid_controller_config_json}
    catch
      _, _ -> {:error, :invalid_controller_config_json}
    end
  end

  defp secure_private_file_mode?(mode) do
    case :os.type() do
      {:win32, _} -> true
      _ -> (mode &&& 0o777) == 0o600
    end
  end

  defp secure_config_mode?(mode) do
    case :os.type() do
      {:win32, _} -> true
      _ -> (mode &&& 0o077) == 0
    end
  end
end
