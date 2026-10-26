"""Native Farm transport for core_fleet's existing queue and pack receiver.

No scheduler, ledger, token store or Docker owner is defined here. All writes
are bound to the coordinator job and protected native worker binding.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time

FARM_PROTOCOL = 'farm-local-checks-worker/v1'
FARM_BINDING = '/boot/config/unraid/plugins/ci-runner-farm/native-local-checks.json'
FARM_POLICY = '/boot/config/plugins/ci-runner-farm/host-capacity.json'


def farm_private_json(path, limit=32768):
    path=Path(path)
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as stream:
        info=os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o077 or info.st_size>limit:
            raise ValueError('FARM_PRIVATE_RECEIPT_REQUIRED')
        data=stream.read(limit+1)
    if len(data)>limit:raise ValueError('FARM_RECEIPT_LIMIT')
    return json.loads(data)


def farm_exclusive_json(path, value):
    data=json.dumps(value,separators=(',',':')).encode()+b'\n'
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream:
        stream.write(data);stream.flush();os.fsync(stream.fileno())
    descriptor=os.open(Path(path).parent,os.O_RDONLY|os.O_DIRECTORY)
    try:os.fsync(descriptor)
    finally:os.close(descriptor)


def farm_pack_projection(snapshot):
    if set(snapshot)-{'commit','base','merge_base','files','resource_contract','observed_resource_contract'}:
        raise ValueError('UNRECOGNIZED_FLEET_SNAPSHOT_FIELD')
    return {key:snapshot[key] for key in ('commit','base','merge_base','files')}


def farm_bound_request(request):
    if os.geteuid()!=0 or request.get('host') not in ('steamy','tootie') or not re.fullmatch('[0-9a-f]{32}',request.get('job','')):
        raise ValueError('FARM_ROOT_JOB_IDENTITY_REQUIRED')
    transport=request.get('farm_transport','native')
    if transport not in ('native','classic'):raise ValueError('FARM_EXPLICIT_TRANSPORT_REQUIRED')
    binding_path=FARM_BINDING if transport=='native' else '/boot/config/plugins/ci-runner-farm/native-local-checks.json'
    binding=farm_private_json(binding_path,8192)
    if binding.get('version')!=1 or binding.get('host')!=request['host']:
        raise ValueError('FARM_PROTECTED_BINDING_CHANGED')
    root=Path(binding['root'])
    if not root.is_absolute() or root.resolve()!=root or root==Path('/'):
        raise ValueError('FARM_PROTECTED_ROOT_REQUIRED')
    info=root.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=0 or info.st_mode&0o077:
        raise ValueError('FARM_PROTECTED_ROOT_REQUIRED')
    observe=request.get('action') in ('farm-log','farm-result','farm-cancel')
    if observe:
        owner=farm_private_json(root/request['job']/'coordinator-owner.json')
        if owner.get('version')!=1 or owner.get('host')!=request['host'] or owner.get('job')!=request['job']:
            raise ValueError('FARM_RETAINED_OWNER_MISMATCH')
        if owner.get('transport','native')!=transport:raise ValueError('FARM_RETAINED_TRANSPORT_CHANGED')
        # Read-only evidence and the task's own cancel marker survive upgrades.
    elif (binding.get('runtimeQualified') is not True or binding.get('canarySubmissionSHA256')
          or binding.get('epoch')!=request.get('farm_epoch') or binding.get('image')!=request.get('farm_image')):
        raise ValueError('FARM_PROTECTED_BINDING_CHANGED')
    return dict(request,parent=str(root)),binding


def farm_wait_operation(task, operation, timeout):
    deadline=time.monotonic()+timeout
    cancellation_sent=False
    while time.monotonic()<deadline:
        status=farm_backend_request(dict(action='job-status'))
        if status.get('cancelOperationIdentity') is not True:
            raise ValueError('FARM_OPERATION_IDENTITY_CANCEL_REQUIRED')
        for job in status.get('history') or []:
            if job.get('id')==operation:return job
        active=status.get('active')
        if not isinstance(active,dict) or active.get('id')!=operation:
            raise ValueError('FARM_OPERATION_NOT_VISIBLE_INSPECT_NO_REPLAY')
        if (task/'cancel').exists() and not cancellation_sent:
            # Compare-and-cancel is enforced atomically by the native Service.
            farm_exclusive_json(task/('cancel-'+operation+'.json'),dict(operation=operation,phase='before-cancel'))
            farm_backend_request(dict(action='cancel',args=[operation],confirm=True))
            cancellation_sent=True
        time.sleep(.25)
    raise ValueError('FARM_OBSERVATION_EXPIRED_INSPECT_NO_REPLAY')


def farm_submit_operation(task, command, timeout, token=None, allow_failed=False):
    if globals().get('REQUEST',{}).get('farm_transport','native')=='classic':
        from core_fleet_classic import submit_operation
        return submit_operation(task,command,timeout,token,allow_failed)
    action=command['action']
    journal=task/('native-'+action+'-operation.json')
    # Exclusive intent before sending; an uncertain write is never replayed.
    farm_exclusive_json(journal,dict(phase='before-submit',command=command))
    request=dict(action='local-checks',value=json.dumps(command,separators=(',',':')))
    if token is not None:request['values']={'dependencyCredential':token.decode()}
    response=farm_backend_request(request)
    operation=response.get('jobId')
    if not isinstance(operation,str) or not re.fullmatch('[0-9a-f]{32}',operation):
        raise ValueError('FARM_SUBMIT_RECEIPT_INVALID_INSPECT_NO_REPLAY')
    farm_exclusive_json(task/('native-'+action+'-accepted.json'),dict(operation=operation,command=command))
    terminal=farm_wait_operation(task,operation,timeout)
    farm_exclusive_json(task/('native-'+action+'-terminal.json'),terminal)
    try:receipt=json.loads(terminal['output'])
    except (ValueError,KeyError,TypeError) as exc:raise ValueError('FARM_TERMINAL_RECEIPT_INVALID') from exc
    request_id=command.get('requestID') or command['submission']['requestID']
    if (receipt.get('version')!=1 or receipt.get('epoch')!=command['epoch']
        or receipt.get('request',{}).get('requestID')!=request_id):
        raise ValueError('FARM_TERMINAL_OWNER_MISMATCH')
    if terminal.get('status')!='passed' and not (allow_failed and terminal.get('status') in ('failed','cancelled','timed_out') and receipt.get('state')=='released'):
        raise ValueError('FARM_OPERATION_FAILED_INSPECT_RELEASE_RECEIPT')
    return receipt


def farm_prepare_bound(request):
    bound,binding=farm_bound_request(request)
    readiness=farm_probe()
    if readiness['farm_epoch']!=binding['epoch'] or readiness['farm_image']!=binding['image']:
        raise ValueError('FARM_ADMISSION_CHANGED')
    snapshot=request['snapshot']
    if not validate_execution_contract(snapshot):raise ValueError('FARM_EXPLICIT_SOURCE_CONTRACT_REQUIRED')
    root=Path(bound['parent']);root.mkdir(parents=True,exist_ok=True,mode=0o700)
    policy=farm_private_json(FARM_POLICY)
    if policy.get('host')!=request['host'] or policy.get('epoch')!=binding['epoch'] or policy.get('mode')!='active':raise ValueError('FARM_POLICY_OWNER_CHANGED')
    receipt_root=Path(policy['receiptRoot'])
    if not receipt_root.is_absolute() or receipt_root.resolve()!=receipt_root or receipt_root==Path('/'):raise ValueError('FARM_RECEIPT_ROOT_INVALID')
    task=root/request['job'];task.mkdir(mode=0o700)
    descriptor=os.open(root,os.O_RDONLY|os.O_DIRECTORY)
    try:os.fsync(descriptor)
    finally:os.close(descriptor)
    owner=dict(version=1,host=request['host'],job=request['job'],epoch=binding['epoch'],image=binding['image'],receiptRoot=str(receipt_root),transport=request.get('farm_transport','native'))
    if owner['transport']=='classic':owner['installation']=readiness['farm_installation']
    farm_exclusive_json(task/'coordinator-owner.json',owner)
    farm_exclusive_json(task/'coordinator-intent.json',snapshot)
    farm_exclusive_json(task/'intent.json',farm_pack_projection(snapshot))
    return dict(task=str(task),farm_epoch=binding['epoch'],farm_image=binding['image'],execution_mode='farm')


def farm_receive_bound(request):
    bound,_=farm_bound_request(request);task=Path(bound['parent'])/request['job']
    full=farm_private_json(task/'coordinator-intent.json')
    if full!=request['snapshot']:raise ValueError('FARM_COORDINATOR_INTENT_MISMATCH')
    # Invoke the SAME canonical receiver, with its closed custody projection.
    projected=dict(bound,snapshot=farm_pack_projection(full),action='receive')
    global REQUEST
    previous=REQUEST;REQUEST=projected
    try:result=receive_fleet()
    finally:REQUEST=previous
    verify_resource_source(task/'repo',full)
    return result


def farm_collect_result(task, request, snapshot, released):
    submission=request['submission']
    if released.get('state')!='released' or released.get('request')!=submission:
        raise ValueError('FARM_RELEASE_NOT_PROVEN')
    evidence=task/'evidence'/request['job'];native=farm_private_json(evidence/'result.json')
    if (any(native.get(k)!=submission.get(k) for k in ('requestID','commit','base','bundleSHA256'))
        or native.get('host')!=request['host'] or native.get('status') not in ('passed','failed','cancelled','timed_out','output_limited')
        or (native.get('exitCode') is not None and type(native['exitCode']) is not int)
        or (native.get('status')=='passed' and native.get('exitCode')!=0)):
        raise ValueError('FARM_RESULT_IDENTITY_OR_EXIT_MISMATCH')
    result=dict(native_started=True,status=native['status'],exit_code=native.get('exitCode'),host=request['host'],commit=submission['commit'],base=submission['base'],task=str(task),log=str(evidence/'checks.log'),source_unchanged=False,resource_contract=dict(status='unverified'),workload_started=False,phase='preflight',farm_receipt=released)
    try:
        verify_resource_source(task/'repo',snapshot)
        result['source_unchanged']=True
        if snapshot.get('observed_resource_contract') is not None:
            rows=read_resource_receipts(evidence/'checks.log',prefix=b'CORE_OBSERVED_RESOURCE_V1 ',limit=1)
            log_path=evidence/'checks.log'
            if log_path.stat().st_size>16*1024**2:raise ValueError('OBSERVED_CORE_LOG_BOUND')
            resources=check_observed_receipts(rows,snapshot,request,log_path.read_text(errors='replace'),native.get('exitCode'))
            result.update(resource_contract=resources,workload_started=True,phase='checks')
        else:
            rows=read_resource_receipts(evidence/'checks.log')
            resources=check_resource_receipts(rows,snapshot,dict(request,platform='linux/amd64'))
            stages=read_resource_receipts(evidence/'checks.log',prefix=b'CORE_RESOURCE_STAGE_V1 ',limit=1)
            expected=dict(version=1,stage='units_started',commit=submission['commit'],base=submission['base'])
            if stages not in ([],[expected]) or (native['status']=='passed' and stages!=[expected]):
                raise ValueError('FARM_FULL_CHECKS_STAGE_MISSING_OR_CHANGED')
            result.update(resource_contract=resources,workload_started=bool(stages),phase='checks' if stages else 'checks_preparation')
    except (ValueError,OSError) as exc:
        result['resource_contract']=dict(status='unverified',error=str(exc)[:300])
        if result['status']=='passed':result['status']='failed'
    farm_exclusive_json(task/'coordinator-result.json',result)
    return result


def farm_run_bound(request):
    bound,binding=farm_bound_request(request);task=Path(bound['parent'])/request['job']
    snapshot=farm_private_json(task/'coordinator-intent.json')
    if snapshot!=request['snapshot'] or not validate_execution_contract(snapshot):raise ValueError('FARM_COORDINATOR_INTENT_MISMATCH')
    verify_resource_source(task/'repo',snapshot)
    submission=request['submission']
    manifest=farm_pack_projection(snapshot)
    digest=hashlib.sha256(json.dumps(manifest,sort_keys=True,separators=(',',':'),ensure_ascii=True).encode()).hexdigest()
    if (submission.get('version')!=1 or submission.get('repository')!='unraid/core' or submission.get('requestID')!=request['job']
        or submission.get('commit')!=snapshot['commit'] or submission.get('base')!=snapshot['base'] or submission.get('bundleSHA256')!=digest
        or submission.get('cpus')!=request['cpus'] or submission.get('memoryMiB')!=request['memory_gib']*1024
        or submission.get('timeoutSeconds')!=request['timeout'] or submission.get('scratchMiB')!=102400):
        raise ValueError('FARM_TYPED_SUBMISSION_MISMATCH')
    if (task/'started.json').exists() or any(task.glob('native-*-operation.json')):
        raise ValueError('FARM_EXECUTION_ALREADY_STARTED_NEVER_REPLAY')
    raw=sys.stdin.buffer.read(4098)
    token=raw[:-1] if raw.endswith(b'\n') else raw
    if not 8<=len(token)<=4096 or any(x in token for x in (b'\n',b'\r',b'\0')):raise ValueError('PROCESS_CREDENTIAL_REQUIRED')
    import fcntl
    lock=(Path(bound['parent'])/'execution.lock').open('a')
    old_handlers={sig:signal.getsignal(sig) for sig in (signal.SIGHUP,signal.SIGTERM,signal.SIGINT)}
    for sig in old_handlers:signal.signal(sig,lambda *_:farm_mark_cancel(task,request))
    try:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            result=dict(native_started=False,status='blocked',exit_code=None,host=request['host'],commit=snapshot['commit'],base=snapshot['base'],task=str(task),workload_started=False,reason='FARM_COORDINATOR_HOST_BUSY')
            farm_exclusive_json(task/'coordinator-result.json',result);return result
        try:
            available=farm_probe()
            if (available['farm_epoch']!=binding['epoch'] or available['farm_image']!=binding['image']
                or available['farm_available_cpus']<request['cpus'] or available['farm_available_memory_gib']<request['memory_gib']):
                raise ValueError('FARM_ADMISSION_CHANGED')
        except (ValueError,OSError) as exc:
            result=dict(native_started=False,status='blocked',exit_code=None,host=request['host'],commit=snapshot['commit'],base=snapshot['base'],task=str(task),workload_started=False,reason=str(exc)[:300])
            farm_exclusive_json(task/'coordinator-result.json',result);return result
        farm_exclusive_json(task/'started.json',dict(phase='coordinator',workload_started=False,submission=submission))
        if (task/'cancel').exists():
            result=dict(native_started=False,status='cancelled',exit_code=None,host=request['host'],commit=snapshot['commit'],base=snapshot['base'],task=str(task),workload_started=False)
            farm_exclusive_json(task/'coordinator-result.json',result);return result
        create=dict(protocol=FARM_PROTOCOL,action='create-admit',epoch=binding['epoch'],submission=submission)
        receipt=farm_submit_operation(task,create,120)
        if receipt.get('request')!=submission or receipt.get('state')!='running':raise ValueError('FARM_CREATED_OWNER_MISMATCH')
        execute=dict(protocol=FARM_PROTOCOL,action='execute',epoch=binding['epoch'],requestID=request['job'])
        released=farm_submit_operation(task,execute,request['timeout']+60,token,allow_failed=True)
        if released.get('request')!=submission or released.get('state')!='released':raise ValueError('FARM_RELEASE_NOT_PROVEN')
        return farm_collect_result(task,request,snapshot,released)
    finally:
        for sig,handler in old_handlers.items():signal.signal(sig,handler)
        lock.close()


def farm_retained_worker(task, request):
    started_path=task/'started.json'
    if not started_path.exists():return None,None,None
    started=farm_private_json(started_path);submission=started['submission']
    if submission.get('requestID')!=request['job']:raise ValueError('FARM_RETAINED_OWNER_MISMATCH')
    owner=farm_private_json(task/'coordinator-owner.json')
    receipt_root=Path(owner['receiptRoot'])
    if not receipt_root.is_absolute() or receipt_root.resolve()!=receipt_root or receipt_root==Path('/'):
        raise ValueError('FARM_RECEIPT_ROOT_INVALID')
    receipt_path=receipt_root/'local-checks'/(request['job']+'.json')
    if not receipt_path.exists():return submission,owner,None
    receipt=farm_private_json(receipt_path)
    if (receipt.get('version')!=1 or receipt.get('epoch')!=owner['epoch'] or receipt.get('request')!=submission
        or receipt.get('worker',{}).get('sourceRoot')!=str(task/'repo') or receipt.get('worker',{}).get('dockerRoot')!=str(task/'docker')
        or receipt.get('worker',{}).get('image')!=owner['image']
        or not (re.fullmatch('[0-9a-f]{64}',receipt.get('containerID',''))
                or receipt.get('state')=='released' and receipt.get('creationAbsent') is True
                and receipt.get('containerID')=='' and not receipt.get('fence'))):
        raise ValueError('FARM_RETAINED_RECEIPT_OWNER_MISMATCH')
    return submission,owner,receipt


def farm_observe_result(task, request):
    cached=task/'coordinator-result.json'
    if cached.exists():return farm_private_json(cached)
    submission,owner,receipt=farm_retained_worker(task,request)
    if receipt is None:return None
    if receipt.get('state')!='released':return None
    if owner.get('transport','native')=='classic':
        from core_fleet_classic import observe_release
        observe_release(task,receipt)
    evidence=task/'evidence'/request['job']/'result.json'
    if not evidence.exists():
        # Positive native absence/release after explicit cancel, before checks.
        if not (task/'cancel').exists():return None
        snapshot=farm_private_json(task/'coordinator-intent.json')
        result=dict(native_started=True,status='cancelled',exit_code=None,host=request['host'],commit=snapshot['commit'],base=snapshot['base'],task=str(task),workload_started=False,farm_receipt=receipt)
        farm_exclusive_json(cached,result);return result
    snapshot=farm_private_json(task/'coordinator-intent.json')
    observed=dict(request,submission=submission,cpus=submission['cpus'],memory_gib=submission['memoryMiB']//1024)
    return farm_collect_result(task,observed,snapshot,receipt)


def farm_mark_cancel(task, request):
    marker=dict(job=request['job'],host=request['host'])
    try:farm_exclusive_json(task/'cancel',marker)
    except FileExistsError:
        if farm_private_json(task/'cancel')!=marker:raise ValueError('FARM_CANCEL_MARKER_OWNER_MISMATCH')


def farm_cancel_task(task, request, binding):
    if request.get('farm_transport','native')=='classic':
        from core_fleet_classic import cancel_task
        return cancel_task(task)
    farm_mark_cancel(task,request)
    if farm_observe_result(task,request) is not None:
        return dict(cancellation_requested=True,delivery='already_terminal')
    import fcntl
    lock=(task.parent/'execution.lock').open('a')
    try:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:return dict(cancellation_requested=True,delivery='owned_supervisor_marker')
        submission,owner,receipt=farm_retained_worker(task,request)
        if owner is None:return dict(cancellation_requested=True,delivery='before_native_submit')
        status=farm_backend_request(dict(action='job-status'))
        if status.get('cancelOperationIdentity') is not True:raise ValueError('FARM_OPERATION_IDENTITY_CANCEL_REQUIRED')
        active=status.get('active')
        if active is not None:
            for action in ('execute','create-admit'):
                accepted_path=task/('native-'+action+'-accepted.json')
                if not accepted_path.exists():continue
                accepted=farm_private_json(accepted_path);command=accepted['command'];operation=accepted['operation']
                expected=dict(protocol=FARM_PROTOCOL,action=action,epoch=owner['epoch'])
                if action=='execute':expected['requestID']=request['job']
                else:expected['submission']=submission
                if command!=expected or not re.fullmatch('[0-9a-f]{32}',operation):raise ValueError('FARM_CANCEL_OPERATION_OWNER_MISMATCH')
                if active.get('id')!=operation:continue
                journal=task/('cancel-'+operation+'.json')
                if journal.exists():return dict(cancellation_requested=True,delivery='cancel_already_journaled_inspect')
                farm_exclusive_json(journal,dict(operation=operation,phase='before-cancel'))
                farm_backend_request(dict(action='cancel',args=[operation],confirm=True))
                return dict(cancellation_requested=True,delivery='exact_operation_cancel_requested')
            return dict(cancellation_requested=True,delivery='foreign_backend_operation_active')
        if receipt is None:return dict(cancellation_requested=True,delivery='no_owned_native_receipt_observed')
        if receipt.get('state')=='released':return dict(cancellation_requested=True,delivery='released_receipt_observed')
        if binding.get('epoch')!=owner['epoch'] or binding.get('image')!=owner['image']:
            raise ValueError('FARM_CANCEL_BINDING_CHANGED_INSPECT')
        if (task/'native-cancel-operation.json').exists():return dict(cancellation_requested=True,delivery='cancel_already_journaled_inspect')
        command=dict(protocol=FARM_PROTOCOL,action='cancel',epoch=owner['epoch'],requestID=request['job'])
        released=farm_submit_operation(task,command,90)
        if released.get('state')!='released' or released.get('request')!=submission:raise ValueError('FARM_CANCEL_RELEASE_NOT_PROVEN')
        farm_observe_result(task,request)
        return dict(cancellation_requested=True,delivery='owned_worker_released')
    finally:lock.close()


def farm_action(request):
    action=request['action']
    if action=='farm-prepare':return farm_prepare_bound(request)
    if action=='farm-receive':return farm_receive_bound(request)
    if action=='farm-run':return farm_run_bound(request)
    bound,binding=farm_bound_request(request);task=Path(bound['parent'])/request['job']
    if action=='farm-cancel':
        return farm_cancel_task(task,request,binding)
    if action=='farm-result':
        return farm_observe_result(task,request)
    if action=='farm-log':
        path=task/'evidence'/request['job']/'checks.log';offset=request.get('offset',0)
        if type(offset) is not int or offset<0:raise ValueError('INVALID_LOG_OFFSET')
        if not path.exists():return dict(offset=offset,size=0,text='')
        size=path.stat().st_size
        if request.get('tail'):offset=max(0,size-32768)
        with path.open('rb') as stream:stream.seek(offset);data=stream.read(32768)
        return dict(offset=offset+len(data),size=size,text=data.decode('utf-8',errors='replace'))
    raise ValueError('UNKNOWN_FARM_ACTION')
