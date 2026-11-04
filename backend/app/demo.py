"""Create a fresh local demo without deleting or replacing any existing database."""
import argparse
import json
import re
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict

from app.cli import migrate,seed,ensure_service_user
from app.core.config import ROOT,settings


def create_demo(name,activate=False):
    if not re.fullmatch(r'admission_demo_[a-z0-9_]{3,30}',name):
        raise ValueError('Choose an explicit new name: admission_demo_<at least three lowercase characters>')
    owner=conninfo_to_dict(settings.migration_database_url)
    if owner.get('host') not in ('127.0.0.1','localhost'):
        raise ValueError('Fresh demo creation is restricted to the local server')
    with psycopg.connect(**(owner|{'dbname':'postgres'}),autocommit=True) as control:
        if control.execute('SELECT 1 FROM pg_database WHERE datname=%s',(name,)).fetchone():
            raise ValueError('That database already exists. Choose a different name; no data was deleted.')
        control.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(name)))
    with psycopg.connect(**(owner|{'dbname':name})) as conn:
        migrate(conn);accounts=seed(conn,write_accounts=False)
        if activate:ensure_service_user(conn)
    credentials=ROOT/'.local'/f'{name}-accounts.json';credentials.write_text(json.dumps(accounts,indent=2))
    if activate:
        env=ROOT/'backend/.env'
        content=env.read_text();(ROOT/'.local'/f'{name}-previous.env').write_text(content)
        lines=[]
        for line in content.splitlines():
            if line.startswith(('DATABASE_URL=','MIGRATION_DATABASE_URL=')):
                line=line.rsplit('/',1)[0]+'/'+name
            lines.append(line)
        env.write_text('\n'.join(lines)+'\n')
        (ROOT/'.local/demo-accounts.json').write_text(json.dumps(accounts,indent=2))
    print(f'Created {name}. Previous databases were preserved. '+('Restart npm run dev to use it.' if activate else 'Use --activate explicitly to switch the local app.'))
    return name


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--name',required=True);parser.add_argument('--activate',action='store_true');args=parser.parse_args()
    create_demo(args.name,args.activate)
