# Demo and operating guide

Use synthetic records. Local accounts appear on the sign-in page and in ignored `.local/demo-accounts.json`. Hosted credentials are generated separately and saved privately; production disables the development account endpoint.

## Student workflow

Register/sign in, complete an application, upload a synthetic PDF/PNG/JPEG (maximum 5 MB), submit, and save ranked choices. New applications require document/exam verification before approval. Inspect historical chance bands, freshness and the latest mock; mock outcomes do not create live holdings.

After publication, inspect the pool/explanation and respond before the configured deadline. FREEZE keeps the place; FLOAT permits better choices; SLIDE permits better choices in the same institute; WITHDRAW removes it. Closure applies the configured default. Spot acceptance is transactional and enforces one current holding.

## Administrator workflow

Signing in opens the Overview for the current round. It shows the published allocation, or the latest live baseline before publication, as a seat plan. Select any seat (or any dot in the rank chart) to see who holds it, which rank and choice won it and, where relevant, why a reserved-pool applicant got a better choice than someone with a better common rank. The data comes from one read-only SQL function, `admin_overview(year)` in migration 0019.

Review documents and exam records. Imports provides sample CSV downloads from `frontend/public/samples/`. Preview validates subject totals, ranks and data; commit rejects a stale preview when source inputs change. Manual external ranks are also supported. Target-year outcomes are excluded from that year's historical predictor.

Configure a future response deadline, run a baseline, inspect its checks, lock the round and explicitly publish. Publication cannot be undone in the app. Later rounds start LOCKED; reopen choices intentionally. Close responses only after the deadline, start later rounds as needed, confirm final admissions after closure and explicitly close the spot phase.

Operations shows job outcomes and predictor freshness. The local worker starts with `npm run dev`. Hosted scheduling uses a protected endpoint and GitHub Actions at 02:00 India time. Free services may wake slowly and cron may be delayed; manual catch-up is available.

## Analyst and auditor workflow

Compare a saved baseline using immutable inputs. Change capacity, specify withdrawals or choose a deterministic rate/seed. Inspect assignments, cutoffs and possible vacancy links; export masked CSV and pin runs. Scenarios do not change live seat capacity. Add-only monotonicity applies only when all other inputs are unchanged.

Audit & history verifies the chain, lists event metadata, compares trusted checkpoints and reads capacity at a UTC system timestamp. Keep checkpoint exports outside this workspace: an owner who can replace the chain and every checkpoint can rewrite the full history.

## Recovery and fresh demos

`npm run backup:verify` backs up database state and committed private objects, restores into a uniquely named disposable database, verifies table/document hashes, migrations, ledger and privileges, then drops only that restore database. Protect `.local/backups` like the original records. A hosted backup must include its committed object keys, not just a database dump.

`npm run demo:new -- --name admission_demo_fresh` refuses an existing name and preserves active configuration. Only explicit `--activate` switches the local backend. Use a fresh demo for irreversible publication/closure demonstrations.

## DBMS walkthrough for the viva

Keep a `psql "$MIGRATION_DATABASE_URL"` window beside the browser. The files in `database/showcase/` each demonstrate one concept against the real tables and roll back afterwards: constraints refusing bad data (01), triggers writing the audit chain and history (02), example queries with joins, window functions, a recursive CTE and `EXPLAIN` (04), and row-level security (06). Files 03 and 05 are commented reading copies of the locking code and the allocation solver.

`npm run demo:race` shows concurrency control live: in a throwaway database, many clients press Accept on one remaining seat at once. A naive read-then-write overbooks it; the atomic conditional `UPDATE` used by `accept_spot()` accepts exactly one.

