"""Every test receives a separate database. The local demo database is untouched."""
import uuid

import psycopg
import pytest
from fastapi.testclient import TestClient
from psycopg import sql
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from app.cli import migrate, seed
from app.core.config import settings
from app.core.security import attempts


@pytest.fixture
def db():
    if not settings.migration_database_url or not any(port in settings.migration_database_url for port in (':55432/',':55433/')):
        pytest.skip("Integration tests require the isolated local PostgreSQL configured by npm run setup")
    name = 'admission_test_' + uuid.uuid4().hex[:12]
    owner = settings.migration_database_url.rsplit('/', 1)[0]
    app_base = settings.database_url.rsplit('/', 1)[0]
    with psycopg.connect(owner + '/postgres', autocommit=True) as control:
        control.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(name)))
        try:
            with psycopg.connect(owner + '/' + name) as conn:
                migrate(conn)
                accounts = seed(conn, write_accounts=False)
            with psycopg.connect(owner + '/' + name, row_factory=dict_row) as conn:
                conn.autocommit = True
                yield {'conn': conn, 'owner_url': owner + '/' + name, 'app_url': app_base + '/' + name, 'accounts': accounts}
        finally:
            control.execute(sql.SQL('DROP DATABASE {} WITH (FORCE)').format(sql.Identifier(name)))


@pytest.fixture
def client(db, monkeypatch):
    import app.db as database
    import app.main as main
    pool = ConnectionPool(db['app_url'], open=False, kwargs={'row_factory': dict_row}, min_size=0, max_size=4)
    monkeypatch.setattr(database, 'pool', pool)
    monkeypatch.setattr(main, 'pool', pool)
    attempts.clear()
    with TestClient(main.app) as client:
        yield client


def as_actor(conn, accounts, role='ADMIN', email=None):
    user = next(a for a in accounts if a['email'] == email) if email else next(a for a in accounts if a['role'] == role)
    conn.execute("SELECT set_config('app.user_id',%s,false)", (str(user['user_id']),))
    return user


def login(client, db, role='ADMIN', email=None):
    user = next(a for a in db['accounts'] if a['email'] == email) if email else next(a for a in db['accounts'] if a['role'] == role)
    result = client.post('/api/v1/auth/login', json={'email': user['email'], 'password': user['password']})
    assert result.status_code == 200, result.text
    return {'X-CSRF-Token': result.json()['csrf_token']}
