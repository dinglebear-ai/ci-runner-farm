defmodule CrfController.ScaleSetSidecar do
  use GenServer

  require Logger

  @default_startup_timeout_ms 15_000
  @max_startup_timeout_ms 120_000
  @shutdown_timeout_ms 2_000
  @diagnostic_tail_bytes 4_096
  @diagnostic_buffer_bytes @diagnostic_tail_bytes * 2

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
         {:ok, output_bytes, diagnostic_buffer} <-
           wait_ready(port, socket_path, startup_timeout_ms) do
      {:ok,
       %{
         port: port,
         socket_path: socket_path,
         output_bytes: output_bytes,
         diagnostic_buffer: diagnostic_buffer,
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
       diagnostic_tail: bounded_diagnostic_tail(state.diagnostic_buffer),
       started_at_ms: state.started_at_ms
     }, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    diagnostic_buffer =
      take_binary_tail(state.diagnostic_buffer <> data, @diagnostic_buffer_bytes)

    {:noreply,
     %{
       state
       | output_bytes: state.output_bytes + byte_size(data),
         diagnostic_buffer: diagnostic_buffer
     }}
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
    report_cleanup(stop_port(state.port))
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
    wait_ready_until(port, socket_path, deadline, 0, "")
  end

  defp wait_ready_until(port, socket_path, deadline, output_bytes, diagnostic_buffer) do
    cond do
      is_nil(Port.info(port)) ->
        {:error, :scaleset_sidecar_exited}

      File.exists?(socket_path) ->
        {:ok, output_bytes, diagnostic_buffer}

      System.monotonic_time(:millisecond) >= deadline ->
        report_cleanup(stop_port(port))
        {:error, :scaleset_sidecar_start_timeout}

      true ->
        receive do
          {^port, {:data, data}} ->
            wait_ready_until(
              port,
              socket_path,
              deadline,
              output_bytes + byte_size(data),
              take_binary_tail(diagnostic_buffer <> data, @diagnostic_buffer_bytes)
            )

          {^port, {:exit_status, status}} ->
            {:error, {:scaleset_sidecar_exit, status}}

          {:EXIT, ^port, reason} ->
            {:error, {:scaleset_sidecar_port_exit, reason}}
        after
          20 -> wait_ready_until(port, socket_path, deadline, output_bytes, diagnostic_buffer)
        end
    end
  end

  defp stop_port(port) do
    failures =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          failures = record_failure([], :term, signal_process(pid, "-TERM"))

          case wait_port_exit(port, System.monotonic_time(:millisecond) + @shutdown_timeout_ms) do
            :ok ->
              failures

            :timeout ->
              failures
              |> record_failure(:kill, signal_process(pid, "-KILL"))
              |> record_failure(
                :final_wait,
                wait_port_exit(port, System.monotonic_time(:millisecond) + 500)
              )
          end

        nil ->
          []
      end

    failures = record_failure(failures, :port_close, close_port(port))
    if failures == [], do: :ok, else: {:error, Enum.reverse(failures)}
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
    _ -> {:error, :port_close_failed}
  catch
    _, _ -> {:error, :port_close_failed}
  end

  defp record_failure(failures, _operation, :ok), do: failures
  defp record_failure(failures, operation, reason), do: [{operation, reason} | failures]

  defp report_cleanup(:ok), do: :ok

  defp report_cleanup({:error, failures}) do
    Logger.warning("scale-set sidecar cleanup failed: #{inspect(failures)}")
  end

  defp bounded_diagnostic_tail(output) do
    output
    |> String.replace_invalid("")
    |> redact_diagnostics()
    |> take_binary_tail(@diagnostic_tail_bytes)
  end

  defp redact_diagnostics(output) do
    output
    |> String.replace(~r/(?i)\bBearer\s+[^\s]+/, "Bearer [REDACTED]")
    |> String.replace(~r/\b(?:gh[opusr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)\b/, "[REDACTED]")
    |> String.replace(
      ~r/(?i)\b(token|authorization|jit(?:_config)?)\s*[:=]\s*[^\s]+/,
      "\\1=[REDACTED]"
    )
  end

  defp take_binary_tail(output, max_bytes) when byte_size(output) <= max_bytes, do: output

  defp take_binary_tail(output, max_bytes) do
    offset = byte_size(output) - max_bytes

    case output do
      <<_::binary-size(^offset), tail::binary>> -> tail
    end
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
