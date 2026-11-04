# Local verification — 4 November 2026

Windows, Node.js 24.18.0, Python 3.12.14, PostgreSQL 16.15 and 18.4. Isolated servers use ports 55433 and 55432; the existing Windows service was not changed.

| Check | Recorded result |
|---|---|
| Database/API baseline suite | 38 passed on PostgreSQL 16.15; 38 passed on 18.4 |
| Frontend request tests | 6 passed |
| Chrome workflows | 6 passed |
| Production build | Passed |
| Static interface review | 0 failures/reflex findings/warnings across 25 files |
| Desktop/mobile layout | 1440/390 px; no document overflow or browser page errors |
| Restore with committed synthetic document | Database/table/document hashes, ledger and runtime-role checks passed |
| 100 seeded add-only scenarios, 300 students each | 0 violations |
| 500 spot requests, 50 concurrent clients, capacity one | 1 accepted, 499 unavailable, 0 failed, 1 holding |
| Three concurrent analyst allocations | All passed; 0/1/2 serialization retries |
| Student HTTP under allocation load | 922 samples; median 21.835 ms, maximum 254.81 ms |

The scale fixture contains 20,000 students, 240,000 choices, 30 programs and 150 pools. Five sequential SQL samples gave a **38,306 ms median** and **43,251 ms nearest-rank p95**. Capacity, stability and applicable monotonicity passed; the **five-second target was not met**. Phase timings/query plans are in `scale-verification.json` and `query-plans.json`. Local results are not a hosted performance guarantee. Concurrent runs also contend on the serial audit chain.

The deliberately unsafe demonstration accepted 50 requests for one place in a disposable verification table. The guarded spot workflow did not overbook.

Integration tests create/drop only their own `admission_test_<random>` databases. Coverage includes roles, CSRF, choices, replay, rollback, publication/idempotency, multi-round responses, rank imports, document verification/privacy, jobs, predictor freshness, retention, final confirmation, audit, storage and restore. Browser checks exercise student choices, admin/analyst simulations, advanced controls/CSV/pinning, mock outcomes, imports/round-settings/admission screens and auditor events. They do not lock/publish the main demo round.

`backend-pg16.xml` and `backend-pg18.xml` record the baseline, before the final deployment-boundary additions; those have separate focused tests. The final Linux/GitHub PostgreSQL 16 run passed all 40 tests, six frontend tests and two proxy tests; the hosted checks are recorded in `deployment-verification.json`. One Starlette HTTPX TestClient deprecation warning remains. Hallmark's Puppeteer rendering tier was unavailable; real Chrome/Playwright supplied workflows, screenshots and viewport measurements.

## Reproduce

```powershell
npm run build
npm run test:ui
npm run test:proxy
npm test
npm run verify:pg16
npm run verify:scale
npm run backup:verify
# With the local app running separately:
npm run test:e2e
node scripts/preview-check.mjs
```

Scale runs use disposable `admission_verify_<random>` databases. Dumps, documents, credentials and screenshots stay under ignored `.local/`. Both original plan files were hash-checked and remain unchanged.
