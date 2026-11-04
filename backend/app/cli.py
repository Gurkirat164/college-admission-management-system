"""Explicit local setup commands; the HTTP server never migrates on startup."""
import hashlib
import json
import secrets
import sys
from pathlib import Path

import psycopg
from argon2 import PasswordHasher
from psycopg import sql
from psycopg.rows import dict_row

from app.core.config import ROOT, settings


def migrate(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS public.schema_migration (name text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())")
    conn.commit()
    for file in sorted((ROOT / "database/migrations").glob("*.sql")):
        content = file.read_text(encoding="utf-8")
        checksum = hashlib.sha256(content.encode()).hexdigest()
        row = conn.execute("SELECT checksum FROM public.schema_migration WHERE name=%s", (file.name,)).fetchone()
        if row:
            if row[0] != checksum:
                raise RuntimeError(f"Applied migration changed: {file.name}. Add a new migration instead.")
            conn.commit()
            continue
        with conn.transaction():
            conn.execute(content)
            conn.execute("INSERT INTO public.schema_migration(name,checksum) VALUES(%s,%s)", (file.name, checksum))
        conn.commit()
        print(f"Applied {file.name}")


def seed(conn, write_accounts=True):
    if conn.execute("SELECT count(*) FROM admission.admission_cycle").fetchone()[0]:
        conn.commit()
        return []
    password = secrets.token_urlsafe(16)
    password_hash = PasswordHasher().hash(password)
    accounts = []
    with conn.transaction():
        conn.execute((ROOT / "database/seeds/demo.sql").read_text(encoding="utf-8"))
        for name, role in [("Admission admin", "ADMIN"), ("Sandbox analyst", "ANALYST"), ("Read-only auditor", "AUDITOR")]:
            email = {"ADMIN": "admin@example.com", "ANALYST": "analyst@example.com", "AUDITOR": "auditor@example.com"}[role]
            uid = conn.execute("INSERT INTO admission.app_user(email,full_name,password_hash,role) VALUES(%s,%s,%s,%s) RETURNING user_id", (email, name, password_hash, role)).fetchone()[0]
            accounts.append(dict(email=email, full_name=name, role=role, password=password, user_id=uid))
        for sid, name in conn.execute("SELECT student_id,full_name FROM admission.student ORDER BY student_id").fetchall():
            email = name.split()[0].lower() + "@example.com"
            uid = conn.execute("INSERT INTO admission.app_user(email,full_name,password_hash,role,student_id) VALUES(%s,%s,%s,'STUDENT',%s) RETURNING user_id", (email, name, password_hash, sid)).fetchone()[0]
            accounts.append(dict(email=email, full_name=name, role="STUDENT", password=password, user_id=uid, student_id=sid))
    conn.commit()
    if write_accounts:
        (ROOT / ".local/demo-accounts.json").write_text(json.dumps(accounts, indent=2), encoding="utf-8")
    print("Synthetic demo data ready." + (" Local credentials are in .local/demo-accounts.json." if write_accounts else ""))
    return accounts


def bootstrap():
    if settings.app_env != "development":
        raise RuntimeError("Bootstrap is a local development command, not a production installer.")
    config = json.loads((ROOT / ".local/local.json").read_text())
    owner_url = settings.migration_database_url
    if not owner_url.endswith("/admission") or ":55432/" not in owner_url:
        raise RuntimeError("Local bootstrap requires the project-owned local database on port 55432.")
    with psycopg.connect(owner_url.rsplit("/", 1)[0] + "/postgres", autocommit=True) as conn:
        if not conn.execute("SELECT 1 FROM pg_roles WHERE rolname='admission_app'").fetchone():
            conn.execute(sql.SQL("CREATE ROLE admission_app LOGIN PASSWORD {} NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT").format(sql.Literal(config["appPassword"])))
        if not conn.execute("SELECT 1 FROM pg_database WHERE datname='admission'").fetchone():
            conn.execute("CREATE DATABASE admission OWNER admission_owner")
    with psycopg.connect(owner_url) as conn:
        migrate(conn)
        seed(conn)
        ensure_service_user(conn)


def ensure_service_user(conn, persist_local=True):
    row = conn.execute("SELECT user_id FROM admission.app_user WHERE email='scheduler@local.invalid'").fetchone()
    if row is None:
        row = conn.execute("INSERT INTO admission.app_user(email,full_name,password_hash,role) VALUES('scheduler@local.invalid','Local scheduled jobs',%s,'ADMIN') RETURNING user_id", (PasswordHasher().hash(secrets.token_urlsafe(40)),)).fetchone()
    conn.commit()
    if persist_local:
        (ROOT / '.local').mkdir(exist_ok=True)
        (ROOT / '.local/service-user.json').write_text(json.dumps({'user_id': row[0]}))
    return row[0]


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "help"
    if action == "bootstrap":
        bootstrap()
    elif action in ("migrate", "seed", "services"):
        if not settings.migration_database_url:
            raise RuntimeError("MIGRATION_DATABASE_URL is required")
        with psycopg.connect(settings.migration_database_url) as conn:
            {"migrate": migrate, "seed": seed, "services": ensure_service_user}[action](conn)
    elif action == "checkpoint":
        with psycopg.connect(settings.migration_database_url, row_factory=dict_row) as conn:
            head = conn.execute("SELECT last_seq,last_hash,clock_timestamp() AS checkpoint_time FROM admission.audit_chain_head").fetchone()
        path = ROOT / ".local" / f"ledger-checkpoint-{head['last_seq']}.json"
        path.write_text(json.dumps(head, default=str, indent=2))
        print(f"Saved {path.name}. Copy it outside the database workspace for independent protection.")
    else:
        print("Commands: bootstrap | migrate | seed | checkpoint")


if __name__ == "__main__":
    main()
