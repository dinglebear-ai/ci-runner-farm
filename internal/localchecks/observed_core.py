"""Separate observed-current-Core contract; never manufactures V1 receipts.

Authority: merged Core #2079's exact existing wrapper/runner/resource planner.
This module owns external observation only. It must not rewrite Core scripts.
"""
import hashlib
import re

PROFILE='core-2079-observed/v1'
PROFILE_SHA256={
 'core/scripts/local_ci_container.sh':'1fce83b6047f9baff1e7363f3e7371281202dfbb7e3a51ca2ef2ea32be68cfbd',
 'core/scripts/local_ci_linux.sh':'777415c0ce2ac7fcc711748cc607b45b8496f96ea94d7937524569ca48f9785f',
 'core/scripts/local_ci_resources.py':'bb6c280f0c9afea77366d65084da462655cf695774df8b2518216d726260f367',
}
# Current local-main variant lacks the later optional automatic-cleanup opt-out.
# It is supported ONLY in Farm's job-private daemon, never a shared host engine.
WRAPPER_SHA256={PROFILE_SHA256['core/scripts/local_ci_container.sh'],'3cfa328b0029c2b62866fa55d75b2a73b77518766ed7ca6206ae65955dbdef24'}
PLAN=re.compile(r'^local-ci: running ([1-9][0-9]*) ExUnit partitions concurrently, ([1-9][0-9]*) schedulers each, on ([1-9][0-9]*) allocated CPUs, memory budget ([1-9][0-9]*) bytes, 1 active run\(s\); lint and quality follow, then Restic$')
LANE=re.compile(r'^local-ci: (units-[1-9][0-9]*|lint|quality|restic-integration) exit ([0-9]+) after ([0-9]+)s$')


def verify_profile(hashes):
 if (not isinstance(hashes,dict) or set(hashes)!=set(PROFILE_SHA256) or hashes.get('core/scripts/local_ci_container.sh') not in WRAPPER_SHA256
     or any(hashes.get(key)!=value for key,value in PROFILE_SHA256.items() if key!='core/scripts/local_ci_container.sh')):raise ValueError('UNSUPPORTED_CURRENT_CORE_SCRIPT_PROFILE')
 return PROFILE


def validate_lanes(output,expected_plan,exit_code):
 """Use authored durable all-lane completion, not short-lived process polling."""
 if not isinstance(output,str) or len(output.encode())>16*1024**2:raise ValueError('OBSERVED_CORE_LOG_BOUND')
 if (not isinstance(expected_plan,list) or len(expected_plan)!=4 or any(type(x) is not int or x<1 for x in expected_plan)
     or expected_plan[0]>128 or type(exit_code) is not int or exit_code!=0):raise ValueError('OBSERVED_CORE_SUCCESS_NOT_PROVEN')
 plans=[];lanes=[]
 for line in output.splitlines():
  plan=PLAN.fullmatch(line)
  if plan:plans.append(list(map(int,plan.groups())))
  lane=LANE.fullmatch(line)
  if lane:lanes.append(dict(name=lane[1],exit_code=int(lane[2]),seconds=int(lane[3])))
 expected=['units-'+str(n) for n in range(1,expected_plan[0]+1)]+['lint','quality','restic-integration']
 if plans!=[expected_plan] or [row['name'] for row in lanes]!=expected or any(row['exit_code'] for row in lanes):raise ValueError('OBSERVED_CORE_FULL_LANES_NOT_PROVEN')
 return dict(profile=PROFILE,workload_started=True,plan=expected_plan,lanes=lanes,exit_code=exit_code)

# Runtime observation stays inside Farm's charged worker and its private daemon.
# These projections deliberately exclude Config.Env and every credential field.
import http.client
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import sys
import threading
import stat
import time
import urllib.parse
from fractions import Fraction

