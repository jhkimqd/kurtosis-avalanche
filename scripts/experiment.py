#!/usr/bin/env python3
"""Scoped Docker fault experiments with durable leases and independent expiry cleanup."""
import argparse, fcntl, hashlib, json, os, pathlib, re, subprocess, sys, tempfile, time

def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=15).strip()

def write(path, value):
    fd,name=tempfile.mkstemp(prefix='.lease-',dir=path.parent)
    temp=pathlib.Path(name)
    try:
        with os.fdopen(fd,'w',encoding='utf8') as f:
            json.dump(value,f,indent=2);f.flush();os.fsync(f.fileno())
        os.replace(temp,path)
    finally: temp.unlink(missing_ok=True)

def resolve(enclave, services):
    info=command('kurtosis','enclave','inspect','--full-uuids',enclave)
    match=re.search(r'^UUID:\s+([a-f0-9]{32})\s*$',info,re.M)
    if not match: raise ValueError('Cannot resolve exact enclave UUID')
    uuid=match[1]
    ids=command('docker','ps','-q','--filter',f'label=com.kurtosistech.enclave-id={uuid}','--filter','label=com.kurtosistech.container-type=user-service').split()
    if not ids: raise ValueError('No running services')
    containers=json.loads(command('docker','inspect',*ids))
    by_name={c['Config']['Labels']['com.kurtosistech.id']:c for c in containers}
    if 'lab' not in by_name: raise ValueError('Not an Avalanche lab enclave')
    targets=[]
    for name in services:
        if not re.fullmatch(r'primary-[0-2]|l1-[01]-(validator-[0-3]|rpc|aggregator)',name): raise ValueError(f'Unsupported fault target: {name}')
        if name not in by_name: raise ValueError(f'Missing running service: {name}')
        c=by_name[name]
        if c['State']['Paused']: raise ValueError(f'Already paused: {name}')
        if 'avalanche-lab' not in c['Config']['Image'] and not c['Config']['Image'].startswith('sha256:'): raise ValueError('Unexpected service image')
        targets.append({'name':name,'id':c['Id'],'networks':c['NetworkSettings']['Networks'],'image_id':c['Image']})
    return uuid,targets

def lockfile(uuid):
    if not re.fullmatch(r'[a-f0-9]{32}',uuid): raise ValueError('Invalid enclave UUID')
    root=pathlib.Path(tempfile.gettempdir())/f'avalanche-lab-leases-{os.getuid()}'
    root.mkdir(mode=0o700,exist_ok=True)
    return root/(uuid+'.lock')

def cleanup(lease):
    with open(lease.with_suffix('.guard'),'a') as guard:
        fcntl.flock(guard,fcntl.LOCK_EX)
        return cleanup_locked(lease)

def cleanup_locked(lease):
    state=json.loads(lease.read_text())
    if state['state']=='recovered': return
    errors=[]
    for target in state['targets']:
        try:
            c=json.loads(command('docker','inspect',target['id']))[0]
            if c['Config']['Labels'].get('com.kurtosistech.enclave-id')!=state['enclave_uuid']: raise ValueError('Enclave identity changed')
            if state['fault']=='pause':
                if c['State']['Paused']: command('docker','unpause',target['id'])
            elif state['fault']=='stop':
                if not c['State']['Running']: command('docker','start',target['id'])
            elif state['fault']=='disconnect':
                for network,settings in target['networks'].items():
                    if network not in c['NetworkSettings']['Networks']:
                        connect=['docker','network','connect']
                        if settings.get('IPAddress'): connect+=['--ip',settings['IPAddress']]
                        if settings.get('GlobalIPv6Address'): connect+=['--ip6',settings['GlobalIPv6Address']]
                        for alias in settings.get('Aliases') or []: connect+=['--alias',alias]
                        command(*connect,network,target['id'])
                    restored=json.loads(command('docker','inspect',target['id']))[0]['NetworkSettings']['Networks'][network]
                    if restored.get('IPAddress')!=settings.get('IPAddress') or restored.get('GlobalIPv6Address','')!=settings.get('GlobalIPv6Address','') or not set(settings.get('Aliases') or []).issubset(set(restored.get('Aliases') or [])): raise ValueError('Network identity was not restored')
        except Exception as exc: errors.append(str(exc))
    state['cleanup_errors']=errors;state['state']='cleanup-failed' if errors else 'recovered';state['recovered_at']=time.time();write(lease,state)
    if errors: raise RuntimeError('; '.join(errors))
    if 'lock_path' in state: lockfile(state['enclave_uuid']).unlink(missing_ok=True)

