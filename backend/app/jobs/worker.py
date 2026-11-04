"""Durable, idempotent local jobs. Allocation logic remains in PostgreSQL."""
import argparse
import json
import logging
import time
import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import psycopg
from psycopg.rows import dict_row

from app.core.config import ROOT, settings


def service_user_id():
    if settings.scheduler_user_id:
        return settings.scheduler_user_id
    file = ROOT / '.local/service-user.json'
    if not file.exists():
        raise RuntimeError('Run node scripts/python.mjs -m app.cli services to prepare the local scheduler identity')
    return json.loads(file.read_text())['user_id']


def set_actor(conn, user_id):
    conn.execute("SELECT set_config('app.user_id',%s,true)", (str(user_id),))


def run_job(year, name='nightly_mock', slot=None, user_id=None):
    user_id = user_id or service_user_id()
    slot = slot or 'manual-' + uuid.uuid4().hex
    with psycopg.connect(settings.database_url, row_factory=dict_row) as conn:
        # Dedicated connection: this session lock never leaks through an API pool.
        locked = conn.execute("SELECT pg_try_advisory_lock(hashtextextended(%s,0)) AS value", (f'job:{name}:{year}',)).fetchone()['value']
        conn.commit()
        if not locked:
            return {'status': 'SKIPPED', 'message': 'This job is already running'}
        job_id = None
        try:
            set_actor(conn, user_id)
            job_id = conn.execute('SELECT admission.job_start(%s,%s,%s) AS id', (name, year, slot)).fetchone()['id']
            conn.commit()
            if job_id is None:
                return {'status': 'SKIPPED', 'message': 'This schedule slot already completed'}
            with conn.transaction():
                conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ')
                set_actor(conn, user_id)
                if name == 'nightly_mock':
                    sim_id = conn.execute('SELECT admission.run_mock(%s) AS id', (year,)).fetchone()['id']
                else:
                    conn.execute('SELECT admission.prune_simulations()')
                    sim_id = None
            with conn.transaction():
                set_actor(conn, user_id)
                conn.execute('SELECT admission.refresh_predictions(%s)', (year,))
                conn.execute("SELECT admission.job_finish(%s,'SUCCEEDED',%s,%s)", (job_id, sim_id, 'Completed from current input snapshot'))
            return {'job_id': job_id, 'status': 'SUCCEEDED', 'sim_id': sim_id}
        except Exception as exc:
            conn.rollback()
            if job_id is not None:
                with conn.transaction():
                    set_actor(conn, user_id)
                    conn.execute("SELECT admission.job_finish(%s,'FAILED',NULL,%s)", (job_id, 'Job failed; inspect local logs and retry. Code: ' + (getattr(exc, 'sqlstate', None) or type(exc).__name__)))
            logging.getLogger('admission.jobs').warning('Job %s failed (%s)', name, getattr(exc, 'sqlstate', None) or type(exc).__name__)
            return {'job_id': job_id, 'status': 'FAILED', 'message': 'The job failed. Its failure was recorded; inspect the API/admin job status.'}
        finally:
            conn.execute("SELECT pg_advisory_unlock(hashtextextended(%s,0))", (f'job:{name}:{year}',))
            conn.commit()


def tick(now=None):
    now = now or datetime.now(timezone.utc)
    local = now.astimezone(ZoneInfo(settings.scheduler_timezone))
    hour, minute = map(int, settings.mock_run_time.split(':'))
    due = local.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if local < due:
        due -= timedelta(days=1)
    slot = due.date().isoformat()
    with psycopg.connect(settings.database_url, row_factory=dict_row) as conn:
        set_actor(conn, service_user_id())
        targets = conn.execute('SELECT admission.job_targets() AS value').fetchone()['value']
    results = []
    for target in targets:
        for name in (['nightly_mock', 'maintenance'] if target['choices_open'] else ['maintenance']):
            results.append(run_job(target['year'], name, slot))
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--watch', action='store_true')
    args = parser.parse_args()
    while True:
        try:
            results = tick()
            for result in results:
                if result['status'] != 'SKIPPED':
                    print('Local scheduled job: ' + json.dumps(result), flush=True)
        except Exception:
            logging.getLogger('admission.jobs').warning('Scheduler is waiting for local setup or database readiness')
        if not args.watch:
            break
        time.sleep(30)


if __name__ == '__main__':
    main()
