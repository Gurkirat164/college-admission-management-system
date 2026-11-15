from fastapi.testclient import TestClient

from app.core.config import settings


def test_proxy_boundary_and_scheduler_token(monkeypatch):
    from app.main import app
    import app.jobs.worker as worker
    monkeypatch.setattr(settings, 'app_env', 'development')
    monkeypatch.setattr(settings, 'proxy_secret', 'test-proxy-key')
    monkeypatch.setattr(settings, 'job_token', 'test-job-key')
    monkeypatch.setattr(worker, 'tick', lambda: [{'status': 'SKIPPED'}])
    # These requests need no database/lifespan: the boundary is checked before routing.
    client = TestClient(app)
    assert client.get('/api/v1/health').status_code == 200
    assert client.get('/api/v1/auth/me').status_code == 403
    assert client.get('/api/v1/dev/accounts', headers={'x-admission-proxy': 'test-proxy-key'}).status_code == 200
    assert client.post('/internal/jobs/daily').status_code == 401
    assert client.post('/internal/jobs/daily', headers={'Authorization': 'Bearer wrong'}).status_code == 401
    assert client.post('/internal/jobs/daily', headers={'Authorization': 'Bearer test-job-key'}).json() == {'results': [{'status': 'SKIPPED'}]}


def test_production_hides_development_accounts(monkeypatch):
    from app.main import app
    monkeypatch.setattr(settings, 'app_env', 'production')
    monkeypatch.setattr(settings, 'demo_accounts', '')
    assert TestClient(app).get('/api/v1/dev/accounts').status_code == 404


def test_hosted_demo_accounts_are_opt_in(monkeypatch):
    import json
    from app.main import app
    monkeypatch.setattr(settings, 'app_env', 'production')
    monkeypatch.setattr(settings, 'proxy_secret', '')
    accounts = [
        {'email': 'admin@example.com', 'password': 'synthetic-1', 'role': 'ADMIN', 'full_name': 'Admin', 'secret': 'dropped'},
        {'email': 's1@example.com', 'password': 'synthetic-2', 'role': 'STUDENT', 'full_name': 'S1', 'student_id': 1},
        {'email': 's2@example.com', 'password': 'synthetic-3', 'role': 'STUDENT', 'full_name': 'S2', 'student_id': 2},
        {'email': 'no-password@example.com', 'role': 'ANALYST'},
    ]
    monkeypatch.setattr(settings, 'demo_accounts', json.dumps(accounts))
    body = TestClient(app).get('/api/v1/dev/accounts').json()
    assert [a['email'] for a in body] == ['admin@example.com', 's1@example.com']
    assert 'secret' not in body[0]
    monkeypatch.setattr(settings, 'demo_accounts', 'not json')
    assert TestClient(app).get('/api/v1/dev/accounts').status_code == 404
