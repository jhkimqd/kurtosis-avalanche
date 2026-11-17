import json,pathlib,hashlib
out=pathlib.Path('fixtures/contracts');out.mkdir(exist_ok=True)
manifest={}
for name in ('ValidatorMessages','ValidatorManager','NativeTokenStakingManager','ERC20TokenStakingManager','ExampleRewardCalculator','TeleporterMessenger','TeleporterRegistry'):
    data=json.loads((pathlib.Path('.build/icm/out')/(name+'.sol')/(name+'.json')).read_text())
    content=json.dumps({'abi':data['abi'],'bytecode':data['bytecode']},sort_keys=True)+'\n'
    (out/(name+'.json')).write_text(content)
    manifest[name]=hashlib.sha256(content.encode()).hexdigest()
(out/'hashes.json').write_text(json.dumps(manifest,indent=2)+'\n')
# Authored application contracts carry their own SPDX notices and are built separately.
for name in ('StakingToken','Ledger','DeliveryVersusPayment','PriceFeed','OracleSettlement','CrossChainSettlement'):
    source={'StakingToken':'StakingToken','CrossChainSettlement':'CrossChainSettlement'}.get(name,'Institutional')
    data=json.loads((pathlib.Path('contracts/out')/(source+'.sol')/(name+'.json')).read_text())
    content=json.dumps({'abi':data['abi'],'bytecode':data['bytecode']},sort_keys=True)+'\n'
    (out/(name+'.json')).write_text(content)
    manifest[name]=hashlib.sha256(content.encode()).hexdigest()
(out/'hashes.json').write_text(json.dumps(manifest,indent=2)+'\n')
