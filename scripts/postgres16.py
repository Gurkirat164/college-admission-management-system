"""Prepare an isolated portable PostgreSQL 16 instance for compatibility checks."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / '.local/pg16'
URL = 'https://get.enterprisedb.com/postgresql/postgresql-16.15-5-windows-x64-binaries.zip'


def prepare():
    import psycopg
    from psycopg import sql
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    binary = DIRECTORY / 'pgsql/bin'
    archive = DIRECTORY / 'postgresql16.zip'
    if not (binary / 'postgres.exe').exists():
        if not archive.exists():
            print('Downloading official EDB PostgreSQL 16 binaries for local verification.', flush=True)
            urllib.request.urlretrieve(URL, archive)
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.infolist():
                parts = Path(member.filename).parts
                if len(parts)<2 or parts[0]!='pgsql' or parts[1] not in ('bin','lib','share') or member.is_dir():
                    continue
                destination = (DIRECTORY / member.filename).resolve()
                if not destination.is_relative_to(DIRECTORY.resolve()):
                    raise RuntimeError('Unsafe archive member')
                destination.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(member) as source, destination.open('wb') as target:
                    shutil.copyfileobj(source, target)
    config = json.loads((ROOT / '.local/local.json').read_text())
    data = DIRECTORY / 'data'
    if not (data / 'PG_VERSION').exists():
        password = DIRECTORY / 'init-password'
        password.write_text(config['ownerPassword'])
        subprocess.run([str(binary/'initdb.exe'),'-D',str(data),'-U','admission_owner','--pwfile',str(password),'--auth=scram-sha-256','--encoding=UTF8','--locale=C'],check=True,stdout=subprocess.DEVNULL)
        password.unlink()
        (data/'postgresql.auto.conf').write_text("listen_addresses='127.0.0.1'\nport=55433\nmax_connections=64\nshared_buffers='128MB'\n")
    ready=subprocess.run([str(binary/'pg_isready.exe'),'-h','127.0.0.1','-p','55433'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if ready.returncode:
        subprocess.run([str(binary/'pg_ctl.exe'),'-D',str(data),'-l',str(DIRECTORY/'postgres.log'),'-w','start'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
    owner_url=f"postgresql://admission_owner:{config['ownerPassword']}@127.0.0.1:55433/postgres"
    with psycopg.connect(owner_url,autocommit=True) as conn:
        if not conn.execute("SELECT 1 FROM pg_roles WHERE rolname='admission_app'").fetchone():
            conn.execute(sql.SQL('CREATE ROLE admission_app LOGIN PASSWORD {} NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT').format(sql.Literal(config['appPassword'])))
        version=conn.execute('SHOW server_version').fetchone()[0]
    connection={'owner_url':owner_url,'app_url':f"postgresql://admission_app:{config['appPassword']}@127.0.0.1:55433/postgres",'pg_bin':str(binary)}
    (DIRECTORY/'connection.json').write_text(json.dumps(connection))
    checksum=hashlib.sha256(archive.read_bytes()).hexdigest() if archive.exists() else None
    (ROOT/'evidence/postgresql16-runtime.json').write_text(json.dumps({'version':version,'source':URL,'download_sha256':checksum,'host':'127.0.0.1','port':55433},indent=2))
    print('Isolated PostgreSQL '+version+' ready on port 55433. Existing databases are unchanged.',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--stop',action='store_true');args=parser.parse_args()
    if args.stop:
        subprocess.run([str(DIRECTORY/'pgsql/bin/pg_ctl.exe'),'-D',str(DIRECTORY/'data'),'-m','fast','-w','stop'],check=True)
    else:
        prepare()
