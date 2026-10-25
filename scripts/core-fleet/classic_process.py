"""Original-child cancellation primitive; not a classic capability advertisement.

Only the existing transport owner retains this object. No disk PID is accepted,
no new process is adopted, and no numeric-PID signal fallback is allowed. Workload
cleanup/release remains the existing Farm protected owner and ledger's job.
"""
import os
import re
import signal
import threading


class OwnedProcess:
    def __init__(self, process, operation_id):
        if not isinstance(operation_id, str) or not re.fullmatch('[0-9a-f]{32}', operation_id):
            raise ValueError('CLASSIC_OPERATION_ID_INVALID')
        if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
            raise ValueError('CLASSIC_PIDFD_REQUIRED')
        self.process = process
        self.operation_id = operation_id
        self.lock = threading.Lock()
        self.closed = False
        self.cancel_sent = False
        self.descriptor = None
        # A Popen child has not been reaped elsewhere and cannot have its PID
        # reused while it remains our unreaped child. Already-reaped termination
        # is classified without opening or signalling a replacement process.
        if process.poll() is None:
            try:
                self.descriptor = os.pidfd_open(process.pid, 0)
            except ProcessLookupError:
                if process.poll() is None:
                    raise ValueError('CLASSIC_PIDFD_ACQUISITION_UNCERTAIN') from None

    def cancel(self, operation_id):
        with self.lock:
            if self.closed:
                raise ValueError('CLASSIC_PIDFD_OWNER_CLOSED')
            if operation_id != self.operation_id:
                raise ValueError('CLASSIC_OPERATION_OWNER_MISMATCH')
            if self.cancel_sent or self.process.poll() is not None:
                return False
            if self.descriptor is None:
                raise ValueError('CLASSIC_PIDFD_ACQUISITION_UNCERTAIN')
            try:
                signal.pidfd_send_signal(self.descriptor, signal.SIGTERM, None, 0)
            except ProcessLookupError:
                if self.process.poll() is None:
                    raise ValueError('CLASSIC_PIDFD_SIGNAL_UNCERTAIN') from None
                return False
            self.cancel_sent = True
            return True

    def close(self):
        with self.lock:
            if self.closed:
                return
            self.closed = True
            if self.descriptor is not None:
                os.close(self.descriptor)
                self.descriptor = None

def settle_child(process, owner, timeout):
    """Reap the original Popen child before closing its pipes/pidfd.

    None is reserved for the explicit continuing settlement owner. A bounded
    caller must retain that real owner if this function reports False.
    """
    import selectors
    import time
    if process.stdin is not None and not process.stdin.closed:
        try:
            process.stdin.close()
        except BrokenPipeError:
            pass
    deadline = None if timeout is None else time.monotonic() + timeout
    with selectors.DefaultSelector() as poll:
        for stream in (process.stdout, process.stderr):
            if stream is not None and not stream.closed:
                poll.register(stream, selectors.EVENT_READ)
        while process.poll() is None:
            if deadline is not None and time.monotonic() >= deadline:
                return False
            wait = .05 if deadline is None else min(.05, max(0, deadline-time.monotonic()))
            for key, _ in poll.select(wait):
                try:
                    data = os.read(key.fileobj.fileno(), 65536)
                except (OSError, ValueError):
                    poll.unregister(key.fileobj)
                    continue
                if not data:
                    poll.unregister(key.fileobj)
    process.wait()  # Terminal original child only; never adopt a stored PID.
    for stream in (process.stdin, process.stdout, process.stderr):
        if stream is not None and not stream.closed:
            stream.close()
    if owner is not None:
        owner.close()
    return True


class RetainedSettlement:
    """Continuing custody of one already-launched child, not a new daemon.

    The non-daemon thread retains the original Popen/pidfd and keeps this owner
    process alive until the actual child exits. It performs no new launch,
    repeated signal, workload action, queue mutation or capacity release.
    """
    def __init__(self, process, owner):
        self.process, self.owner = process, owner
        self.finished = threading.Event()
        self.observation_failed = threading.Event()
        self.failure = None
        self.thread = threading.Thread(target=self._settle, name='farm-classic-settlement', daemon=False)
        self.thread.start()

    def _settle(self):
        # An observation failure must not discard the only original Popen/pidfd
        # owner or masquerade as terminal cleanup. Keep custody, record the
        # failure, and retry only read/drain/reap observation with backoff.
        import time
        while True:
            try:
                if settle_child(self.process, self.owner, 1):
                    self.finished.set()
                    return
            except Exception as error:
                self.failure = type(error).__name__
                self.observation_failed.set()
                time.sleep(.1)
