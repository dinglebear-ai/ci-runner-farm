defmodule CrfController.ScaleSetSidecar do
  use GenServer

  @default_startup_timeout_ms 15_000
  @max_startup_timeout_ms 120_000
  @shutdown_timeout_ms 2_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    executable = Keyword.get(opts, :executable)
    socket_path = Keyword.get(opts, :socket_path)
    runtime_config = Keyword.get(opts, :runtime_config)
    compatibility = Keyword.get(opts, :compatibility)
    startup_timeout_ms = Keyword.get(opts, :startup_timeout_ms, @default_startup_timeout_ms)

    with :ok <- supported_platform(),
         :ok <- regular_absolute(executable, :invalid_scaleset_sidecar_executable),
         :ok <- absolute(socket_path, :invalid_scaleset_socket),
         :ok <- regular_absolute(runtime_config, :invalid_scaleset_runtime_config),
         :ok <- regular_absolute(compatibility, :invalid_scaleset_compatibility),
         true <-
           is_integer(startup_timeout_ms) and startup_timeout_ms in 100..@max_startup_timeout_ms,
         {:ok, port} <- open_sidecar(executable, socket_path, compatibility, runtime_config),
         :ok <- wait_ready(port, socket_path, startup_timeout_ms) do
      {:ok,
       %{
         port: port,
         socket_path: socket_path,
         output_bytes: 0,
         started_at_ms: System.monotonic_time(:millisecond)
       }}
    else
      false -> {:stop, :invalid_scaleset_sidecar_timeout}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    os_pid =
      case Port.info(state.port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    {:reply,
     %{
       ready: File.exists?(state.socket_path) and not is_nil(Port.info(state.port)),
       os_pid: os_pid,
       output_bytes: state.output_bytes,
       started_at_ms: state.started_at_ms
     }, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    {:noreply, %{state | output_bytes: state.output_bytes + byte_size(data)}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:scaleset_sidecar_exit, status}, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:stop, {:scaleset_sidecar_port_exit, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_port(state.port)
    :ok
  end

  defp open_sidecar(executable, socket_path, compatibility, runtime_config) do
    args = [
      "supervise",
      "--socket",
      socket_path,
      "--compatibility",
      compatibility,
      "--runtime-config",
      runtime_config
    ]

    try do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(args, &String.to_charlist/1)
          ]
        )

      {:ok, port}
    rescue
      _ -> {:error, :scaleset_sidecar_start_failed}
    catch
      _, _ -> {:error, :scaleset_sidecar_start_failed}
    end
  end

  defp wait_ready(port, socket_path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_ready_until(port, socket_path, deadline)
  end

  defp wait_ready_until(port, socket_path, deadline) do
    cond do
      is_nil(Port.info(port)) ->
        {:error, :scaleset_sidecar_exited}

      File.exists?(socket_path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        stop_port(port)
        {:error, :scaleset_sidecar_start_timeout}

      true ->
        receive do
          {^port, {:data, _data}} -> wait_ready_until(port, socket_path, deadline)
          {^port, {:exit_status, status}} -> {:error, {:scaleset_sidecar_exit, status}}
          {:EXIT, ^port, reason} -> {:error, {:scaleset_sidecar_port_exit, reason}}
        after
          20 -> wait_ready_until(port, socket_path, deadline)
        end
    end
  end

  defp stop_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        _ = signal_process(pid, "-TERM")

        case wait_port_exit(port, System.monotonic_time(:millisecond) + @shutdown_timeout_ms) do
          :ok ->
            :ok

          :timeout ->
            _ = signal_process(pid, "-KILL")
            _ = wait_port_exit(port, System.monotonic_time(:millisecond) + 500)
        end

      nil ->
        :ok
    end

    close_port(port)
  end

  defp wait_port_exit(port, deadline) do
    cond do
      is_nil(Port.info(port)) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        receive do
          {^port, {:exit_status, _status}} -> :ok
          {:EXIT, ^port, _reason} -> :ok
          {^port, {:data, _data}} -> wait_port_exit(port, deadline)
        after
          20 -> wait_port_exit(port, deadline)
        end
    end
  end

  defp signal_process(pid, signal) when is_integer(pid) and pid > 0 do
    case System.find_executable("kill") do
      nil ->
        {:error, :kill_command_unavailable}

      executable ->
        try do
          case System.cmd(executable, [signal, Integer.to_string(pid)], stderr_to_stdout: true) do
            {_output, 0} -> :ok
            {_output, _status} -> {:error, :process_signal_failed}
          end
        rescue
          _ -> {:error, :process_signal_failed}
        catch
          _, _ -> {:error, :process_signal_failed}
        end
    end
  end

  defp close_port(port) do
    if not is_nil(Port.info(port)), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp regular_absolute(path, error) do
    with :ok <- absolute(path, error),
         true <- File.regular?(path) do
      :ok
    else
      false -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp absolute(path, error) when is_binary(path),
    do: if(Path.type(path) == :absolute, do: :ok, else: {:error, error})

  defp absolute(_path, error), do: {:error, error}

  defp supported_platform do
    case :os.type() do
      {:win32, _} -> {:error, :scaleset_sidecar_requires_unix}
      _ -> :ok
    end
  end
end