ROOT=Path('/workspace/source')
INSPECT='{"id":{{json .Id}},"name":{{json .Name}},"image":{{json .Image}},"command":{{json .Config.Cmd}},"entrypoint":{{json .Config.Entrypoint}},"memory":{{.HostConfig.Memory}},"nanocpus":{{.HostConfig.NanoCpus}},"privileged":{{.HostConfig.Privileged}},"pidmode":{{json .HostConfig.PidMode}},"cgroupns":{{json .HostConfig.CgroupnsMode}},"pid":{{.State.Pid}},"running":{{.State.Running}},"mounts":{{json .Mounts}}}'
INNER_PROBE='''import hashlib,json,runpy,subprocess
from pathlib import Path
p=Path('/workspace/repo/core/scripts/local_ci_resources.py')
m=runpy.run_path(str(p));v=m['resources']();cpu,memory,affinity,physical=v
print(json.dumps(dict(cpu_numerator=cpu.numerator if cpu is not None else None,cpu_denominator=cpu.denominator if cpu is not None else None,memory=memory,affinity=affinity,physical=physical,plan=list(m['partition_plan'](v,1)),head=subprocess.check_output(['git','-C','/workspace/repo','rev-parse','HEAD'],text=True).strip(),base=subprocess.check_output(['git','-C','/workspace/repo','rev-parse','refs/remotes/origin/main'],text=True).strip(),runner_sha256=hashlib.sha256(Path('/runner.sh').read_bytes()).hexdigest(),planner_sha256=hashlib.sha256(p.read_bytes()).hexdigest())))'''


def capture(argv,timeout=15,limit=65536):
 p=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=timeout)
 if p.returncode or len(p.stdout)>limit:raise ValueError('OBSERVED_CORE_COMMAND_FAILED_OR_BOUND')
 return p.stdout


def current_profile(root):
 hashes={}
 for name in PROFILE_SHA256:
  descriptor=os.open(root/name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
  with os.fdopen(descriptor,'rb') as stream:
   info=os.fstat(stream.fileno())
   if not stat.S_ISREG(info.st_mode) or info.st_size>2*1024**2:raise ValueError('OBSERVED_CORE_SCRIPT_BOUND')
   data=stream.read(2*1024**2+1)
   if len(data)>2*1024**2:raise ValueError('OBSERVED_CORE_SCRIPT_BOUND')
   hashes[name]=hashlib.sha256(data).hexdigest()
 verify_profile(hashes)
 return hashes


def image_reference(root,commit):
 # The reviewed exact wrapper owns these inputs and options. This adapter does
 # not substitute an image recipe or build another source tree.
 text=(root/'core/scripts/local_ci_container.sh').read_text()
 found=re.findall(r'^image_inputs=\((.*?)\)',text,re.M|re.S)
 if len(found)!=1:raise ValueError('OBSERVED_CORE_IMAGE_RECIPE_CHANGED')
 paths=found[0].split()
 expected=['core/deploy/Dockerfile.build','package.json','core/scripts/verify_beam_runtime.sh','core/native/bsdtar/zip-permissions.patch','core/native/7zip/zip-permissions.patch']
 if paths!=expected:raise ValueError('OBSERVED_CORE_IMAGE_RECIPE_CHANGED')
 tree=capture(['git','-C',str(root),'ls-tree',commit,'--',*paths])
 options=b'--platform\nlinux/amd64\n--target\nlocal-test\n--build-arg\nBUILD_BASE=fedora-base\n'
 key=hashlib.sha1(b'blob '+str(len(options+tree)).encode()+b'\0'+options+tree).hexdigest()
 return 'core-local-ci-fedora-x86_64:inputs-'+key,key


class UnixDocker(http.client.HTTPConnection):
 def __init__(self):super().__init__('localhost',timeout=5)
 def connect(self):
  self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);self.sock.settimeout(5);self.sock.connect('/var/run/docker.sock')



def require_missing_image(reference):
 connection=UnixDocker()
 try:
  connection.request('GET','/_ping');response=connection.getresponse();body=response.read(1025)
  if response.status!=200 or body!=b'OK':raise ValueError('OBSERVED_CORE_DOCKER_RESPONSE_REQUIRED')
  connection.request('GET','/images/'+urllib.parse.quote(reference,safe='')+'/json')
  response=connection.getresponse()
  if response.status==200:raise ValueError('OBSERVED_CORE_UNPROVEN_PREEXISTING_IMAGE')
  if response.status!=404:raise ValueError('OBSERVED_CORE_IMAGE_ABSENCE_NOT_PROVEN')
  body=response.read(65537)
  if len(body)>65536:raise ValueError('OBSERVED_CORE_IMAGE_ABSENCE_NOT_PROVEN')
  missing=json.loads(body).get('message')
  if not isinstance(missing,str) or missing!='No such image: '+reference:raise ValueError('OBSERVED_CORE_IMAGE_ABSENCE_NOT_PROVEN')
 finally:connection.close()


