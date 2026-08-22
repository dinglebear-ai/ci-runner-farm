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

      assert wait_until(fn -> ScaleSetSidecar.status(sidecar).output_bytes > 4_096 end, 2_000)
      status = ScaleSetSidecar.status(sidecar)
      assert status.ready
      assert is_integer(status.os_pid) and status.os_pid > 0
      assert File.exists?(socket_path)
      assert status.output_bytes > 4_096
      assert byte_size(status.diagnostic_tail) <= 4_096
      assert status.diagnostic_tail =~ "sidecar diagnostic"
      assert status.diagnostic_tail =~ "Bearer [REDACTED]"
      refute status.diagnostic_tail =~ "super-secret-token"
      refute status.diagnostic_tail =~ "github_pat_"

      Process.unlink(sidecar)
      :ok = GenServer.stop(sidecar, :normal, 5_000)
      assert wait_until(fn -> not File.exists?(socket_path) end, 2_000)

      File.rm_rf!(root)
    end
  end

  test "managed sidecar escalates from TERM to KILL for an uncooperative child" do
    if elem(:os.type(), 0) == :win32 do
      assert true
    else
      root =
        Path.join(System.tmp_dir!(), "crf-sidecar-stubborn-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      executable = Path.join(root, "fake-sidecar.py")
      socket_path = Path.join(root, "control.sock")
      runtime = sealed(root, "runtime.json")
      compatibility = sealed(root, "compatibility.json")

      File.write!(executable, stubborn_sidecar())
      File.chmod!(executable, 0o700)

      {:ok, sidecar} =
        ScaleSetSidecar.start_link(
          name: nil,
          executable: executable,
          socket_path: socket_path,
          runtime_config: runtime,
          compatibility: compatibility,
          startup_timeout_ms: 5_000,
          shutdown_timeout_ms: 100
        )

      %{os_pid: os_pid} = ScaleSetSidecar.status(sidecar)
      Process.unlink(sidecar)
      :ok = GenServer.stop(sidecar, :normal, 5_000)

      kill = System.find_executable("kill")
      assert {_output, status} = System.cmd(kill, ["-0", Integer.to_string(os_pid)])
      assert status != 0
      File.rm_rf!(root)
    end
  end

  test "managed sidecar allows session cleanup beyond the former two-second boundary" do
    if elem(:os.type(), 0) == :win32 do
      assert true
    else
      root =
        Path.join(System.tmp_dir!(), "crf-sidecar-cleanup-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      executable = Path.join(root, "fake-sidecar.py")
      socket_path = Path.join(root, "control.sock")
      cleanup_path = Path.join(root, "sessions-closed")
      runtime = sealed(root, "runtime.json")
      compatibility = sealed(root, "compatibility.json")

      File.write!(executable, delayed_cleanup_sidecar())
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

      %{os_pid: os_pid} = ScaleSetSidecar.status(sidecar)
      Process.unlink(sidecar)
      started_at = System.monotonic_time(:millisecond)
      :ok = GenServer.stop(sidecar, :normal, 10_000)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert elapsed_ms >= 2_500
      assert elapsed_ms < 15_000
      assert File.read!(cleanup_path) == "all sessions closed\n"

      kill = System.find_executable("kill")
      assert {_output, status} = System.cmd(kill, ["-0", Integer.to_string(os_pid)])
      assert status != 0
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
    print("x" * 5000, flush=True)
    print("Bearer super-secret-token", flush=True)
    print("token=github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", flush=True)
    print("sidecar diagnostic", flush=True)
    while running:
        time.sleep(0.02)

    server.close()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    """
  end

  defp stubborn_sidecar do
    String.replace(
      fake_sidecar(),
      "signal.signal(signal.SIGTERM, stop)",
      "signal.signal(signal.SIGTERM, signal.SIG_IGN)"
    )
  end

  defp delayed_cleanup_sidecar do
    ~S"""
    #!/usr/bin/env python3
    import os
    import signal
    import socket
    import sys
    import time

    args = sys.argv[1:]
    path = args[args.index("--socket") + 1]
    cleanup_path = args[args.index("--runtime-config") + 1].replace("runtime.json", "sessions-closed")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    os.chmod(path, 0o600)
    server.listen(1)

    def stop(_signum, _frame):
        time.sleep(2.5)
        with open(cleanup_path, "w") as marker:
            marker.write("all sessions closed\n")
        server.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    while True:
        time.sleep(0.02)
    """
  end
end
