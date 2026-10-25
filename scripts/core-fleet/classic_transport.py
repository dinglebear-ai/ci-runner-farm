"""Unadvertised classic transport; existing Go/FD8/ledger remain authoritative.

An operation receipt is transport recovery evidence, never a capacity ledger.
No lost-response operation is replayed and no stored numeric PID is signalled.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import time
from classic_process import OwnedProcess, RetainedSettlement, settle_child

PROTOCOL = 'farm-local-checks-worker/v1'
BINDING = Path('/boot/config/plugins/ci-runner-farm/native-local-checks.json')
WRAPPER = Path('/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh')
CAPACITY = Path('/usr/local/emhttp/plugins/ci-runner-farm/bin/ci-runner-capacity')
POLICY = Path('/boot/config/plugins/ci-runner-farm/host-capacity.json')
HEX32 = re.compile('[0-9a-f]{32}')
HEX64 = re.compile('[0-9a-f]{64}')


def read_output(descriptor, maximum):
    """Read the bounded transport capture, separate from settlement draining."""
    return os.read(descriptor, maximum)


def redact_decoded(value, secret):
    # JSON escaping can hide the original byte sequence in a captured string.
    # Sanitize decoded keys and values before any response is persisted.
    if isinstance(value,str):return value.replace(secret,'[REDACTED]')
    if isinstance(value,list):return [redact_decoded(item,secret) for item in value]
    if isinstance(value,dict):return {redact_decoded(key,secret):redact_decoded(item,secret) for key,item in value.items()}
    return value


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def private_read(path, maximum=65536):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077 or info.st_size > maximum:
            raise ValueError('CLASSIC_PRIVATE_RECEIPT_INVALID')
        raw = stream.read(maximum + 1)
        if len(raw) > maximum:
            raise ValueError('CLASSIC_PRIVATE_RECEIPT_BOUND')
        return json.loads(raw)


def exclusive(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(canonical(value)); stream.flush(); os.fsync(stream.fileno())
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)


def command_request(command):
    if not isinstance(command, dict) or command.get('protocol') != PROTOCOL or not isinstance(command.get('epoch'),str) or not HEX32.fullmatch(command['epoch']):
        raise ValueError('CLASSIC_CLOSED_COMMAND_REQUIRED')
    action = command.get('action')
    fields = {'protocol', 'action', 'epoch'}
    if action in ('create-admit', 'qualify'):
        fields.add('submission'); submission = command.get('submission')
        keys = {'version', 'repository', 'commit', 'base', 'bundleSHA256', 'requestID', 'cpus', 'memoryMiB', 'timeoutSeconds', 'scratchMiB'}
        if not isinstance(submission, dict) or set(submission) != keys or type(submission['version']) is not int or submission['version'] != 1 or submission['repository'] != 'unraid/core':
            raise ValueError('CLASSIC_CLOSED_SUBMISSION_REQUIRED')
        if any(not isinstance(submission[k], str) or not re.fullmatch('[0-9a-f]{40}', submission[k]) for k in ('commit', 'base')) or not isinstance(submission['bundleSHA256'],str) or not HEX64.fullmatch(submission['bundleSHA256']):
            raise ValueError('CLASSIC_CLOSED_SUBMISSION_REQUIRED')
        for key, maximum in [('cpus',128), ('memoryMiB',1048576), ('timeoutSeconds',86400), ('scratchMiB',1048576)]:
            if type(submission[key]) is not int or not 1 <= submission[key] <= maximum:
                raise ValueError('CLASSIC_FINITE_SUBMISSION_REQUIRED')
        request = submission['requestID']
    elif action in ('execute', 'complete', 'cancel'):
        fields.add('requestID'); request = command.get('requestID')
    else: raise ValueError('CLASSIC_CLOSED_COMMAND_REQUIRED')
    if set(command) != fields or not isinstance(request, str) or not HEX32.fullmatch(request) or len(canonical(command)) > 16384:
        raise ValueError('CLASSIC_CLOSED_COMMAND_REQUIRED')
    return request


def file_digest(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022 or not info.st_mode & 0o111 or info.st_size > 64*1024**2:
            raise ValueError('CLASSIC_INSTALLED_FILE_INVALID')
        return hashlib.sha256(stream.read(64*1024**2+1)).hexdigest()


class Operation:
    def __init__(self, task, operation_id, command, wrapper, capacity, pins, image, timeout=7200, cleanup_timeout=120):
        if type(timeout) is not int or not 1 <= timeout <= 86400 or type(cleanup_timeout) is not int or not 1 <= cleanup_timeout <= 180:
            raise ValueError('CLASSIC_FINITE_OPERATION_REQUIRED')
        if not isinstance(image,str) or not re.fullmatch('sha256:[0-9a-f]{64}',image):raise ValueError('CLASSIC_IMAGE_PIN_REQUIRED')
        self.timeout,self.cleanup_timeout,self.image=timeout,cleanup_timeout,image
        self.retained_owner = None
        self.task = Path(task)
        info = self.task.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError('CLASSIC_PRIVATE_TASK_REQUIRED')
        self.request = command_request(command)
        if self.task.name != self.request or not isinstance(operation_id, str) or not HEX32.fullmatch(operation_id):
            raise ValueError('CLASSIC_OPERATION_OWNER_MISMATCH')
        if not isinstance(pins,dict) or set(pins) != {'wrapperSHA256','capacitySHA256'} or any(not isinstance(v,str) or not HEX64.fullmatch(v) for v in pins.values()):
            raise ValueError('CLASSIC_INSTALLATION_PIN_REQUIRED')
        self.wrapper, self.capacity = Path(wrapper), Path(capacity)
        self.command, self.operation_id, self.pins = command, operation_id, pins
        self.intent = {'version':1,'operationID':operation_id,'command':command,'installation':pins,'image':image,'timeoutSeconds':timeout,'cleanupTimeoutSeconds':cleanup_timeout}
        self.digest = hashlib.sha256(canonical(self.intent)).hexdigest()
        prefix = 'classic-'+command['action']
        self.intent_path = self.task/(prefix+'-intent.json')
        self.result_path = self.task/(prefix+'-result.json')
        self.cancel_path = self.task/(prefix+'-cancel.json')

    def bound_intent(self):
        if private_read(self.intent_path) != self.intent:
            raise ValueError('CLASSIC_OPERATION_OWNER_MISMATCH')

    def status(self):
        self.bound_intent()
        if self.result_path.exists():
            value = private_read(self.result_path)
            if value.get('operationID') != self.operation_id or value.get('intentSHA256') != self.digest:
                raise ValueError('CLASSIC_OPERATION_OWNER_MISMATCH')
            return value
        return {'operationID':self.operation_id,'intentSHA256':self.digest,'state':'inspect_required','reason':'terminal_receipt_not_observed','replayAllowed':False}

    def cancel(self):
        self.bound_intent()
        if self.result_path.exists(): return self.status()
        marker = {'operationID':self.operation_id,'intentSHA256':self.digest}
        try: exclusive(self.cancel_path, marker)
        except FileExistsError:
            if private_read(self.cancel_path) != marker: raise ValueError('CLASSIC_CANCEL_OWNER_MISMATCH')
        return {'operationID':self.operation_id,'state':'cancel_requested','delivery':'original_owner_must_acknowledge','replayAllowed':False}

    def _cancel_requested(self):
        if not self.cancel_path.exists(): return False
        if private_read(self.cancel_path) != {'operationID':self.operation_id,'intentSHA256':self.digest}:
            raise ValueError('CLASSIC_CANCEL_OWNER_MISMATCH')
        return True

    def run(self, dependency=b''):
        timeout,cleanup_timeout=self.timeout,self.cleanup_timeout
        if self.command['action'] == 'execute':
            if not isinstance(dependency, bytes) or not 8 <= len(dependency) <= 4096 or any(x in dependency for x in (b'\n',b'\r',b'\0')): raise ValueError('CLASSIC_STDIN_CREDENTIAL_REQUIRED')
        elif dependency: raise ValueError('CLASSIC_UNEXPECTED_CREDENTIAL')
        if file_digest(self.wrapper) != self.pins['wrapperSHA256'] or file_digest(self.capacity) != self.pins['capacitySHA256']:
            raise ValueError('CLASSIC_INSTALLATION_CHANGED')
        try: exclusive(self.intent_path, self.intent)
        except FileExistsError: return self.status()
        process = None; owner = None; poll = selectors.DefaultSelector(); output = bytearray(); failure = None; cancel_at = None
        deadline = time.monotonic()+timeout
        try:
            process = subprocess.Popen([str(self.wrapper),'local-checks'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={'PATH':os.environ.get('PATH',''),'HOME':'/nonexistent'},close_fds=True)
            owner = OwnedProcess(process,self.operation_id)
            # Do not deliver the protected envelope or secret until this exact
            # unreaped child has exec'd the pinned capacity binary. Path hashes
            # alone cannot establish the identity of executing code.
            identity_deadline = min(deadline,time.monotonic()+25)
            while process.poll() is None:
                try:
                    with open('/proc/'+str(process.pid)+'/exe','rb') as stream:
                        helper = hashlib.sha256(stream.read(64*1024**2+1)).hexdigest()
                    arguments=Path('/proc',str(process.pid),'cmdline').read_bytes().rstrip(b'\0').split(b'\0')
                    if helper == self.pins['capacitySHA256'] and len(arguments)==2 and os.path.normpath(os.fsdecode(arguments[0]))==str(self.capacity) and arguments[1]==b'local-checks': break
                except FileNotFoundError: pass
                if self._cancel_requested() or time.monotonic() >= identity_deadline:
                    owner.cancel(self.operation_id); failure='CLASSIC_HELPER_IDENTITY_NOT_ESTABLISHED'; break
                time.sleep(.02)
            if failure or process.poll() is not None:
                failure=failure or 'CLASSIC_HELPER_EXITED_BEFORE_ENVELOPE'
                process.stdin.close()
            else:
                process.stdin.write(canonical(self.command)+b'\n'+dependency);process.stdin.close()
            for stream in (process.stdout,process.stderr): poll.register(stream,selectors.EVENT_READ)
            while poll.get_map() or process.poll() is None:
                now=time.monotonic()
                if self._cancel_requested() or now>=deadline or failure:
                    if cancel_at is None: owner.cancel(self.operation_id);cancel_at=now
                    if now-cancel_at >= cleanup_timeout and (process.poll() is None or poll.get_map()):
                        failure='CLASSIC_OWNER_CLEANUP_UNCERTAIN';break
                for key,_ in poll.select(.1):
                    data=read_output(key.fileobj.fileno(),65536)
                    if not data:poll.unregister(key.fileobj);continue
                    if key.fileobj is process.stdout and len(output)<=60*1024:output.extend(data)
                    if len(output)>60*1024:failure='CLASSIC_RESPONSE_BOUND_EXCEEDED'
            code=process.poll()
            if code is None:
                self.retained_owner=RetainedSettlement(process,owner)
            response=None
            if code is not None and not failure:
                try:
                    raw=bytes(output).replace(dependency,b'[REDACTED]') if dependency else bytes(output)
                    response=json.loads(raw)
                    if not isinstance(response,dict):raise ValueError()
                    if dependency:response=redact_decoded(response,dependency.decode('utf-8'))
                except (ValueError,UnicodeError):failure='CLASSIC_RESPONSE_INVALID'
            result={'operationID':self.operation_id,'intentSHA256':self.digest,'state':'terminal' if code is not None and not failure else 'inspect_required','exitCode':code,'cancelAcknowledged':bool(owner.cancel_sent),'replayAllowed':False}
            if response is not None:result['response']=response
            if failure:result['reason']=failure
            if self.retained_owner is not None:result['settlementOwnerRetainedAtReturn']=True
            exclusive(self.result_path,result)
            return result
        except Exception:
            if owner is not None: owner.cancel(self.operation_id)
            # The intent remains immutable. A transport exception never grants
            # permission to respawn or claims that a charged worker was released.
            raise
        finally:
            poll.close()
            if process is not None and self.retained_owner is None:
                if not settle_child(process, owner, cleanup_timeout):
                    self.retained_owner=RetainedSettlement(process,owner)
            elif process is None and owner is not None:
                owner.close()

    def recover(self, receipt, prove_absence):
        self.bound_intent()
        if (not isinstance(receipt,dict) or not isinstance(receipt.get('request'),dict) or type(receipt.get('version')) is not int or receipt.get('version')!=1 or receipt.get('epoch')!=self.command['epoch']
            or receipt.get('state')!='released' or receipt.get('request',{}).get('requestID')!=self.request
            or receipt.get('worker')!={'image':self.image,'sourceRoot':str(self.task/'repo'),'dockerRoot':str(self.task/'docker')}
            or not isinstance(receipt.get('containerID'),str) or not HEX64.fullmatch(receipt['containerID'])):
            raise ValueError('CLASSIC_RELEASE_NOT_PROVEN')
        if 'submission' in self.command and receipt['request']!=self.command['submission']:
            raise ValueError('CLASSIC_RELEASE_NOT_PROVEN')
        if prove_absence(receipt['containerID']) is not True:raise ValueError('CLASSIC_CONTAINER_ABSENCE_NOT_PROVEN')
        # Do not rewrite an uncertain intent/result or manufacture test success.
        return {'operationID':self.operation_id,'state':'released_observed','containerID':receipt['containerID'],'replayAllowed':False,'workloadSuccessProven':False}


def protected_operation(operation_id, command, pins, timeout, cleanup_timeout):
    if os.geteuid()!=0:raise ValueError('CLASSIC_ROOT_REQUIRED')
    return operation_from_binding(operation_id,command,pins,timeout,cleanup_timeout)


def operation_from_binding(operation_id, command, pins, timeout, cleanup_timeout):
    binding=private_read(BINDING,8192)
    request=command_request(command)
    root=binding.get('root')
    if binding.get('version')!=1 or binding.get('epoch')!=command['epoch'] or not isinstance(root,str) or not Path(root).is_absolute() or str(Path(root))!=root or root=='/':
        raise ValueError('CLASSIC_PROTECTED_BINDING_CHANGED')
    info=Path(root).lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o077:raise ValueError('CLASSIC_PRIVATE_ROOT_REQUIRED')
    return Operation(Path(root)/request,operation_id,command,WRAPPER,CAPACITY,pins,binding.get('image'),timeout,cleanup_timeout)


def observe_release(operation):
    policy=private_read(POLICY)
    root=policy.get('receiptRoot')
    if policy.get('epoch')!=operation.command['epoch'] or not isinstance(root,str) or not Path(root).is_absolute() or str(Path(root))!=root or root=='/':
        raise ValueError('CLASSIC_POLICY_OWNER_CHANGED')
    info=Path(root).lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o077:raise ValueError('CLASSIC_PRIVATE_ROOT_REQUIRED')
    receipt=private_read(Path(root)/'local-checks'/(operation.request+'.json'))
    def absent(identity):
        result=subprocess.run(['docker','ps','--all','--no-trunc','--filter','id='+identity,'--format','{{.ID}}'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10,env={'PATH':os.environ.get('PATH',''),'HOME':'/nonexistent','DOCKER_HOST':'unix:///var/run/docker.sock'})
        return result.returncode==0 and result.stdout==b''
    return operation.recover(receipt,absent)


def handle_request(request, dependency=b''):
    keys={'action','operationID','command','installation','timeoutSeconds','cleanupTimeoutSeconds'}
    if not isinstance(request,dict) or set(request)!=keys or request['action'] not in ('run','status','cancel','observe-release'):
        raise ValueError('CLASSIC_CLOSED_TRANSPORT_REQUIRED')
    if dependency and request['action']!='run':raise ValueError('CLASSIC_UNEXPECTED_CREDENTIAL')
    operation=protected_operation(request['operationID'],request['command'],request['installation'],request['timeoutSeconds'],request['cleanupTimeoutSeconds'])
    if request['action']=='run':return operation.run(dependency)
    if request['action']=='status':return operation.status()
    if request['action']=='cancel':return operation.cancel()
    return observe_release(operation)