def inner_ancestry(pid,cpus,memory):
 if type(pid) is not int or pid<1:raise ValueError('OBSERVED_CORE_INNER_PID_INVALID')
 lines=Path('/proc',str(pid),'cgroup').read_text().splitlines()
 unified=[line[3:] for line in lines if line.startswith('0::')]
 if len(unified)!=1:raise ValueError('OBSERVED_CORE_CGROUP_UNIDENTIFIABLE')
 mount=Path('/sys/fs/cgroup');group=(mount/unified[0].lstrip('/')).resolve()
 if not group.is_relative_to(mount.resolve()):raise ValueError('OBSERVED_CORE_CGROUP_ESCAPE')
 nodes=[];cpu=None;mem=None
 while True:
  quota,period=(group/'cpu.max').read_text().split();raw=(group/'memory.max').read_text().strip()
  if quota!='max':
   if not quota.isdigit() or not period.isdigit() or int(quota)<1 or int(period)<1:raise ValueError('OBSERVED_CORE_CGROUP_CPU_INVALID')
   value=Fraction(int(quota),int(period));cpu=value if cpu is None else min(cpu,value)
  if raw!='max':
   if not raw.isdigit() or int(raw)<1:raise ValueError('OBSERVED_CORE_CGROUP_MEMORY_INVALID')
   mem=int(raw) if mem is None else min(mem,int(raw))
  nodes.append(dict(path=str(group.relative_to(mount)),cpu=quota+' '+period,memory=raw))
  if group==mount:break
  if len(nodes)>64:raise ValueError('OBSERVED_CORE_CGROUP_DEPTH_BOUND')
  group=group.parent
 if cpu!=cpus or mem!=memory:raise ValueError('OBSERVED_CORE_EFFECTIVE_LIMITS_MISMATCH')
 # The namespace root is the charged outer worker, not the engine allocation.
 root_cpu,root_period=(mount/'cpu.max').read_text().split();root_memory=(mount/'memory.max').read_text().strip()
 if root_cpu=='max' or Fraction(int(root_cpu),int(root_period))!=cpus or root_memory!=str(memory):raise ValueError('OBSERVED_CORE_OUTER_LIMITS_MISMATCH')
 return nodes


