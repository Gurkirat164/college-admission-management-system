# Demo and operating guide

Use synthetic records. Local accounts appear on the sign-in page and in ignored `.local/demo-accounts.json`. Hosted credentials are generated separately and saved privately; production disables the development account endpoint.

## Student workflow

Register/sign in, complete an application, upload a synthetic PDF/PNG/JPEG (maximum 5 MB), submit, and save ranked choices. New applications require document/exam verification before approval. Inspect historical chance bands, freshness and the latest mock; mock outcomes do not create live holdings.

After publication, inspect the pool/explanation and respond before the configured deadline. FREEZE keeps the place; FLOAT permits better choices; SLIDE permits better choices in the same institute; WITHDRAW removes it. Closure applies the configured default. Spot acceptance is transactional and enforces one current holding.

## Administrator workflow

Review documents and exam records. Imports provides sample CSV downloads from `frontend/public/samples/`. Preview validates subject totals, ranks and data; commit rejects a stale preview when source inputs change. Manual external ranks are also supported. Target-year outcomes are excluded from that year's historical predictor.

Configure a future response deadline, run a baseline, inspect its checks, lock the round and explicitly publish. Publication cannot be undone in the app. Later rounds start LOCKED; reopen choices intentionally. Close responses only after the deadline, start later rounds as needed, confirm final admissions after closure and explicitly close the spot phase.

Operations shows job outcomes and predictor freshness. The local worker starts with `npm run dev`. Hosted scheduling uses a protected endpoint and GitHub Actions at 02:00 India time. Free services may wake slowly and cron may be delayed; manual catch-up is available.

## Analyst and auditor workflow

Compare a saved baseline using immutable inputs. Change capacity, specify withdrawals or choose a deterministic rate/seed. Inspect assignments, cutoffs and possible vacancy links; export masked CSV and pin runs. Scenarios do not change live seat capacity. Add-only monotonicity applies only when all other inputs are unchanged.

Audit & history verifies the chain, lists event metadata, compares trusted checkpoints and reads capacity at a UTC system timestamp. Keep checkpoint exports outside this workspace: an owner who can replace the chain and every checkpoint can rewrite the full history.

## Recovery and fresh demos

`npm run backup:verify` backs up database state and committed private objects, restores into a uniquely named disposable database, verifies table/document hashes, migrations, ledger and privileges, then drops only that restore database. Protect `.local/backups` like the original records. A hosted backup must include its committed object keys, not just a database dump.

`npm run demo:new -- --name admission_demo_fresh` refuses an existing name and preserves active configuration. Only explicit `--activate` switches the local backend. Use a fresh demo for irreversible publication/closure demonstrations.
