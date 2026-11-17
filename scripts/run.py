#!/usr/bin/env python3
"""Prepare a fresh, isolated package upload and preserve each run's resolved inputs."""
import fcntl,hashlib,json,os,pathlib,re,shutil,subprocess,sys,tempfile,uuid
import yaml
root=pathlib.Path(__file__).resolve().parent.parent
os.chdir(root)
args=yaml.safe_load(pathlib.Path(sys.argv[1]).read_text()) or {}
if not isinstance(args,dict): raise SystemExit('Package arguments must be a mapping')
enclave=os.environ.get('ENCLAVE','avax-lab')
if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,62}',enclave): raise SystemExit('ENCLAVE must contain lowercase letters, digits and hyphens, at most 63 characters')
locks=pathlib.Path(tempfile.gettempdir())/f'avalanche-lab-run-locks-{os.getuid()}'
locks.mkdir(mode=0o700,exist_ok=True)
lock=open(locks/(enclave+'.lock'),'a')
try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError: raise SystemExit('Another deployment is targeting this enclave name')
inventory=subprocess.check_output(['kurtosis','enclave','ls','--full-uuids'],text=True)
rows=[line.split() for line in inventory.splitlines()]
if any(len(row)>1 and re.fullmatch(r'[a-f0-9]{32}',row[0]) and row[1]==enclave for row in rows):
    raise SystemExit(f'Enclave {enclave!r} already exists. Resume commands through its lab service, or choose a new ENCLAVE. Existing state is preserved.')
if 'UUID' not in inventory and 'No enclaves' not in inventory:
    raise SystemExit('Unrecognized enclave inventory; refusing to assume absence')
instance=str(uuid.uuid4());stage=root/'.build'/'packages'/instance
stage.mkdir(parents=True)
args['instance_id']=instance
args['image_id']=subprocess.check_output(['docker','image','inspect',args.get('image','avalanche-lab:local'),'--format','{{.Id}}'],text=True).strip()
args['image']='avalanche-lab:sha256-'+args['image_id'].split(':',1)[1]
subprocess.run(['docker','tag',args['image_id'],args['image']],check=True)
for name in ('main.star','kurtosis.yml','versions.json'):
    shutil.copyfile(root/name,stage/name)
for name in ('src','fixtures'):
    shutil.copytree(root/name,stage/name)
evidence=root/'artifacts'/'runs'/instance;evidence.mkdir(parents=True)
argfile=evidence/'resolved-args.json';argfile.write_text(json.dumps(args,indent=2)+'\n')
(evidence/'enclave.txt').write_text(enclave+'\n')
raise SystemExit(subprocess.run(['kurtosis','run','--enclave',enclave,str(stage),'--args-file',str(argfile)]).returncode)
