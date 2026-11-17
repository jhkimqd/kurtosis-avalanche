"""Export immutable local git objects, including recorded submodules, without editing references."""
import pathlib, subprocess, sys, tarfile, io, shutil, tempfile

def export(repo, ref, dest):
    dest.mkdir(parents=True, exist_ok=True)
    data = subprocess.check_output(['git','-C',str(repo),'archive',ref])
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        # Convenience executable links are not needed by direct Go/Forge builds.
        archive.extractall(dest, members=[m for m in archive.getmembers() if not m.issym() and not m.islnk()], filter='data')
    entries = subprocess.check_output(['git','-C',str(repo),'ls-tree','-r',ref],text=True)
    for entry in entries.splitlines():
        meta,path = entry.split('\t',1)
        mode,kind,sha=meta.split()
        if mode == '160000':
            export(repo/path,sha,dest/path)

destination=pathlib.Path(sys.argv[3]).resolve()
staging=pathlib.Path(tempfile.mkdtemp(prefix='source-',dir=destination.parent))
try:
    export(pathlib.Path(sys.argv[1]),sys.argv[2],staging)
    if destination.exists(): shutil.rmtree(destination)
    staging.rename(destination)
finally:
    if staging.exists(): shutil.rmtree(staging)
