"""Custom-format backup and restore rehearsal without replacing the live database."""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict

from app.core.config import ROOT, settings
from app.storage import storage


def checksum(path):
    result=hashlib.sha256()
    with path.open('rb') as file:
        while block:=file.read(1024*1024):result.update(block)
    return result.hexdigest()


def table_manifest(conn):
    result={}
    for (name,) in conn.execute("SELECT tablename FROM pg_tables WHERE schemaname='admission' ORDER BY tablename").fetchall():
        digest=hashlib.sha256();count=0
        for row in conn.execute(sql.SQL('SELECT to_jsonb(t)::text FROM admission.{} t ORDER BY to_jsonb(t)::text').format(sql.Identifier(name))):
            digest.update(row[0].encode());digest.update(b'\n');count+=1
        result[name]={'rows':count,'sha256':digest.hexdigest()}
    return result


def postgres_env(parameters,dbname=None):
    return {**os.environ,'PGHOST':parameters['host'],'PGPORT':parameters['port'],'PGUSER':parameters['user'],
            'PGPASSWORD':parameters['password'],'PGDATABASE':dbname or parameters['dbname']}


def backup(restore_check=False):
    parameters=conninfo_to_dict(settings.migration_database_url)
    if parameters.get('host') not in ('127.0.0.1','localhost'):
        raise RuntimeError('This recovery utility is restricted to the local project database')
    config=json.loads((ROOT/'.local/local.json').read_text())
    binary=Path(config['pgBin'])
    if parameters.get('port')=='55433':
        binary=Path(json.loads((ROOT/'.local/pg16/connection.json').read_text())['pg_bin'])
    folder=ROOT/'.local/backups'/(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:6])
    (folder/'documents').mkdir(parents=True)
    with psycopg.connect(settings.migration_database_url) as conn:
        conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
        conn.execute("SET LOCAL TIME ZONE 'UTC'")
        snapshot=conn.execute('SELECT pg_export_snapshot()').fetchone()[0]
        manifest={'created_at':datetime.now(timezone.utc).isoformat(),'server_version':conn.execute('SHOW server_version').fetchone()[0],
          'tables':table_manifest(conn),'ledger_head':dict(zip(['seq','hash'],conn.execute('SELECT last_seq,last_hash FROM admission.audit_chain_head').fetchone())),
          'migrations':conn.execute('SELECT name,checksum FROM public.schema_migration ORDER BY name').fetchall(),'documents':[],
          'roles':conn.execute("SELECT rolname,rolsuper,rolcreatedb,rolcreaterole,rolcanlogin FROM pg_roles WHERE rolname IN('admission_owner','admission_app') ORDER BY rolname").fetchall()}
        for key,expected in conn.execute('SELECT storage_key,checksum FROM admission.document_submission ORDER BY document_id'):
            destination=folder/'documents'/key
            with storage().open(key) as source,destination.open('wb') as target:shutil.copyfileobj(source,target)
            if checksum(destination)!=expected:raise AssertionError('Document checksum differs from its committed record')
            manifest['documents'].append({'key':key,'sha256':expected})
        subprocess.run([str(binary/('pg_dump.exe' if os.name=='nt' else 'pg_dump')),'-Fc','--snapshot',snapshot,'--no-owner','--file',str(folder/'database.dump')],
          env=postgres_env(parameters),check=True,capture_output=True)
    manifest['dump_sha256']=checksum(folder/'database.dump')
    (folder/'manifest.json').write_text(json.dumps(manifest,default=str,indent=2))
    report={'backup_created':True,'dump_sha256':manifest['dump_sha256'],'document_count':len(manifest['documents']),
      'table_count':len(manifest['tables']),'server_version':manifest['server_version'],'backup_directory':str(folder.relative_to(ROOT))}
    if restore_check:report.update(rehearse(folder,parameters,binary,manifest))
    (ROOT/'evidence/recovery-verification.json').write_text(json.dumps(report,default=str,indent=2))
    print(json.dumps(report,indent=2));return folder


def rehearse(folder,parameters,binary,manifest):
    name='admission_restore_'+uuid.uuid4().hex[:12]
    if not re.fullmatch(r'admission_restore_[0-9a-f]{12}',name):raise AssertionError('Invalid recovery target')
    with psycopg.connect(**(parameters|{'dbname':'postgres'}),autocommit=True) as control:
        control.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(name)))
        try:
            subprocess.run([str(binary/('pg_restore.exe' if os.name=='nt' else 'pg_restore')),'--exit-on-error','--no-owner','--dbname',name,str(folder/'database.dump')],
              env=postgres_env(parameters,name),check=True,capture_output=True)
            with psycopg.connect(**(parameters|{'dbname':name})) as restored:
                restored.execute("SET TIME ZONE 'UTC'")
                if table_manifest(restored)!=manifest['tables']:raise AssertionError('Restored table count/hash mismatch')
                versions=restored.execute('SELECT name,checksum FROM public.schema_migration ORDER BY name').fetchall()
                if versions!=[tuple(v) for v in manifest['migrations']]:raise AssertionError('Restored migration mismatch')
                head=restored.execute('SELECT last_seq,last_hash FROM admission.audit_chain_head').fetchone()
                if head!=(manifest['ledger_head']['seq'],manifest['ledger_head']['hash']):raise AssertionError('Ledger checkpoint mismatch')
                actor=restored.execute("SELECT user_id FROM admission.app_user WHERE role='ADMIN' AND enabled ORDER BY user_id LIMIT 1").fetchone()[0]
                restored.execute("SELECT set_config('app.user_id',%s,true)",(str(actor),))
                verified=restored.execute('SELECT admission.verify_ledger()').fetchone()[0]
                if not verified['valid']:raise AssertionError('Restored ledger did not verify')
                target=folder/'restore-documents';target.mkdir()
                for document in manifest['documents']:
                    shutil.copy2(folder/'documents'/document['key'],target/document['key'])
                    if checksum(target/document['key'])!=document['sha256']:raise AssertionError('Restored document mismatch')
                role=restored.execute("SELECT has_function_privilege('admission_app','admission.workspace()','EXECUTE'),has_table_privilege('admission_app','admission.seat_matrix','UPDATE')").fetchone()
                if role!=(True,False):raise AssertionError('Restored runtime grants differ')
            return {'restore_checked':True,'all_table_hashes_match':True,'all_document_hashes_match':True,'ledger_checkpoint_matches':True,'runtime_permissions_verified':True,'restore_target':'new disposable database, dropped after verification'}
        finally:
            control.execute(sql.SQL('DROP DATABASE {} WITH (FORCE)').format(sql.Identifier(name)))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--restore-check',action='store_true');args=parser.parse_args()
    backup(args.restore_check)