def watchdog(lease):
    # The durable lease is written before this independent process starts.
    while True:
        state=json.loads(lease.read_text())
        if state['state']=='recovered': return
        if time.time()>=state['expires_at']:
            for attempt in range(60):
                try:
                    cleanup(lease);return
                except Exception as exc:
                    print(f'Cleanup attempt {attempt+1} failed: {exc}',flush=True)
                    time.sleep(min(10,1+attempt))
            raise RuntimeError(f'Automatic recovery exhausted retries; manual recovery required: {lease}')
        time.sleep(min(0.25,max(0.01,state['expires_at']-time.time())))

def assert_active_lease(state):
    if state['state']!='prepared' or time.time()>=state['expires_at']:
        raise ValueError('Lease expired or already recovered before injection')

def inject(args):
    if not 1<=args.seconds<=60: raise ValueError('Fault duration must be 1..60 seconds')
    if len(set(args.service))!=len(args.service): raise ValueError('Duplicate target')
    uuid,targets=resolve(args.enclave,args.service)
    root=pathlib.Path(args.output).resolve();root.mkdir(parents=True,exist_ok=True);os.chmod(root,0o700)
    lock=lockfile(uuid)
    fd=os.open(lock,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.close(fd)
    lease=root/(uuid+'-'+str(time.time_ns())+'.json')
    state={'schema_version':1,'enclave_uuid':uuid,'fault':args.fault,'targets':targets,'state':'prepared','created_at':time.time(),'expires_at':time.time()+args.seconds+len(targets)*20+10,'lock_path':str(lock),'site_model':'single-host simulation'}
    write(lease,state)
    log=open(lease.with_suffix('.watchdog.log'),'w');os.chmod(log.name,0o600)
    subprocess.Popen([sys.executable,str(pathlib.Path(__file__).resolve()),'watchdog',str(lease)],start_new_session=True,stdin=subprocess.DEVNULL,stdout=log,stderr=log)
    try:
        guard=open(lease.with_suffix('.guard'),'a')
        fcntl.flock(guard,fcntl.LOCK_EX)
        state=json.loads(lease.read_text())
        assert_active_lease(state)
        for target in targets:
            if args.fault=='pause': command('docker','pause',target['id'])
            elif args.fault=='stop': command('docker','stop','--time','5',target['id'])
            else:
                for network in target['networks']: command('docker','network','disconnect',network,target['id'])
        state['state']='active';state['injected_at']=time.time();write(lease,state)
        fcntl.flock(guard,fcntl.LOCK_UN);guard.close()
        time.sleep(args.seconds)
    finally:
        if 'guard' in locals() and not guard.closed: guard.close()
        cleanup(lease)
    print(lease)

def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='command',required=True)
    run=sub.add_parser('inject');run.add_argument('--enclave',required=True);run.add_argument('--service',action='append',required=True);run.add_argument('--fault',choices=['pause','stop','disconnect'],required=True);run.add_argument('--seconds',type=int,default=5);run.add_argument('--output',default='artifacts/faults')
    for name in ('watchdog','recover'):
        p=sub.add_parser(name);p.add_argument('lease',type=pathlib.Path)
    args=parser.parse_args()
    if args.command=='inject': inject(args)
    elif args.command=='watchdog': watchdog(args.lease)
    else: cleanup(args.lease)
if __name__=='__main__': main()