class DockerObserver:
 def __init__(self,root,commit,base,cpus,memory):
  self.root=root;self.commit=commit;self.base=base;self.cpus=cpus;self.memory=memory
  raw=str(root).encode();identity=hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
  self.name='core-local-ci-'+identity[:16]+'-fedora-x86_64'
  self.volume='core-local-ci-work-'+identity[:16]+'-fedora-x86_64'
  self.expected_image=None;self.checks=None;self.exit_code=None;self.error=None;self.events=0;self.stopping=False
  self.guard=threading.RLock()
  self.connection=UnixDocker()
  query=urllib.parse.urlencode({'filters':json.dumps({'type':['container']},separators=(',',':'))})
  try:
   self.connection.request('GET','/events?'+query)
   self.response=self.connection.getresponse()
   if self.response.status!=200:raise ValueError('OBSERVED_CORE_EVENT_HANDSHAKE_FAILED')
   self.socket=self.connection.sock
   if self.socket is None:raise ValueError('OBSERVED_CORE_EVENT_SOCKET_MISSING')
   self.socket.settimeout(None)
  except Exception:
   self.connection.close();raise
  self.thread=threading.Thread(target=self.read,daemon=True);self.thread.start()
 def read(self):
  try:
   while not self.stopping:
    line=self.response.readline(65537)
    if not line:
     if not self.stopping:raise ValueError('OBSERVED_CORE_EVENT_STREAM_LOST')
     break
    if len(line)>65536:raise ValueError('OBSERVED_CORE_EVENT_BOUND')
    event=json.loads(line);self.events+=1
    if self.events>512:raise ValueError('OBSERVED_CORE_EVENT_COUNT_BOUND')
    identity=event.get('id') or event.get('Actor',{}).get('ID');action=event.get('Action') or event.get('status')
    if not isinstance(identity,str) or not re.fullmatch('[0-9a-f]{64}',identity):continue
    if action=='start':self.started(identity)
    elif action=='die' and self.checks is not None and identity==self.checks['container']['id']:
     code=event.get('Actor',{}).get('Attributes',{}).get('exitCode')
     if not isinstance(code,str) or not code.isdigit():raise ValueError('OBSERVED_CORE_DOCKER_EXIT_MISSING')
     self.exit_code=int(code)
  except Exception as exc:
   if not self.stopping:self.error=failure_code(exc)
 def started(self,identity):
  item=json.loads(capture(['docker','container','inspect','--format',INSPECT,identity]))
  if item.get('name')!='/'+self.name:return
  command=item.get('command')
  if (not isinstance(command,list) or len(command)!=4 or command[0]!='/runner.sh'
      or command[1] not in ('monaco','setup','checks') or command[2:]!=[self.commit,self.base]
      or item.get('entrypoint')!=['/bin/bash'] or item.get('memory')!=self.memory or item.get('nanocpus')!=self.cpus*10**9
      or item.get('privileged') is not False or item.get('pidmode') not in ('','private') or item.get('cgroupns')!='private'):
   raise ValueError('OBSERVED_CORE_CONTAINER_MISMATCH')
  mounts=item.get('mounts')
  if not isinstance(mounts,list):raise ValueError('OBSERVED_CORE_MOUNTS_MISSING')
  by_destination={row.get('Destination'):row for row in mounts}
  for destination,source in [('/source.git',str(self.root/'.git')),('/runner.sh',str(self.root/'core/scripts/local_ci_linux.sh'))]:
   row=by_destination.get(destination,{})
   if row.get('Type')!='bind' or row.get('Source')!=source or row.get('RW') is not False:raise ValueError('OBSERVED_CORE_SOURCE_MOUNT_MISMATCH')
  if any('docker.sock' in str(row.get('Source','')) for row in mounts):raise ValueError('OBSERVED_CORE_HOST_SOCKET_EXPOSED')
  workspace=by_destination.get('/workspace',{})
  if workspace.get('Type')!='volume' or workspace.get('Name')!=self.volume:raise ValueError('OBSERVED_CORE_WORKSPACE_MISMATCH')
  if command[1]!='checks':return
  if item.get('image')!=self.expected_image:raise ValueError('OBSERVED_CORE_CHECKS_IMAGE_OR_DUPLICATE')
  with self.guard:
   if self.checks is not None and self.checks['container']['id']!=identity:raise ValueError('OBSERVED_CORE_CHECKS_IMAGE_OR_DUPLICATE')
   if self.checks is None:self.checks=dict(container=item)
 def prove_plan(self,plan):
  # This authored durable line follows checkout/reset and resource planning. A
  # Docker start event alone does not prove source readiness. Re-inspect this
  # exact live container, then probe its settled source/allocation.
  current=json.loads(capture(['docker','container','inspect','--format',INSPECT,self.name]))
  self.started(current['id'])
  with self.guard:
   if self.checks is None or self.checks['container']['id']!=current.get('id') or current.get('running') is not True:raise ValueError('OBSERVED_CORE_LIVE_CHECKS_IDENTITY_CHANGED')
   item=self.checks['container'];identity=item['id']
  if any(current.get(k)!=item.get(k) for k in ('id','image','command','pid','memory','nanocpus','mounts')):raise ValueError('OBSERVED_CORE_LIVE_CHECKS_IDENTITY_CHANGED')
  ancestry=inner_ancestry(item.get('pid'),self.cpus,self.memory)
  inner=json.loads(capture(['docker','exec',identity,'python3','-c',INNER_PROBE],timeout=30,limit=16384))
  if (inner.get('head')!=self.commit or inner.get('base')!=self.base or inner.get('runner_sha256')!=PROFILE_SHA256['core/scripts/local_ci_linux.sh']
      or inner.get('planner_sha256')!=PROFILE_SHA256['core/scripts/local_ci_resources.py'] or inner.get('cpu_numerator')!=self.cpus
      or inner.get('cpu_denominator')!=1 or inner.get('memory')!=self.memory):raise ValueError('OBSERVED_CORE_INNER_SOURCE_OR_LIMITS_CHANGED')
  if inner.get('plan')!=plan:raise ValueError('OBSERVED_CORE_DURABLE_PLAN_CHANGED')
  with self.guard:self.checks=dict(container=current,ancestry=ancestry,inner=inner)
 def close(self):
  self.stopping=True
  try:self.socket.shutdown(socket.SHUT_RDWR)
  except OSError:pass
  try:
   self.thread.join(timeout=5)
   if self.thread.is_alive():raise ValueError('OBSERVED_CORE_EVENT_CLEANUP_UNCERTAIN')
  finally:self.connection.close()


