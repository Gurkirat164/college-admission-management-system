# DBMS showcase

Readable, commented SQL for the viva: one file per concept, using the project's real tables. The migrations in [`../migrations/`](../migrations/README.md) stay the source of truth; nothing here changes the schema.

Runnable files open a transaction and roll it back, so they leave the demo data untouched. Run them as the owner, with the URL from `backend/.env`:

```bash
psql "$MIGRATION_DATABASE_URL" -f database/showcase/01_keys_and_constraints.sql
```

| File | Concepts | Runs? |
|---|---|---|
| [01_keys_and_constraints.sql](01_keys_and_constraints.sql) | Composite primary keys, UNIQUE, CHECK, FOREIGN KEY, ENUM domain, exclusion constraint: each one refusing bad data | Yes |
| [02_triggers.sql](02_triggers.sql) | BEFORE trigger (choice deadline guard), AFTER triggers (hash-chained audit log, temporal history) | Yes |
| [03_transactions_and_locking.sql](03_transactions_and_locking.sql) | Atomic conditional UPDATE, `FOR UPDATE` row locks, advisory locks, idempotency, REPEATABLE READ, retry on 40001/40P01 | Reading copy |
| [04_queries.sql](04_queries.sql) | Joins, GROUP BY/HAVING, FILTER, window functions, correlated subquery, recursive CTE, temporal range query, view, `EXPLAIN` | Yes (read-only) |
| [05_allocation.sql](05_allocation.sql) | The deferred-acceptance solver as set-based SQL, with its stability and capacity proofs | Reading copy |
| [06_row_level_security.sql](06_row_level_security.sql) | Row-level security policies, and why the app relies on privileges and SECURITY DEFINER functions instead | Yes |

For concurrency under real load, run `npm run demo:race`. It fires many simultaneous seat requests at one seat, first with a naive read-then-write and then with the project's atomic update, in a throwaway database. Normalization is covered in [`docs/normalization.md`](../../docs/normalization.md) and the full ER diagram in [`docs/er-diagram.md`](../../docs/er-diagram.md).

## Access control in one paragraph

The API logs in as `admission_app`, which has **no privileges on any table**. It can only `EXECUTE` an approved list of functions. Each function is `SECURITY DEFINER` (it runs with the owner's rights), pins its `search_path`, and starts with `require_role(...)`, which reads the signed-in user that the API placed in the transaction (`app.user_id`) and raises error 42501 for the wrong role. Row-level security policies on the nine student-data tables are a second layer: they apply to any non-owner role that is ever given table access, as file 06 shows, but the owner-run functions bypass them by design.
