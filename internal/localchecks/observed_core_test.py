import importlib.util
from pathlib import Path
import unittest
import io
import json
import tempfile
import threading
import http.server
import socketserver
import socket
import shlex
import os
import time
from types import SimpleNamespace
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('observed_core',Path(__file__).with_name('observed_core.py'))
o=importlib.util.module_from_spec(spec);spec.loader.exec_module(o)

class ObservedCurrentCore(unittest.TestCase):
 def log(self):
  return '\n'.join(['local-ci: running 2 ExUnit partitions concurrently, 1 schedulers each, on 2 allocated CPUs, memory budget 12884901888 bytes, 1 active run(s); lint and quality follow, then Restic']+[f'local-ci: {name} exit 0 after 1s' for name in ['units-1','units-2','lint','quality','restic-integration']])+'\n'
 def test_durable_actual_all_lane_completion_proves_units_started(self):
  result=o.validate_lanes(self.log(),[2,1,2,12884901888],0)
  self.assertTrue(result['workload_started']);self.assertEqual(len(result['lanes']),5)
 def test_missing_duplicate_failed_or_changed_plan_is_not_acceptance(self):
  for text,plan,code in [(self.log().replace('local-ci: units-2 exit 0 after 1s\n',''),[2,1,2,12884901888],0),(self.log()+'local-ci: lint exit 0 after 1s\n',[2,1,2,12884901888],0),(self.log().replace('units-2 exit 0','units-2 exit 1'),[2,1,2,12884901888],0),(self.log(),[1,2,2,12884901888],0),(self.log(),[2,1,2,12884901888],1)]:
   with self.subTest(text=text,plan=plan,code=code),self.assertRaises(ValueError):o.validate_lanes(text,plan,code)
 def test_preloop_plan_without_completed_lanes_does_not_prove_units(self):
  with self.assertRaises(ValueError):o.validate_lanes(self.log().splitlines()[0]+'\n',[2,1,2,12884901888],0)
 def test_reviewed_script_profile_is_exact_and_separate_from_v1(self):
  self.assertEqual(o.verify_profile(dict(o.PROFILE_SHA256)),o.PROFILE)
  for key in o.PROFILE_SHA256:
   changed=dict(o.PROFILE_SHA256);changed[key]='f'*64
   with self.assertRaises(ValueError):o.verify_profile(changed)

 def test_image_absence_requires_responding_daemon_and_exact_404(self):
  class Response:
   def __init__(self,status,body):self.status=status;self.body=body
   def read(self,bound):return self.body[:bound]
  class Connection:
   def __init__(self,responses):self.responses=iter(responses)
   def request(self,*args):pass
   def getresponse(self):return next(self.responses)
   def close(self):pass
  reference='fixture:inputs-'+'a'*40
  good=[Response(200,b'OK'),Response(404,json.dumps({'message':'No such image: '+reference}).encode())]
  with patch.object(o,'UnixDocker',return_value=Connection(good)):o.require_missing_image(reference)
  for responses in ([Response(403,b'forbidden')],[Response(200,b'wrong')],[Response(200,b'OK'),Response(403,b'forbidden')],[Response(200,b'OK'),Response(404,b'{"message":"route not found"}')],[Response(200,b'OK'),Response(200,b'private image metadata must not be read')]):
   with self.subTest(responses=responses),patch.object(o,'UnixDocker',return_value=Connection(responses)),self.assertRaises(ValueError):o.require_missing_image(reference)
 def test_composed_start_before_checkout_waits_for_authored_plan_line(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);scripts=root/'core/scripts';scripts.mkdir(parents=True)
   ready=root/'settled';wrapper=scripts/'local_ci_container.sh'
   wrapper.write_text('#!/bin/bash\nset -eu\n: > '+str(ready)+'\ncat <<\'LANES\'\n'+self.log()+'LANES\n')
   commit='a'*40;base='b'*40;identity='c'*64;image='sha256:'+'d'*64
   observer=o.DockerObserver.__new__(o.DockerObserver)
   observer.root=root;observer.commit=commit;observer.base=base;observer.cpus=2;observer.memory=12884901888;observer.name='fixture';observer.volume='fixture-volume';observer.expected_image=image;observer.checks=None;observer.error=None;observer.guard=threading.RLock()
   item=dict(id=identity,name='/fixture',image=image,command=['/runner.sh','checks',commit,base],entrypoint=['/bin/bash'],memory=12884901888,nanocpus=2*10**9,privileged=False,pidmode='',cgroupns='private',pid=123,running=True,mounts=[dict(Destination='/source.git',Type='bind',Source=str(root/'.git'),RW=False),dict(Destination='/runner.sh',Type='bind',Source=str(root/'core/scripts/local_ci_linux.sh'),RW=False),dict(Destination='/workspace',Type='volume',Name='fixture-volume')])
   inner=dict(head=commit,base=base,runner_sha256=o.PROFILE_SHA256['core/scripts/local_ci_linux.sh'],planner_sha256=o.PROFILE_SHA256['core/scripts/local_ci_resources.py'],cpu_numerator=2,cpu_denominator=1,memory=12884901888,plan=[2,1,2,12884901888])
   probes=[]
   def capture(argv,**kwargs):
    if argv[:2]==['docker','exec']:
     probes.append(identity)
     self.assertTrue(ready.exists(),'source/planner probed before authored checkout/reset settled')
     return json.dumps(inner).encode()
    return json.dumps(item).encode()
   with patch.object(o,'capture',side_effect=capture),patch.object(o,'inner_ancestry',return_value=[{'fixture':'actual-kernel-reader-tested-separately'}]),patch.object(o,'ROOT',root),patch.object(o.sys,'stdout',SimpleNamespace(buffer=io.BytesIO())):
    observer.started(identity)
    self.assertEqual(probes,[])
    code,log=o.run_wrapper('checks',commit,base,{},observer,o.time.monotonic()+5)
   self.assertEqual(code,0);self.assertEqual(probes,[identity]);self.assertEqual(observer.checks['inner'],inner)
   self.assertTrue(o.validate_lanes(log.decode(),inner['plan'],code)['workload_started'])

 def test_composed_runtime_uses_real_unix_event_handshake_and_authored_lanes(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);scripts=root/'core/scripts';scripts.mkdir(parents=True)
   events=root/'events.jsonl';events.touch();proof=root/'proof';settled=root/'settled';stop=threading.Event()
   commit='a'*40;base='b'*40;identity='c'*64;image='sha256:'+'d'*64;reference='fixture:inputs-'+'e'*40
   class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args):pass
    def do_GET(self):
     if self.path=='/_ping':body=b'OK';status=200
     elif self.path.startswith('/images/'):
      body=json.dumps({'message':'No such image: '+reference}).encode();status=404
     elif self.path.startswith('/events?'):
      self.send_response(200);self.send_header('Transfer-Encoding','chunked');self.end_headers();self.wfile.flush()
      offset=0;deadline=time.monotonic()+8
      while not stop.is_set() and time.monotonic()<deadline:
       with events.open('rb') as stream:stream.seek(offset);data=stream.read();offset=stream.tell()
       for line in data.splitlines(keepends=True):
        self.wfile.write(('%x\r\n'%len(line)).encode()+line+b'\r\n');self.wfile.flush()
       stop.wait(.01)
      return
     else:body=b'{}';status=404
     self.send_response(status);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);self.wfile.flush()
   class Server(socketserver.ThreadingMixIn,socketserver.UnixStreamServer):
    daemon_threads=True
    def handle_error(self,*args):pass
   server=Server(str(root/'engine.sock'),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
   def connect(connection):
    connection.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);connection.sock.settimeout(5);connection.sock.connect(str(root/'engine.sock'))
   started=json.dumps(dict(Type='container',Action='start',Actor=dict(ID=identity)))
   died=json.dumps(dict(Type='container',Action='die',Actor=dict(ID=identity,Attributes=dict(exitCode='0'))))
   body='#!/bin/bash\nset -eu\ntest "$EX_STANDARDS_TOKEN" = fixture-private-runtime\nif [ "$1" = setup ]; then exit 0; fi\n'
   body+='printf \'%s\\n\' '+shlex.quote(started)+' >> '+shlex.quote(str(events))+'\n: > '+shlex.quote(str(settled))+'\n'
   body+='cat <<\'PLAN\'\n'+self.log().splitlines()[0]+'\nPLAN\n'
   body+='for count in $(seq 1 500); do [ ! -e '+shlex.quote(str(proof))+' ] || break; sleep .01; done\ntest -e '+shlex.quote(str(proof))+'\n'
   body+='cat <<\'LANES\'\n'+'\n'.join(self.log().splitlines()[1:])+'\nLANES\n'
   body+='printf \'%s\\n\' '+shlex.quote(died)+' >> '+shlex.quote(str(events))+'\n'
   (scripts/'local_ci_container.sh').write_text(body)
   raw=str(root).encode();key=o.hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
   item=dict(id=identity,name='/core-local-ci-'+key[:16]+'-fedora-x86_64',image=image,command=['/runner.sh','checks',commit,base],entrypoint=['/bin/bash'],memory=12884901888,nanocpus=2*10**9,privileged=False,pidmode='',cgroupns='private',pid=123,running=True,mounts=[dict(Destination='/source.git',Type='bind',Source=str(root/'.git'),RW=False),dict(Destination='/runner.sh',Type='bind',Source=str(scripts/'local_ci_linux.sh'),RW=False),dict(Destination='/workspace',Type='volume',Name='core-local-ci-work-'+key[:16]+'-fedora-x86_64')])
   inner=dict(head=commit,base=base,runner_sha256=o.PROFILE_SHA256['core/scripts/local_ci_linux.sh'],planner_sha256=o.PROFILE_SHA256['core/scripts/local_ci_resources.py'],cpu_numerator=2,cpu_denominator=1,memory=12884901888,affinity=16,physical=32*1024**3,plan=[2,1,2,12884901888])
   def capture(argv,**kwargs):
    self.assertNotIn('fixture-private-runtime',' '.join(argv))
    if argv[0]=='git':return b'' if 'status' in argv else (commit+'\n').encode()
    if argv[:3]==['docker','image','inspect']:return image.encode()
    if argv[:2]==['docker','exec']:
     self.assertTrue(settled.exists());proof.touch();return json.dumps(inner).encode()
    return json.dumps(item).encode()
   class Sink(io.StringIO):
    def __init__(self):super().__init__();self.buffer=io.BytesIO()
   sink=Sink()
   try:
    with patch.object(o,'ROOT',root),patch.object(o,'capture',side_effect=capture),patch.object(o,'current_profile',return_value=dict(o.PROFILE_SHA256)),patch.object(o,'image_reference',return_value=(reference,'e'*40)),patch.object(o.UnixDocker,'connect',connect),patch.object(o,'inner_ancestry',return_value=[dict(path='docker/'+identity,cpu='200000 100000',memory='12884901888'),dict(path='docker',cpu='max 100000',memory='max'),dict(path='.',cpu='200000 100000',memory='12884901888')]),patch.object(o.sys,'stdout',sink),patch.dict(os.environ,{'EX_STANDARDS_TOKEN':'fixture-private-runtime','DOCKER_HOST':'unix:///var/run/docker.sock','DOCKER_CONTEXT':''}):
     self.assertEqual(o.main([commit,base,'2','12884901888','5']),0)
    record=json.loads(sink.getvalue().split('CORE_OBSERVED_RESOURCE_V1 ',1)[1]);self.assertEqual(record['docker_exit_code'],0);self.assertEqual(record['observed']['container']['id'],identity);self.assertTrue(record['workload_started']);self.assertEqual(len(record['lanes']),5)
    self.assertNotIn('fixture-private-runtime',sink.getvalue());self.assertNotIn(b'fixture-private-runtime',sink.buffer.getvalue())
   finally:stop.set();server.shutdown();server.server_close();thread.join(timeout=2)

if __name__=='__main__':unittest.main()
