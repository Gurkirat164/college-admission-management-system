"""Export complete PostgreSQL 16 schema and a generated data dictionary."""
import json
import os
import subprocess
import uuid

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict

from app.cli import migrate
from app.core.config import ROOT


def generate():
    config=json.loads((ROOT/'.local/pg16/connection.json').read_text())
    params=conninfo_to_dict(config['owner_url']);name='admission_verify_docs_'+uuid.uuid4().hex[:8]
    with psycopg.connect(**params,autocommit=True) as control:
        control.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(name)))
        try:
            with psycopg.connect(**(params|{'dbname':name})) as conn:
                migrate(conn)
                rows=conn.execute("SELECT table_name,column_name,data_type,is_nullable,column_default FROM information_schema.columns WHERE table_schema='admission' ORDER BY table_name,ordinal_position").fetchall()
                keys=conn.execute("SELECT t.relname,c.conname,pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace WHERE n.nspname='admission' ORDER BY t.relname,c.conname").fetchall()
                lines=['# Database dictionary','','Generated from the complete migrated PostgreSQL 16 schema. Migrations remain authoritative.','']
                current=None
                for table,column,datatype,nullable,default in rows:
                    if table!=current:
                        lines+=['',f'## {table}','','| Column | PostgreSQL type | Nullable | Default |','|---|---|---|---|'];current=table
                    lines.append(f'| {column} | {datatype} | {nullable} | {str(default or "").replace("|","/")} |')
                lines+=['','## Relational constraints','','| Relation | Constraint | Definition |','|---|---|---|']
                lines += [f'| {t} | {n} | {d.replace("|","/")} |' for t,n,d in keys]
                (ROOT/'docs/data-dictionary.md').write_text('\n'.join(lines)+'\n')
            env={**os.environ,'PGHOST':params['host'],'PGPORT':params['port'],'PGUSER':params['user'],'PGPASSWORD':params['password'],'PGDATABASE':name}
            subprocess.run([str(ROOT/'.local/pg16/pgsql/bin/pg_dump.exe'),'--schema-only','--no-owner','--file',str(ROOT/'database/schema.sql')],env=env,check=True,capture_output=True)
        finally:
            control.execute(sql.SQL('DROP DATABASE {} WITH (FORCE)').format(sql.Identifier(name)))
    print('Exported database/schema.sql and docs/data-dictionary.md from PostgreSQL 16.')


if __name__=='__main__':generate()