def run_wrapper(mode,commit,base,environment,observer,deadline):
 child=subprocess.Popen(['bash',str(ROOT/'core/scripts/local_ci_container.sh'),mode,commit,base],cwd=ROOT,env=environment,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 output=bytearray();pending=b'';poll=selectors.DefaultSelector();poll.register(child.stdout,selectors.EVENT_READ)
 try:
  while poll.get_map() or child.poll() is None:
   if observer.error:raise ValueError(observer.error)
   if time.monotonic()>deadline:raise ValueError('OBSERVED_CORE_DEADLINE_EXPIRED')
   for key,_ in poll.select(.2):
    data=os.read(key.fileobj.fileno(),65536)
    if not data:poll.unregister(key.fileobj);continue
    output.extend(data)
    if len(output)>16*1024**2:raise ValueError('OBSERVED_CORE_OUTPUT_BOUND')
    sys.stdout.buffer.write(data);sys.stdout.buffer.flush()
    if mode=='checks':
     pending+=data
     while b'\n' in pending:
      line,pending=pending.split(b'\n',1)
      parsed=PLAN.fullmatch(line.decode('utf-8','replace'))
      if parsed:observer.prove_plan(list(map(int,parsed.groups())))
     if len(pending)>16*1024**2:raise ValueError('OBSERVED_CORE_LOG_LINE_BOUND')
  return child.wait(timeout=5),bytes(output)
 finally:
  if child.poll() is None:
   child.terminate()
   try:child.wait(timeout=5)
   except subprocess.TimeoutExpired:child.kill();child.wait(timeout=5)
  poll.close();child.stdout.close()


def main(arguments):
 if len(arguments)!=5 or any(not re.fullmatch('[0-9a-f]{40}',x) for x in arguments[:2]):raise ValueError('OBSERVED_CORE_CLOSED_ARGUMENTS_REQUIRED')
 commit,base=arguments[:2];cpus,memory,timeout=map(int,arguments[2:])
 if not 1<=cpus<=32 or not 4*1024**3<=memory<=128*1024**3 or not 1<=timeout<=7200:raise ValueError('OBSERVED_CORE_FINITE_BUDGET_REQUIRED')
 if sys.platform!='linux' or os.environ.get('DOCKER_HOST') not in (None,'','unix:///var/run/docker.sock') or os.environ.get('DOCKER_CONTEXT'):raise ValueError('OBSERVED_CORE_PRIVATE_LINUX_DAEMON_REQUIRED')
 hashes=current_profile(ROOT)
 if capture(['git','-C',str(ROOT),'rev-parse','HEAD']).decode().strip()!=commit or capture(['git','-C',str(ROOT),'status','--porcelain','--untracked-files=all']):raise ValueError('OBSERVED_CORE_SOURCE_CHANGED')
 reference,image_key=image_reference(ROOT,commit)
 require_missing_image(reference)
 token=os.environ.pop('EX_STANDARDS_TOKEN','')
 if not 8<=len(token)<=4096 or any(c in token for c in '\r\n\x00'):raise ValueError('OBSERVED_CORE_PROCESS_CREDENTIAL_REQUIRED')
 environment=dict(os.environ,EX_STANDARDS_TOKEN=token,CORE_SKIP_AUTOMATIC_CLEANUP='1')
 deadline=time.monotonic()+timeout;observer=DockerObserver(ROOT,commit,base,cpus,memory)
 try:
  setup,_=run_wrapper('setup',commit,base,environment,observer,deadline)
  if setup:return setup
  image=capture(['docker','image','inspect','--format','{{.Id}}',reference]).decode().strip()
  if not re.fullmatch('sha256:[0-9a-f]{64}',image):raise ValueError('OBSERVED_CORE_IMAGE_INVALID')
  observer.expected_image=image
  code,log=run_wrapper('checks',commit,base,environment,observer,deadline)
  if code:return code
  exit_observation_deadline=min(deadline,time.monotonic()+3)
  while observer.exit_code is None and not observer.error and time.monotonic()<exit_observation_deadline:time.sleep(.05)
  if observer.error or observer.checks is None or observer.exit_code!=code:raise ValueError('OBSERVED_CORE_ACTUAL_CHECKS_EXIT_NOT_PROVEN')
  lanes=validate_lanes(log.decode('utf-8','replace'),observer.checks['inner']['plan'],code)
  current_profile(ROOT)
  receipt=dict(version=1,profile=PROFILE,commit=commit,base=base,script_sha256=hashes,image_ref=reference,image_key=image_key,image=image,observed=observer.checks,docker_exit_code=observer.exit_code)
  receipt.update(lanes)
  print('CORE_OBSERVED_RESOURCE_V1 '+json.dumps(receipt,separators=(',',':')),flush=True)
  return code
 finally:observer.close()


def failure_code(exc):
 value=str(exc)
 return value if isinstance(exc,ValueError) and re.fullmatch('[A-Z][A-Z0-9_]{1,100}',value) else 'OBSERVED_CORE_INTERNAL_OR_TRANSPORT_FAILURE'


if __name__=='__main__':
 try:sys.exit(main(sys.argv[1:]))
 except Exception as exc:
  print('observed_current_core_proof_failed: '+failure_code(exc),file=sys.stderr);sys.exit(78)
