defmodule CrfController.NodeCommand do
  alias CrfController.{Identifier, Placement, Resources, Secret}

  @protocol_version 1
  @max_ttl_ms 5 * 60 * 1000
  @max_wire_message_bytes 256 * 1024
  @backends [:container, :native_process, :virtual_machine]

  @enforce_keys [
    :protocol_version,
    :command_id,
    :idempotency_key,
    :node_id,
    :node_generation,
    :issued_at_unix_ms,
    :expires_at_unix_ms,
    :payload
  ]
  defstruct @enforce_keys

  @type payload ::
          {:start_placement, String.t(), String.t(), String.t(), String.t(), Resources.t(),
           atom(), Secret.t()}
          | {:cancel_placement, String.t()}
          | {:set_drain, boolean()}

  @type t :: %__MODULE__{
          protocol_version: pos_integer(),
          command_id: String.t(),
          idempotency_key: String.t(),
          node_id: String.t(),
          node_generation: pos_integer(),
          issued_at_unix_ms: pos_integer(),
          expires_at_unix_ms: pos_integer(),
          payload: payload()
        }

  @spec start_placement(
          Placement.t(),
          String.t(),
          atom(),
          Secret.t(),
          pos_integer(),
          pos_integer()
        ) ::
          {:ok, t()} | {:error, atom()}
  def start_placement(
        %Placement{} = placement,
        runner_name,
        execution_backend,
        %Secret{} = jit_config,
        issued_at_unix_ms,
        expires_at_unix_ms
      ) do
    with :ok <- valid_identifier(runner_name, :invalid_runner_name),
         true <- execution_backend in @backends,
         :ok <- valid_lifetime(issued_at_unix_ms, expires_at_unix_ms) do
      {:ok,
       %__MODULE__{
         protocol_version: @protocol_version,
         command_id: placement.command_id,
         idempotency_key: placement.idempotency_key,
         node_id: placement.node_id,
         node_generation: placement.node_generation,
         issued_at_unix_ms: issued_at_unix_ms,
         expires_at_unix_ms: expires_at_unix_ms,
         payload:
           {:start_placement, placement.id, placement.work_id, placement.pool_id, runner_name,
            placement.resources, execution_backend, jit_config}
       }}
    else
      false -> {:error, :invalid_execution_backend}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cancel_placement(Placement.t(), String.t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, t()} | {:error, atom()}
  def cancel_placement(
        %Placement{} = placement,
        command_id,
        idempotency_key,
        issued_at_unix_ms,
        expires_at_unix_ms
      ) do
    with :ok <- valid_identifier(command_id, :invalid_command_id),
         :ok <- valid_identifier(idempotency_key, :invalid_idempotency_key),
         :ok <- valid_lifetime(issued_at_unix_ms, expires_at_unix_ms) do
      {:ok,
       %__MODULE__{
         protocol_version: @protocol_version,
         command_id: command_id,
         idempotency_key: idempotency_key,
         node_id: placement.node_id,
         node_generation: placement.node_generation,
         issued_at_unix_ms: issued_at_unix_ms,
         expires_at_unix_ms: expires_at_unix_ms,
         payload: {:cancel_placement, placement.id}
       }}
    end
  end

  @spec set_drain(
          String.t(),
          pos_integer(),
          String.t(),
          String.t(),
          boolean(),
          pos_integer(),
          pos_integer()
        ) ::
          {:ok, t()} | {:error, atom()}
  def set_drain(
        node_id,
        node_generation,
        command_id,
        idempotency_key,
        draining,
        issued_at_unix_ms,
        expires_at_unix_ms
      ) do
    with :ok <- valid_identifier(node_id, :invalid_node_id),
         true <- is_integer(node_generation) and node_generation > 0,
         :ok <- valid_identifier(command_id, :invalid_command_id),
         :ok <- valid_identifier(idempotency_key, :invalid_idempotency_key),
         true <- is_boolean(draining),
         :ok <- valid_lifetime(issued_at_unix_ms, expires_at_unix_ms) do
      {:ok,
       %__MODULE__{
         protocol_version: @protocol_version,
         command_id: command_id,
         idempotency_key: idempotency_key,
         node_id: node_id,
         node_generation: node_generation,
         issued_at_unix_ms: issued_at_unix_ms,
         expires_at_unix_ms: expires_at_unix_ms,
         payload: {:set_drain, draining}
       }}
    else
      false -> {:error, :invalid_command}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec encode(t(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def encode(%__MODULE__{} = command, now_unix_ms)
      when is_integer(now_unix_ms) and now_unix_ms >= 0 do
    with {:ok, wire_map} <- wire_map(command, now_unix_ms) do
      encoded = wire_map |> :json.encode() |> IO.iodata_to_binary()

      if byte_size(encoded) <= @max_wire_message_bytes,
        do: {:ok, encoded},
        else: {:error, :message_too_large}
    end
  end

  def encode(_, _), do: {:error, :invalid_command}

  @spec wire_map(t(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def wire_map(%__MODULE__{} = command, now_unix_ms) do
    with :ok <- validate(command, now_unix_ms), do: {:ok, do_wire_map(command)}
  end

  @spec validate(t(), non_neg_integer()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = command, now_unix_ms) do
    with true <- command.protocol_version == @protocol_version,
         :ok <- valid_identifier(command.command_id, :invalid_command_id),
         :ok <- valid_identifier(command.idempotency_key, :invalid_idempotency_key),
         :ok <- valid_identifier(command.node_id, :invalid_node_id),
         true <- is_integer(command.node_generation) and command.node_generation > 0,
         :ok <- valid_lifetime(command.issued_at_unix_ms, command.expires_at_unix_ms),
         true <- now_unix_ms <= command.expires_at_unix_ms,
         :ok <- valid_payload(command.payload) do
      :ok
    else
      false -> {:error, :invalid_or_expired_command}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_payload(
         {:start_placement, placement_id, work_id, pool_id, runner_name, %Resources{} = resources,
          backend, %Secret{}}
       ) do
    with :ok <- valid_identifier(placement_id, :invalid_placement_id),
         :ok <- valid_identifier(work_id, :invalid_work_id),
         :ok <- valid_identifier(pool_id, :invalid_pool_id),
         :ok <- valid_identifier(runner_name, :invalid_runner_name),
         true <- resources.cpu_millis > 0 and resources.memory_bytes > 0,
         true <- backend in @backends do
      :ok
    else
      false -> {:error, :invalid_start_placement}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_payload({:cancel_placement, placement_id}),
    do: valid_identifier(placement_id, :invalid_placement_id)

  defp valid_payload({:set_drain, draining}) when is_boolean(draining), do: :ok
  defp valid_payload(_), do: {:error, :invalid_payload}

  defp do_wire_map(%__MODULE__{} = command) do
    %{
      "protocol_version" => command.protocol_version,
      "command_id" => command.command_id,
      "idempotency_key" => command.idempotency_key,
      "node_id" => command.node_id,
      "node_generation" => command.node_generation,
      "issued_at_unix_ms" => command.issued_at_unix_ms,
      "expires_at_unix_ms" => command.expires_at_unix_ms,
      "payload" => payload_map(command.payload)
    }
  end

  defp payload_map(
         {:start_placement, placement_id, work_id, pool_id, runner_name, resources, backend,
          jit_config}
       ) do
    %{
      "type" => "start_placement",
      "placement_id" => placement_id,
      "work_id" => work_id,
      "pool_id" => pool_id,
      "runner_name" => runner_name,
      "resources" => %{
        "cpu_millis" => resources.cpu_millis,
        "memory_bytes" => resources.memory_bytes
      },
      "execution_backend" => Atom.to_string(backend),
      "jit_config" => Secret.expose(jit_config)
    }
  end

  defp payload_map({:cancel_placement, placement_id}) do
    %{"type" => "cancel_placement", "placement_id" => placement_id}
  end

  defp payload_map({:set_drain, draining}) do
    %{"type" => "set_drain", "draining" => draining}
  end

  defp valid_lifetime(issued_at_unix_ms, expires_at_unix_ms)
       when is_integer(issued_at_unix_ms) and issued_at_unix_ms > 0 and
              is_integer(expires_at_unix_ms) and expires_at_unix_ms >= issued_at_unix_ms and
              expires_at_unix_ms - issued_at_unix_ms <= @max_ttl_ms,
       do: :ok

  defp valid_lifetime(_, _), do: {:error, :invalid_command_lifetime}

  defp valid_identifier(value, error) do
    if Identifier.valid?(value), do: :ok, else: {:error, error}
  end
end
