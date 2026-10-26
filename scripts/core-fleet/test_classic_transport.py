import importlib.util,json,os,pathlib,subprocess,tempfile,threading,time,unittest
from classic_transport import Operation,file_digest,exclusive,private_read,operation_from_binding,handle_request
from unittest.mock import patch
import copy

class ClassicTransportTest(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.build=tempfile.TemporaryDirectory(prefix='farm-classic-fixture-');root=pathlib.Path(cls.build.name)
  source=root/'main.go';source.write_text('''package main
import("os";"io";"encoding/json";"bytes";"os/signal";"syscall";"strings";"time")
func main(){if len(os.Args)!=2||os.Args[1]!="local-checks"{os.Exit(9)};if _,e:=os.Stat("/proc/self/fd/8");e!=nil{os.Exit(8)};raw,_:=io.ReadAll(os.Stdin);parts:=bytes.SplitN(raw,[]byte("\\n"),2);var c map[string]interface{};if json.Unmarshal(parts[0],&c)!=nil{os.Exit(7)};if c["action"]=="execute" {if c["requestID"]=="ffffffffffffffffffffffffffffffff"{signal.Ignore(syscall.SIGTERM);os.Stdout.Write([]byte("ready"));time.Sleep(2500*time.Millisecond);return};if c["requestID"]=="cccccccccccccccccccccccccccccccc"{signals:=make(chan os.Signal,1);signal.Notify(signals,syscall.SIGTERM);<-signals;os.Stdout.Write([]byte("{\\"cancelled\\":true}\\n"));return};if c["requestID"]=="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"{json.NewEncoder(os.Stdout).Encode(map[string]string{"large":strings.Repeat("x",70000)});return};json.NewEncoder(os.Stdout).Encode(map[string]string{"reflected":string(parts[1])});return};os.Stdout.Write([]byte("{\\"ok\\":true}\\n"))}
''');cls.binary=root/'capacity';e=dict(os.environ,GOMAXPROCS='2',GOFLAGS='-p=2');subprocess.run(['go','build','-o',str(cls.binary),str(source)],check=True,capture_output=True,timeout=30,env=e)
 @classmethod
 def tearDownClass(cls):cls.build.cleanup()
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='farm-classic-operation-');self.addCleanup(self.tmp.cleanup);self.root=pathlib.Path(self.tmp.name)
 def operation(self,action='qualify',request='a'*32,operation='b'*32,timeout=3,cleanup_timeout=2):
  task=self.root/request;task.mkdir(mode=0o700,exist_ok=True);wrapper=self.root/'wrapper'
  wrapper.write_text('#!/bin/bash\nset -eu\nexec 8>"'+str(self.root/'fleet.lock')+'"\nflock 8\nexec "'+str(self.binary)+'" "$@"\n');wrapper.chmod(0o700)
  command={'protocol':'farm-local-checks-worker/v1','action':action,'epoch':'e'*32}
  if action=='qualify':command['submission']={'version':1,'repository':'unraid/core','commit':'f'*40,'base':'f'*40,'bundleSHA256':'1'*64,'requestID':request,'cpus':2,'memoryMiB':12288,'timeoutSeconds':180,'scratchMiB':1024}
  else:command['requestID']=request
  return Operation(task,operation,command,wrapper,self.binary,{'wrapperSHA256':file_digest(wrapper),'capacitySHA256':file_digest(self.binary)},'sha256:'+'2'*64,timeout=timeout,cleanup_timeout=cleanup_timeout)
 def test_run_exact_owner_and_lost_response_is_observed_without_replay(self):
  op=self.operation();result=op.run();self.assertEqual(result['state'],'terminal');self.assertEqual(result['response'],{'ok':True});self.assertEqual(op.run(),result)
 def test_uncertain_intent_blocks_new_process_and_wrong_operation(self):
  op=self.operation();exclusive(op.intent_path,op.intent);self.assertEqual(op.run()['state'],'inspect_required')
  other=self.operation(operation='d'*32)
  with self.assertRaisesRegex(ValueError,'CLASSIC_OPERATION_OWNER_MISMATCH'):other.status()
 def test_cancel_delivered_by_original_owner_once(self):
  op=self.operation('execute','c'*32);result=[];thread=threading.Thread(target=lambda:result.append(op.run(b'fixture-dependency-token')));thread.start()
  limit=time.monotonic()+2
  while not op.intent_path.exists() and time.monotonic()<limit:time.sleep(.01)
  time.sleep(.2);op.cancel();op.cancel();thread.join(4);self.assertFalse(thread.is_alive());self.assertTrue(result[0]['cancelAcknowledged']);self.assertEqual(result[0]['response'],{'cancelled':True})
 def test_secret_is_stdin_only_and_never_persisted(self):
  op=self.operation('execute','d'*32);secret=b'fixture-private-credential';result=op.run(secret);self.assertEqual(result['response']['reflected'],'[REDACTED]')
  for p in op.task.iterdir():self.assertNotIn(secret,p.read_bytes())
 def test_json_escaped_dependency_is_redacted_after_decoding(self):
  op=self.operation('execute','d'*32);secret=b'fixture-quote-"-slash-\\-token'
  result=op.run(secret);self.assertEqual(result['response']['reflected'],'[REDACTED]')
  for path in op.task.iterdir():
   self.assertNotIn(secret,path.read_bytes());self.assertNotIn(json.dumps(secret.decode())[1:-1].encode(),path.read_bytes())
 def test_replaced_installed_helper_refused_before_intent(self):
  op=self.operation();op.wrapper.write_text('#!/bin/sh\nexit 1\n')
  with self.assertRaisesRegex(ValueError,'CLASSIC_INSTALLATION_CHANGED'):op.run()
  self.assertFalse(op.intent_path.exists())
 def test_fifo_receipt_does_not_block(self):
  op=self.operation();os.mkfifo(op.intent_path,0o600)
  with self.assertRaisesRegex(ValueError,'CLASSIC_PRIVATE_RECEIPT_INVALID'):op.status()
 def test_oversized_result_is_inspect_required_and_status_remains_readable(self):
  op=self.operation('execute','e'*32);result=op.run(b'fixture-dependency-token');self.assertEqual(result['state'],'inspect_required');self.assertEqual(result['reason'],'CLASSIC_RESPONSE_BOUND_EXCEEDED');self.assertEqual(op.status(),result);self.assertLess(op.result_path.stat().st_size,65536)
 def test_cancel_after_terminal_returns_terminal_without_creating_marker(self):
  op=self.operation();result=op.run();self.assertEqual(op.cancel(),result);self.assertFalse(op.cancel_path.exists())
 def release(self,op):
  return {'version':1,'epoch':op.command['epoch'],'state':'released','request':op.command['submission'],'worker':{'image':op.image,'sourceRoot':str(op.task/'repo'),'dockerRoot':str(op.task/'docker')},'containerID':'3'*64}
 def test_recovery_requires_exact_released_receipt_and_positive_absence(self):
  op=self.operation();exclusive(op.intent_path,op.intent);receipt=self.release(op);seen=[]
  result=op.recover(receipt,lambda identity:seen.append(identity) or True)
  self.assertEqual(seen,['3'*64]);self.assertEqual(result['state'],'released_observed');self.assertFalse(result['workloadSuccessProven']);self.assertFalse(op.result_path.exists());self.assertEqual(op.status()['state'],'inspect_required')
  for key,value in [('epoch','0'*32),('state','running'),('containerID','bad'),('request',None),('version',True)]:
   changed=copy.deepcopy(receipt);changed[key]=value
   with self.assertRaisesRegex(ValueError,'CLASSIC_RELEASE_NOT_PROVEN'):op.recover(changed,lambda _:True)
  changed=copy.deepcopy(receipt);changed['request']['cpus']=3
  with self.assertRaisesRegex(ValueError,'CLASSIC_RELEASE_NOT_PROVEN'):op.recover(changed,lambda _:True)
  with self.assertRaisesRegex(ValueError,'CLASSIC_CONTAINER_ABSENCE_NOT_PROVEN'):op.recover(receipt,lambda _:False)
 def test_absent_creation_recovery_requires_original_terminal_and_separate_positive_proof(self):
  op=self.operation();exclusive(op.intent_path,op.intent)
  receipt=self.release(op);receipt.update(containerID='',creationAbsent=True)
  proof=lambda request: request==op.request
  with self.assertRaisesRegex(ValueError,'CLASSIC_RELEASE_NOT_PROVEN'):op.recover(receipt,lambda _:True,proof)
  exclusive(op.result_path,dict(operationID=op.operation_id,intentSHA256=op.digest,state='terminal',exitCode=1))
  result=op.recover(receipt,lambda _:self.fail('empty container id inspected'),proof)
  self.assertTrue(result['creationAbsent']);self.assertFalse(result['workloadSuccessProven'])
  with self.assertRaisesRegex(ValueError,'CLASSIC_CONTAINER_ABSENCE_NOT_PROVEN'):op.recover(receipt,lambda _:True,lambda _:False)
  with self.assertRaisesRegex(ValueError,'CLASSIC_RELEASE_NOT_PROVEN'):op.recover(receipt,lambda _:True)
  for key,value in [('creationAbsent',1),('fence','foreign'),('containerID','3'*64)]:
   changed=copy.deepcopy(receipt);changed[key]=value
   with self.assertRaisesRegex(ValueError,'CLASSIC_RELEASE_NOT_PROVEN'):op.recover(changed,lambda _:True,proof)
 def test_creation_absence_requires_same_responsive_daemon_and_exact_name(self):
  from classic_transport import creation_absence
  for mode in ('absent','present','offline','changed'):
   daemon=subprocess.CompletedProcess([],0,b'daemon-id\n',b'')
   names=subprocess.CompletedProcess([],0,b'3'*64 if mode=='present' else b'',b'')
   final=subprocess.CompletedProcess([],1 if mode=='offline' else 0,b'other' if mode=='changed' else b'daemon-id\n',b'')
   with patch('classic_transport.subprocess.run',side_effect=[daemon,names,final]) as run:
    self.assertEqual(creation_absence('a'*32),mode=='absent')
    self.assertEqual(run.call_args_list[1].args[0],['docker','container','ls','--all','--quiet','--no-trunc','--filter','name=^/farm-local-checks-'+'a'*32+'$'])
 def test_protected_binding_composes_exact_task_pins_and_epoch(self):
  op=self.operation();binding=self.root/'binding.json';exclusive(binding,{'version':1,'epoch':op.command['epoch'],'root':str(self.root),'image':op.image})
  with patch('classic_transport.BINDING',binding),patch('classic_transport.WRAPPER',op.wrapper),patch('classic_transport.CAPACITY',self.binary):
   loaded=operation_from_binding(op.operation_id,op.command,op.pins,3,2);self.assertEqual(loaded.run()['response'],{'ok':True})
   changed=copy.deepcopy(op.command);changed['epoch']='0'*32
   with self.assertRaisesRegex(ValueError,'CLASSIC_PROTECTED_BINDING_CHANGED'):operation_from_binding(op.operation_id,changed,op.pins,3,2)
 def test_dispatch_rejects_unknown_fields_actions_and_status_credentials(self):
  request={'action':'status','operationID':'b'*32,'command':{},'installation':{},'timeoutSeconds':3,'cleanupTimeoutSeconds':2}
  with self.assertRaisesRegex(ValueError,'CLASSIC_UNEXPECTED_CREDENTIAL'):handle_request(request,b'private')
  for changed in [dict(request,action='shell'),dict(request,path='/tmp/other')]:
   with self.assertRaisesRegex(ValueError,'CLASSIC_CLOSED_TRANSPORT_REQUIRED'):handle_request(changed)
 def test_ignored_sigterm_retains_original_owner_until_real_child_reaped(self):
  op=self.operation('execute','f'*32,timeout=1,cleanup_timeout=1)
  result=op.run(b'fixture-dependency-token')
  self.assertEqual(result['state'],'inspect_required');self.assertTrue(result['settlementOwnerRetainedAtReturn'])
  retained=op.retained_owner;self.assertIsNotNone(retained);self.assertFalse(retained.owner.closed);self.assertIsNone(retained.owner.process.poll())
  self.assertTrue(retained.finished.wait(3));self.assertEqual(retained.owner.process.returncode,0);self.assertTrue(retained.owner.closed)
  self.assertTrue(all(stream.closed for stream in (retained.owner.process.stdin,retained.owner.process.stdout,retained.owner.process.stderr)))
  with self.assertRaises(ChildProcessError):os.waitpid(retained.owner.process.pid,os.WNOHANG)
 def test_postlaunch_exception_keeps_real_owner_until_settlement(self):
  op=self.operation('execute','f'*32,cleanup_timeout=1);read=os.read
  def fail_after_output(fd,size):
   data=read(fd,size)
   if data:raise RuntimeError('fixture postlaunch output failure')
   return data
  with patch('classic_transport.read_output',side_effect=fail_after_output):
   with self.assertRaisesRegex(RuntimeError,'fixture postlaunch'):op.run(b'fixture-dependency-token')
  retained=op.retained_owner;self.assertIsNotNone(retained);self.assertFalse(retained.owner.closed);self.assertIsNone(retained.owner.process.poll())
  self.assertEqual(op.status()['state'],'inspect_required');self.assertTrue(retained.finished.wait(3));self.assertTrue(retained.owner.closed)
  with self.assertRaises(ChildProcessError):os.waitpid(retained.owner.process.pid,os.WNOHANG)
 def test_postlaunch_exception_settles_terminal_child_before_handles_close(self):
  from classic_process import OwnedProcess
  op=self.operation();created=[];read=os.read
  def tracked(process,identity):
   owner=OwnedProcess(process,identity);created.append(owner);return owner
  def fail_after_output(fd,size):
   data=read(fd,size)
   if data:raise RuntimeError('fixture terminal output failure')
   return data
  with patch('classic_transport.OwnedProcess',side_effect=tracked),patch('classic_transport.read_output',side_effect=fail_after_output):
   with self.assertRaisesRegex(RuntimeError,'fixture terminal'):op.run()
  self.assertEqual(len(created),1);owner=created[0];self.assertTrue(owner.closed);self.assertIsNotNone(owner.process.returncode)
  with self.assertRaises(ChildProcessError):os.waitpid(owner.process.pid,os.WNOHANG)
if __name__=='__main__':unittest.main()
