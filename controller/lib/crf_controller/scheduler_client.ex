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
         queued: %{},
         sequence: 0
       }}
    else
      false -> {:stop, :invalid_scheduler_timeout}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:schedule, requests, nodes}, from, %{pending: nil} = state) do
    entry = new_entry(from, requests, nodes, state.timeout_ms)
    start_request(state, entry)
  end

  def handle_call({:schedule, requests, nodes}, from, state) do
    if map_size(state.queued) >= @max_queue do
      {:reply, {:error, :scheduler_queue_full}, state}
    else
      entry = new_entry(from, requests, nodes, state.timeout_ms)

      {:noreply,
       %{
         state
         | queue: :queue.in(entry.id, state.queue),
           queued: Map.put(state.queued, entry.id, entry)
       }}
    end
  end

  @impl true
  def handle_info({port, {:data, payload}}, %{port: port, pending: pending} = state)
      when not is_nil(pending) do
    Process.cancel_timer(pending.timer)
    result = SchedulerWire.decode_response(payload, pending.request_id)
    GenServer.reply(pending.from, result)
    drop_monitor(pending)
    start_next(%{state | pending: nil})
  end

  def handle_info(
        {:scheduler_timeout, request_id},
        %{pending: %{request_id: request_id} = pending} = state
      ) do
    GenServer.reply(pending.from, {:error, :scheduler_timeout})
    drop_monitor(pending)
    state = %{state | pending: nil}
    restart_port_and_continue(state)
  end

  def handle_info({:queue_expired, entry_id}, state) do
    case Map.pop(state.queued, entry_id) do
      {nil, _queued} ->
        {:noreply, state}

      {entry, queued} ->
        GenServer.reply(entry.from, {:error, :scheduler_queue_timeout})
        drop_monitor(entry)
        {:noreply, %{state | queued: queued}}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    cond do
      state.pending && state.pending.monitor == monitor ->
        Process.cancel_timer(state.pending.timer)
        restart_port_and_continue(%{state | pending: nil})

      true ->
        queued =
          Map.reject(state.queued, fn {_id, entry} ->
            if entry.monitor == monitor, do: Process.cancel_timer(entry.expiry_timer)
            entry.monitor == monitor
          end)

        {:noreply, %{state | queued: queued}}
    end
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

  defp start_request(state, entry) do
    sequence = state.sequence + 1
    request_id = "schedule-#{sequence}"

    case SchedulerWire.encode_request(request_id, entry.requests, entry.nodes) do
      {:ok, payload} ->
        if Port.command(state.port, payload) do
          if entry.expiry_timer, do: Process.cancel_timer(entry.expiry_timer)
          timer = Process.send_after(self(), {:scheduler_timeout, request_id}, state.timeout_ms)

          pending = Map.merge(entry, %{request_id: request_id, timer: timer, expiry_timer: nil})

          {:noreply, %{state | pending: pending, sequence: sequence}}
        else
          drop_monitor(entry)
          {:reply, {:error, :scheduler_unavailable}, state}
        end

      {:error, reason} ->
        drop_monitor(entry)
        {:reply, {:error, reason}, state}
    end
  end

  defp start_next(state) do
    case :queue.out(state.queue) do
      {{:value, entry_id}, queue} ->
        case Map.pop(state.queued, entry_id) do
          {nil, queued} ->
            start_next(%{state | queue: queue, queued: queued})

          {entry, queued} ->
            state = %{state | queue: queue, queued: queued}

            if System.monotonic_time(:millisecond) >= entry.deadline_ms or
                 not Process.alive?(entry.caller) do
              GenServer.reply(entry.from, {:error, :scheduler_queue_timeout})
              drop_monitor(entry)
              start_next(state)
            else
              case start_request(state, entry) do
                {:noreply, state} ->
                  {:noreply, state}

                {:reply, reply, state} ->
                  GenServer.reply(entry.from, reply)
                  start_next(state)
              end
            end
        end

      {:empty, queue} ->
        {:noreply, %{state | queue: queue}}
    end
  end

  defp restart_port_and_continue(state) do
    state =
      if state.pending do
        Process.cancel_timer(state.pending.timer)
        entry = Map.drop(state.pending, [:request_id, :timer])
        remaining = max(entry.deadline_ms - System.monotonic_time(:millisecond), 0)
        expiry_timer = Process.send_after(self(), {:queue_expired, entry.id}, remaining)
        entry = %{entry | expiry_timer: expiry_timer}

        %{
          state
          | pending: nil,
            queue: :queue.in_r(entry.id, state.queue),
            queued: Map.put(state.queued, entry.id, entry)
        }
      else
        state
      end

    reopen(state)
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
        {:stop, reason, %{state | port: nil, pending: nil, queue: :queue.new(), queued: %{}}}
    end
  end

  defp fail_all(state, reason) do
    if state.pending do
      GenServer.reply(state.pending.from, {:error, reason})
      drop_monitor(state.pending)
    end

    state.queue
    |> :queue.to_list()
    |> Enum.each(fn entry_id ->
      if entry = state.queued[entry_id] do
        GenServer.reply(entry.from, {:error, reason})
        drop_monitor(entry)
      end
    end)
  end

  defp new_entry({caller, _tag} = from, requests, nodes, timeout_ms) do
    id = make_ref()

    %{
      id: id,
      from: from,
      caller: caller,
      monitor: Process.monitor(caller),
      requests: requests,
      nodes: nodes,
      deadline_ms: System.monotonic_time(:millisecond) + timeout_ms,
      expiry_timer: Process.send_after(self(), {:queue_expired, id}, timeout_ms)
    }
  end

  defp drop_monitor(entry) do
    if entry[:expiry_timer], do: Process.cancel_timer(entry.expiry_timer)
    Process.demonitor(entry.monitor, [:flush])
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
