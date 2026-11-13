"""Concurrency demo: many students try to take the last seat at the same instant.

Run with: npm run demo:race   (optionally: npm run demo:race -- --clients 30)

It creates a throwaway database, gives one pool a single seat, and starts N clients at once,
each on its own connection, twice:

  naive   read seats_left, then write seats_left - 1 (the classic lost-update bug)
  atomic  UPDATE ... SET seats_left = seats_left - 1 WHERE seats_left > 0, the pattern
          admission.accept_spot() uses

The demo database is dropped at the end; the project's data is never touched.
"""
import argparse
import threading
import time
import uuid

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from app.core.config import settings

SETUP = """
CREATE TABLE spot_pool (pool_id int PRIMARY KEY, seats_left int NOT NULL CHECK (seats_left >= 0));
CREATE TABLE spot_acceptance (student_id int NOT NULL, mode text NOT NULL);
"""


def naive(conn, student):
    with conn.transaction():
        seats = conn.execute('SELECT seats_left FROM spot_pool WHERE pool_id = 1').fetchone()[0]
        time.sleep(0.05)  # the gap between reading and writing, where other clients sneak in
        if seats > 0:
            conn.execute('UPDATE spot_pool SET seats_left = %s WHERE pool_id = 1', (seats - 1,))
            conn.execute("INSERT INTO spot_acceptance VALUES (%s, 'naive')", (student,))
            return True
    return False


def atomic(conn, student):
    with conn.transaction():
        row = conn.execute(
            'UPDATE spot_pool SET seats_left = seats_left - 1 WHERE pool_id = 1 AND seats_left > 0 RETURNING 1'
        ).fetchone()
        if row:
            conn.execute("INSERT INTO spot_acceptance VALUES (%s, 'atomic')", (student,))
            return True
    return False


def race(url, attempt, clients):
    with psycopg.connect(url, autocommit=True) as conn:
        conn.execute('TRUNCATE spot_acceptance; DELETE FROM spot_pool; INSERT INTO spot_pool VALUES (1, 1)')
    connections = [psycopg.connect(url, autocommit=True) for _ in range(clients)]
    start = threading.Barrier(clients)
    accepted = [False] * clients

    def client(i):
        start.wait()  # release every client at the same moment
        accepted[i] = attempt(connections[i], i + 1)

    threads = [threading.Thread(target=client, args=(i,)) for i in range(clients)]
    began = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    elapsed = (time.perf_counter() - began) * 1000
    for c in connections:
        c.close()
    with psycopg.connect(url) as conn:
        seats_left = conn.execute('SELECT seats_left FROM spot_pool WHERE pool_id = 1').fetchone()[0]
        rows = conn.execute('SELECT count(*) FROM spot_acceptance').fetchone()[0]
    return sum(accepted), rows, seats_left, elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--clients', type=int, default=25, help='simultaneous clients (default 25)')
    clients = parser.parse_args().clients
    if not settings.migration_database_url:
        raise SystemExit('MIGRATION_DATABASE_URL is not set. Run npm run setup first.')
    params = conninfo_to_dict(settings.migration_database_url)
    name = 'admission_race_demo_' + uuid.uuid4().hex[:8]
    with psycopg.connect(make_conninfo(**(params | {'dbname': 'postgres'})), autocommit=True) as control:
        # Each client needs its own connection; stay inside the server's limit (40 for the local cluster).
        free = control.execute(
            "SELECT current_setting('max_connections')::int - current_setting('superuser_reserved_connections')::int"
            " - (SELECT count(*) FROM pg_stat_activity) - 3"
        ).fetchone()[0]
        if clients > free:
            print(f'Using {free} clients: the server has room for {free} more connections.')
            clients = free
        control.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(name)))
        try:
            url = make_conninfo(**(params | {'dbname': name}))
            with psycopg.connect(url, autocommit=True) as conn:
                conn.execute(SETUP)
            print(f'One seat, {clients} students pressing Accept at the same moment.\n')
            for label, attempt in (('Naive read-then-write', naive), ('Atomic conditional UPDATE', atomic)):
                won, rows, left, ms = race(url, attempt, clients)
                verdict = 'correct' if rows == 1 else f'OVERBOOKED by {rows - 1}'
                print(f'{label:<28} {won:>3} accepted  {clients - won:>3} refused  '
                      f'seats_left={left}  {ms:6.0f} ms  -> {verdict}')
            print('\nThe naive version reads seats_left=1 in every client before any of them writes, so all of them')
            print('"take" the seat. The atomic UPDATE locks the row: later clients wait, re-check seats_left > 0')
            print('after the first commit, and update nothing.')
        finally:
            control.execute(sql.SQL('DROP DATABASE IF EXISTS {} WITH (FORCE)').format(sql.Identifier(name)))


if __name__ == '__main__':
    main()
