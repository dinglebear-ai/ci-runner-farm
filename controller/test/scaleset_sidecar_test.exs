defmodule CrfController.ScaleSetSidecarTest do
  use ExUnit.Case, async: false

  alias CrfController.ScaleSetSidecar

  test "managed sidecar publishes its socket and terminates with its OTP owner" do
    if elem(:os.type(), 0) == :win32 do
      assert true
    else
      root = Path.join(System.tmp_dir!(), "crf-sidecar-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      executable = Path.join(root, "fake-sidecar.py")
      socket_path = Path.join(root, "control.sock")
      runtime = sealed(root, "runtime.json")
      compatibility = sealed(root, "compatibility.json")

      File.write!(executable, fake_sidecar())
      File.chmod!(executable, 0o700)

      {:ok, sidecar} =
        ScaleSetSidecar.start_link(
          name: nil,
          executable: executable,
          socket_path: socket_path,
          runtime_config: runtime,
          compatibility: compatibility,
          startup_timeout_ms: 5_000
        )

      status = ScaleSetSidecar.status(sidecar)
      assert status.ready
      assert is_integer(status.os_pid) and status.os_pid > 0
      assert File.exists?(socket_path)

      Process.unlink(sidecar)
      :ok = GenServer.stop(sidecar, :normal, 5_000)
      assert wait_until(fn -> not File.exists?(socket_path) end, 2_000)

      File.rm_rf!(root)
    end
  end

  defp sealed(root, name) do
    path = Path.join(root, name)
    File.write!(path, "fixture")
    File.chmod!(path, 0o600)
    path
  end

  defp wait_until(predicate, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(predicate, deadline)
  end

  defp do_wait(predicate, deadline) do
    cond do
      predicate.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        do_wait(predicate, deadline)
    end
  end

  defp fake_sidecar do
    ~S"""
    #!/usr/bin/env python3
    import os
    import signal
    import socket
    import sys
    import time

    args = sys.argv[1:]
    path = args[args.index("--socket") + 1]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    os.chmod(path, 0o600)
    server.listen(1)
    running = True

    def stop(_signum, _frame):
        global running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print("ready", flush=True)
    while running:
        time.sleep(0.02)

    server.close()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    """
  end
end
