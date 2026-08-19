defmodule CrfController.SchedulerClient do
  use GenServer

  alias CrfController.SchedulerWire

  @default_timeout_ms 5_000
  @max_timeout_ms 30_000
  @max_queue 1024

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    genserver_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def schedule(server \\ __MODULE__, requests, nodes, timeout \\ 10_000) do
    GenServer.call(server, {:schedule, requests, nodes}, timeout)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    executable = Keyword.get(opts, :executable)
    timeout_ms = Keyword.get(opts, :request_timeout_ms, @default_timeout_ms)

    with :ok <- validate_executable(executable),
         true <- is_integer(timeout_ms) and timeout_ms in 100..@max_timeout_ms,
         {:ok, port} <- open_port(executable) do
      {:ok,
       %{
         executable: executable,
         port: port,
         timeout_ms: timeout_ms,
         pending: nil,
         queue: :queue.new(),
         sequence: 0
       }}
    else
      false -> {:stop, :invalid_scheduler_timeout}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:schedule, requests, nodes}, from, %{pending: nil} = state) do
    start_request(state, from, requests, nodes)
  end

  def handle_call({:schedule, requests, nodes}, from, state) do
    if :queue.len(state.queue) >= @max_queue do
      {:reply, {:error, :scheduler_queue_full}, state}
    else
      {:noreply, %{state | queue: :queue.in({from, requests, nodes}, state.queue)}}
    end
  end

  @impl true
  def handle_info({port, {:data, payload}}, %{port: port, pending: pending} = state)
      when not is_nil(pending) do
    Process.cancel_timer(pending.timer)
    result = SchedulerWire.decode_response(payload, pending.request_id)
    GenServer.reply(pending.from, result)
    start_next(%{state | pending: nil})
  end

  def handle_info(
        {:scheduler_timeout, request_id},
        %{pending: %{request_id: request_id} = pending} = state
      ) do
    GenServer.reply(pending.from, {:error, :scheduler_timeout})
    state = %{state | pending: nil}
    restart_port_and_continue(state)
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    restart_port_and_continue(%{state | port: nil})
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_request(state, from, requests, nodes) do
    sequence = state.sequence + 1
    request_id = "schedule-#{sequence}"

    case SchedulerWire.encode_request(request_id, requests, nodes) do
      {:ok, payload} ->
        if Port.command(state.port, payload) do
          timer = Process.send_after(self(), {:scheduler_timeout, request_id}, state.timeout_ms)

          pending = %{
            from: from,
            request_id: request_id,
            requests: requests,
            nodes: nodes,
            timer: timer
          }

          {:noreply, %{state | pending: pending, sequence: sequence}}
        else
          {:reply, {:error, :scheduler_unavailable}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp start_next(state) do
    case :queue.out(state.queue) do
      {{:value, {from, requests, nodes}}, queue} ->
        state = %{state | queue: queue}

        case start_request(state, from, requests, nodes) do
          {:noreply, state} ->
            {:noreply, state}

          {:reply, reply, state} ->
            GenServer.reply(from, reply)
            start_next(state)
        end

      {:empty, queue} ->
        {:noreply, %{state | queue: queue}}
    end
  end

  defp restart_port_and_continue(state) do
    if state.pending do
      Process.cancel_timer(state.pending.timer)

      state = %{
        state
        | queue:
            :queue.in_r(
              {state.pending.from, state.pending.requests, state.pending.nodes},
              state.queue
            ),
          pending: nil
      }

      reopen(state)
    else
      reopen(state)
    end
  end

  defp reopen(state) do
    if is_port(state.port) do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end

    case open_port(state.executable) do
      {:ok, port} ->
        start_next(%{state | port: port})

      {:error, reason} ->
        fail_all(state, reason)
        {:stop, reason, %{state | port: nil, pending: nil, queue: :queue.new()}}
    end
  end

  defp fail_all(state, reason) do
    if state.pending, do: GenServer.reply(state.pending.from, {:error, reason})

    state.queue
    |> :queue.to_list()
    |> Enum.each(fn {from, _requests, _nodes} -> GenServer.reply(from, {:error, reason}) end)
  end

  defp open_port(executable) do
    try do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [:binary, :exit_status, :use_stdio, {:packet, 4}]
        )

      {:ok, port}
    rescue
      _ -> {:error, :scheduler_start_failed}
    catch
      _, _ -> {:error, :scheduler_start_failed}
    end
  end

  defp validate_executable(executable) when is_binary(executable) do
    cond do
      Path.type(executable) != :absolute -> {:error, :invalid_scheduler_executable}
      not File.regular?(executable) -> {:error, :invalid_scheduler_executable}
      true -> :ok
    end
  end

  defp validate_executable(_), do: {:error, :invalid_scheduler_executable}
end
