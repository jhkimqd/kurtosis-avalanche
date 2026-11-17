import pathlib,unittest,builtins,json,hashlib

def fail(message):raise ValueError(message)
def kind(value):return {int:'int',bool:'bool',str:'string',dict:'dict',list:'list'}.get(builtins.type(value),'unknown')
ns={'fail':fail,'type':kind}
exec(pathlib.Path('src/config/input.star').read_text(),ns)
class ConfigTest(unittest.TestCase):
    def test_rejects_unsupported_features_and_bad_bounds(self):
        for args in ({'network':'mainnet'},{'staking':'pos'},{'validator_count':0},{'validator_count':True},{'l1_count':3},{'metrics':'true'},{'instance_id':''}):
            with self.subTest(args=args), self.assertRaises(ValueError):ns['parse'](args)
    def test_supported_profiles(self):
        for mode in ('poa','native-pos','erc20-pos'):
            self.assertEqual(ns['parse']({'staking':mode,'instance_id':'test-instance'})['staking'],mode)
    def test_multi_l1_fixture_identities_are_unique(self):
        nodes=json.loads(pathlib.Path('fixtures/network.json').read_text())['nodes']
        self.assertEqual(len(nodes),13);self.assertEqual(len({n['node_id'] for n in nodes}),13)
if __name__=='__main__':unittest.main()
