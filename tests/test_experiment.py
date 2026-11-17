import importlib.util,json,pathlib,tempfile,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('experiment','scripts/experiment.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class CleanupTest(unittest.TestCase):
    def test_recovery_checks_enclave_and_unpauses(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'lease.json'
            m.write(p,{'state':'active','enclave_uuid':'abc','fault':'pause','targets':[{'id':'container'}]})
            node={'Config':{'Labels':{'com.kurtosistech.enclave-id':'abc'}},'State':{'Paused':True}}
            with patch.object(m,'command',side_effect=[json.dumps([node]),'']) as run:
                m.cleanup(p);self.assertEqual(run.call_args.args,('docker','unpause','container'))
            self.assertEqual(json.loads(p.read_text())['state'],'recovered')
    def test_refuses_changed_enclave(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'lease.json';m.write(p,{'state':'active','enclave_uuid':'abc','fault':'pause','targets':[{'id':'container'}]})
            node={'Config':{'Labels':{'com.kurtosistech.enclave-id':'other'}}}
            with patch.object(m,'command',return_value=json.dumps([node])) as run:
                with self.assertRaises(RuntimeError):m.cleanup(p)
                self.assertEqual(run.call_count,1)
            self.assertEqual(json.loads(p.read_text())['state'],'cleanup-failed')
    def test_attached_network_mismatch_never_becomes_success(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'lease.json'
            expected={'IPAddress':'172.1.1.2','Aliases':['validator'],'GlobalIPv6Address':''}
            node={'Config':{'Labels':{'com.kurtosistech.enclave-id':'abc'}},'State':{},'NetworkSettings':{'Networks':{'net':dict(expected,Aliases=[])}}}
            m.write(p,{'state':'active','enclave_uuid':'abc','fault':'disconnect','targets':[{'id':'container','networks':{'net':expected}}]})
            with patch.object(m,'command',return_value=json.dumps([node])):
                for _ in range(2):
                    with self.assertRaises(RuntimeError):m.cleanup(p)
                    self.assertEqual(json.loads(p.read_text())['state'],'cleanup-failed')
    def test_expired_or_recovered_lease_cannot_inject(self):
        with patch.object(m.time,'time',return_value=100):
            for state in ({'state':'prepared','expires_at':99},{'state':'recovered','expires_at':200}):
                with self.assertRaises(ValueError):m.assert_active_lease(state)
            m.assert_active_lease({'state':'prepared','expires_at':200})
if __name__=='__main__':unittest.main()
