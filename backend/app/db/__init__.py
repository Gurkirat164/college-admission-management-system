from contextlib import contextmanager

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from app.core.config import settings

pool = ConnectionPool(settings.database_url, min_size=0, max_size=8, open=False,
                      kwargs={"row_factory": dict_row,"options":"-c temp_buffers=64MB"}, timeout=10)


@contextmanager
def transaction(user_id=None, repeatable=False):
    with pool.connection() as conn:
        if repeatable:
            conn.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        conn.execute("SET LOCAL statement_timeout = '300s'")
        if user_id is not None:
            conn.execute("SELECT set_config('app.user_id', %s, true)", (str(user_id),))
        yield conn
