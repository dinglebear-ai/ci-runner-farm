import importlib.util,pathlib,signal,subprocess,sys,time,unittest,os
spec=importlib.util.spec_from_file_location('classic_process',pathlib.Path(__file__).with_name('classic_process.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class ClassicProcessTest(unittest.TestCase):
 def test_original_child_cancelled_once_through_pidfd(self):
  child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'])
  owner=m.OwnedProcess(child,"a"*32)
  try:
   self.assertTrue(owner.cancel("a"*32));self.assertFalse(owner.cancel("a"*32));self.assertEqual(child.wait(timeout=3),-signal.SIGTERM)
  finally:owner.close()
 def test_terminal_child_is_never_signalled(self):
  child=subprocess.Popen([sys.executable,'-c','pass']);child.wait(timeout=3)
  owner=m.OwnedProcess(child,"a"*32)
  try:self.assertFalse(owner.cancel("a"*32));self.assertEqual(child.returncode,0)
  finally:owner.close()
 def test_wrong_operation_cannot_cancel(self):
  child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)']);owner=m.OwnedProcess(child,"a"*32)
  try:
   with self.assertRaisesRegex(ValueError,'CLASSIC_OPERATION_OWNER_MISMATCH'):owner.cancel("b"*32)
   self.assertIsNone(child.poll());owner.cancel("a"*32);child.wait(timeout=3)
  finally:owner.close()
 def test_closed_owner_cannot_signal_child(self):
  child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)']);owner=m.OwnedProcess(child,"a"*32);owner.close()
  try:
   with self.assertRaisesRegex(ValueError,'CLASSIC_PIDFD_OWNER_CLOSED'):owner.cancel("a"*32)
   self.assertIsNone(child.poll())
  finally:child.terminate();child.wait(timeout=3)
 def test_settlement_exception_keeps_owner_and_records_failure_until_real_reap(self):
  from unittest.mock import patch
  child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(.4)'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  owner=m.OwnedProcess(child,"a"*32);original=m.settle_child;calls=[]
  def fail_once(*args):
   calls.append(True)
   if len(calls)==1:raise RuntimeError('fixture settlement observer failed')
   return original(*args)
  with patch.object(m,'settle_child',side_effect=fail_once):
   retained=m.RetainedSettlement(child,owner)
   self.assertTrue(retained.observation_failed.wait(1));self.assertEqual(retained.failure,'RuntimeError');self.assertFalse(owner.closed);self.assertIsNone(child.poll());self.assertFalse(retained.finished.is_set())
   self.assertTrue(retained.finished.wait(2));self.assertEqual(child.returncode,0);self.assertTrue(owner.closed)
   with self.assertRaises(ChildProcessError):os.waitpid(child.pid,os.WNOHANG)
if __name__=='__main__':unittest.main()
