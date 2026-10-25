"""Explicit classic Farm adapter for the existing coordinator, never UDS failover.

The existing shell/Go owner keeps FD8 and the capacity ledger. This module only
binds synchronous operation receipts to coordinator phases and cancellation.
"""
import json
import os
from pathlib import Path
import subprocess
import selectors
import signal
import time
from classic_process import OwnedProcess, RetainedSettlement, settle_child
import uuid
import fcntl

from classic_transport import (CAPACITY, WRAPPER, canonical, exclusive,
                               file_digest, private_read, protected_operation)


def read_capabilities():
    # Finite capture while the trusted read-only helper executes, not a size
    # check after unbounded communicate() allocation.
    if not hasattr(os,'pidfd_open') or not hasattr(signal,'pidfd_send_signal'):raise ValueError('CLASSIC_PIDFD_REQUIRED')
    process=subprocess.Popen([str(CAPACITY),'local-checks-readiness'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                             env={'PATH':os.environ.get('PATH',''),'HOME':'/nonexistent'})
    custody=None;raw=bytearray();deadline=time.monotonic()+12
    try:
        custody=OwnedProcess(process,uuid.uuid4().hex)
        with selectors.DefaultSelector() as poll:
            poll.register(process.stdout,selectors.EVENT_READ)
            while poll.get_map() or process.poll() is None:
                if time.monotonic()>=deadline:raise ValueError('CLASSIC_READINESS_TIMEOUT')
                for key,_ in poll.select(.05):
                    block=os.read(key.fileobj.fileno(),65536)
                    if not block:poll.unregister(key.fileobj);continue
                    if len(raw)+len(block)>1048576:raise ValueError('CLASSIC_READINESS_BOUND')
                    raw.extend(block)
        if process.wait()!=0:raise ValueError('CLASSIC_READINESS_UNAVAILABLE')
        return json.loads(raw)
    finally:
        if custody is not None and process.poll() is None:custody.cancel(custody.operation_id)
        if not settle_child(process,custody,2):RetainedSettlement(process,custody)


def probe(host):
    """Use only the fixed classic CLI's qualification and read-only diagnostics."""
    pins={'wrapperSHA256':file_digest(WRAPPER),'capacitySHA256':file_digest(CAPACITY)}
    value=read_capabilities()
    if value.get('protocol')!='farm-classic-capabilities/v1' or value.get('transport')!='classic':raise ValueError('CLASSIC_READINESS_PROTOCOL_REQUIRED')
    ready=value.get('readiness',{});admission=value.get('admission',{})
    if ready.get('protocol')!='farm-local-checks-worker/v1' or ready.get('host')!=host or ready.get('runtimeQualified') is not True:raise ValueError('CLASSIC_RUNTIME_NOT_QUALIFIED')
    if not admission.get('policyMatches') or admission.get('grants') or admission.get('pending'):raise ValueError('CLASSIC_ADMISSION_NOT_IDLE')
    if pins!={'wrapperSHA256':file_digest(WRAPPER),'capacitySHA256':file_digest(CAPACITY)}:raise ValueError('CLASSIC_INSTALLATION_CHANGED')
    remaining=admission['remaining']
    if any(type(remaining.get(k)) is not int or remaining[k]<0 for k in ('vcpus','memoryMiB')):raise ValueError('CLASSIC_CAPACITY_INVALID')
    return dict(execution_mode='farm',farm_transport='classic',farm_runtime_qualified=True,
                farm_epoch=ready['epoch'],farm_image=ready['image'],farm_observed_current=True,
                farm_available_cpus=remaining['vcpus'],farm_available_memory_gib=remaining['memoryMiB']/1024,
                farm_installation=pins)


def owner(task):
    value=private_read(Path(task)/'coordinator-owner.json')
    if value.get('version')!=1 or value.get('transport')!='classic' or value.get('job')!=Path(task).name:raise ValueError('CLASSIC_COORDINATOR_OWNER_CHANGED')
    return value


def operation(task, journal):
    value=owner(task)
    op=protected_operation(journal['operationID'],journal['command'],value['installation'],journal['timeoutSeconds'],journal['cleanupTimeoutSeconds'])
    if op.task!=Path(task) or op.image!=value['image'] or op.command['epoch']!=value['epoch']:raise ValueError('CLASSIC_COORDINATOR_BINDING_CHANGED')
    return op


def submit_operation(task, command, timeout, token=None, allow_failed=False):
    task=Path(task);value=owner(task)
    journal={'operationID':uuid.uuid4().hex,'command':command,'timeoutSeconds':timeout,'cleanupTimeoutSeconds':120}
    # No synthetic native jobId/history. Each phase has one immutable identity.
    op=operation(task,journal)
    exclusive(task/('classic-'+command['action']+'-coordinator.json'),journal)
    original=op._cancel_requested
    def cancelled():
        marker=task/'cancel'
        if marker.exists() and command['action']!='cancel':
            if private_read(marker)!={'job':value['job'],'host':value['host']}:raise ValueError('CLASSIC_COORDINATOR_CANCEL_OWNER_CHANGED')
            op.cancel()
        return original()
    op._cancel_requested=cancelled
    try:
        result=op.run(token or b'')
    finally:
        if op.retained_owner is not None:
            # This is execution-owner lifetime, not an observation wait. Keep
            # farm_run_bound's signal scope/lock after the caller disconnects.
            # Operation already delivered its one pidfd SIGTERM. A marker can
            # acknowledge cancellation, never signal again or launch cleanup.
            observation_error=None
            while not op.retained_owner.finished.wait(.1):
                if observation_error is None:
                    try:cancelled()
                    except Exception as error:observation_error=error
            if observation_error is not None:
                raise ValueError('CLASSIC_CANCEL_OBSERVATION_UNCERTAIN_AFTER_SETTLEMENT') from observation_error
    response=result.get('response')
    if (not isinstance(response,dict) or response.get('version')!=1 or response.get('epoch')!=command['epoch']
        or response.get('request',{}).get('requestID')!=op.request):raise ValueError('CLASSIC_RESPONSE_UNCERTAIN_INSPECT_NO_REPLAY')
    if result.get('state')!='terminal' or (result.get('exitCode')!=0 and not (allow_failed and response.get('state')=='released')):raise ValueError('CLASSIC_OPERATION_FAILED_INSPECT_RELEASE_RECEIPT')
    return response


def retained_operations(task):
    for action in ('execute','create-admit','cancel'):
        path=Path(task)/('classic-'+action+'-coordinator.json')
        if path.exists():yield operation(task,private_read(path))


def cancel_task(task):
    task=Path(task);value=owner(task);marker={'job':value['job'],'host':value['host']}
    try:exclusive(task/'cancel',marker)
    except FileExistsError:
        if private_read(task/'cancel')!=marker:raise ValueError('CLASSIC_COORDINATOR_CANCEL_OWNER_CHANGED')
    operations=list(retained_operations(task))
    for op in operations:
        status=op.status()
        if status.get('state')!='terminal':
            op.cancel()
            return {'cancellation_requested':True,'delivery':'original_classic_owner_marker','operationID':op.operation_id}
        if status.get('exitCode')!=0:
            return {'cancellation_requested':True,'delivery':'inspect_failed_classic_owner_no_replay'}
    # The same existing coordinator execution lock proves that no original
    # coordinator can enter its next phase while cancellation inspects it.
    with (task.parent/'execution.lock').open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:return {'cancellation_requested':True,'delivery':'original_classic_coordinator_marker'}
        receipt=private_read(Path(value['receiptRoot'])/'local-checks'/(value['job']+'.json')) if operations else None
        if receipt is None:return {'cancellation_requested':True,'delivery':'before_classic_submit'}
        submission=private_read(task/'started.json')['submission']
        if (receipt.get('version')!=1 or receipt.get('epoch')!=value['epoch'] or receipt.get('request')!=submission
            or receipt.get('worker')!={'image':value['image'],'sourceRoot':str(task/'repo'),'dockerRoot':str(task/'docker')}):raise ValueError('CLASSIC_CANCEL_RECEIPT_OWNER_CHANGED')
        if receipt.get('state')=='released':
            observe_release(task,receipt)
            return {'cancellation_requested':True,'delivery':'already_released_observed'}
        if (receipt.get('state')!='running' or (task/'classic-execute-coordinator.json').exists()
            or (task/'classic-cancel-coordinator.json').exists()):return {'cancellation_requested':True,'delivery':'inspect_retained_classic_receipt_no_replay'}
        # Create-admit completed, but its coordinator exited before execute.
        # Invoke only the existing Go cancellation lifecycle for this exact
        # owner. Never edit the ledger or infer release from a dead process.
        command={'protocol':'farm-local-checks-worker/v1','action':'cancel','epoch':value['epoch'],'requestID':value['job']}
        released=submit_operation(task,command,90)
        if released.get('request')!=submission or released.get('state')!='released':raise ValueError('CLASSIC_CANCEL_RELEASE_NOT_PROVEN')
        observe_release(task,released)
        return {'cancellation_requested':True,'delivery':'owned_classic_worker_released'}


def observe_release(task, receipt):
    for op in retained_operations(task):
        # Positive exact absence is mandatory even when another phase recorded
        # release. Recovery never transforms this into workload success.
        def absent(identity):
            result=subprocess.run(['docker','ps','--all','--no-trunc','--filter','id='+identity,'--format','{{.ID}}'],capture_output=True,timeout=10,
                                  env={'PATH':os.environ.get('PATH',''),'HOME':'/nonexistent','DOCKER_HOST':'unix:///var/run/docker.sock'})
            return result.returncode==0 and result.stdout==b''
        return op.recover(receipt,absent)
    raise ValueError('CLASSIC_RETAINED_OPERATION_MISSING_INSPECT_NO_REPLAY')
