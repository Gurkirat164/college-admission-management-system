# College Admission Management System

React renders the student and staff workbench, Python/FastAPI manages authentication and private documents, and PostgreSQL executes admission rules. Both original plan documents are preserved.

## Run locally on Windows

Requirements: Node.js 20.19+ (or 22.12+), Python 3.11+ and PostgreSQL binaries. Setup detects installed PostgreSQL 16/18 and bundled Python; `PG_BIN` and `ADMISSION_PYTHON` override detection.

```powershell
npm run setup
npm run dev
```

Open <http://127.0.0.1:5173>. API docs: <http://127.0.0.1:8000/docs>. Setup initializes a separate project-owned cluster on port 55432. It generates synthetic demo records and random credentials under ignored `.local/`, and does not change an existing database service or deploy anything. Development sign-in shortcuts perform real authentication and are disabled in production. Ctrl+C stops the website/API/worker; `npm run stop` stops the project-owned database.

## Structure

| Path | Responsibility |
|---|---|
| `frontend/` | React screens, forms and API client |
| `backend/` | FastAPI, authentication, guarded SQL calls, storage and jobs |
| `database/migrations/` | Authoritative schema, functions, constraints and permissions |
| `database/seeds/` | Synthetic college-demo records |
| `functions/api/` | Cloudflare Pages same-origin proxy to Render |
| `backend/tests/`, `tests/` | Database/API, browser and proxy checks |
| `scripts/` | Local setup and verification launchers |
| `docs/`, `evidence/` | Operating guide, report, dictionary and measured verification |

The runtime database login is not the owner and cannot directly write admission tables. Applied migrations are checksum-verified: add migrations rather than modifying applied files. Credentials never belong in frontend build variables or Git.

## Workflows

Students can register, submit applications/documents, save ranked choices, inspect chance bands and mock outcomes, review explanations and respond to published results. Administrators can verify documents/results, preview/commit rank imports, configure rounds/deadlines, publish checked allocations, confirm admissions and manage spot seats. Analysts can replay immutable inputs, change capacity/withdrawals, inspect cutoffs and possible vacancy links, export masked CSV and pin runs. Auditors can verify ledger events/checkpoints and query system-time seat history.

The scheduler records mock/maintenance job status and refreshes predictions. Files use private local/S3 storage. Hosted requests pass through Pages so Secure authentication cookies remain on the frontend's default domain.

## Verification

```powershell
npm run build
npm run test:ui
npm run test:proxy
npm test
npm run verify:pg16
# With npm run dev running and Chrome installed:
npm run test:e2e
```

The baseline passed 38 database/API tests on PostgreSQL 16.15 and 18.4, six frontend request tests and six Chrome workflows. Recovery with a committed synthetic document, 100 random scenarios and the 500-request spot race passed. Deployment-specific tests supplement this baseline. See [verification evidence](evidence/local-verification.md).

The 20,000-student benchmark passed correctness checks but took a median **38.3 seconds** and measured p95 **43.3 seconds** across five sequential samples. The five-second target remains unmet. Free hosting may sleep; local measurements are not a hosted performance guarantee.

## Documentation and operations

- [Demo and operating guide](docs/demo-guide.md)
- [Project report](docs/project-report.md)
- [ER diagram](docs/er-diagram.md) and [data dictionary](docs/data-dictionary.md)
- [Implementation status](docs/implementation-status.md)
- [Deployment configuration](docs/deployment.md)

```powershell
npm run jobs:once
npm run backup:verify
npm run demo:new -- --name admission_demo_fresh
npm run schema:export
node scripts/python.mjs -m app.cli checkpoint
```

Fresh demo creation preserves the active dataset; switching requires explicit `--activate`. Recovery combines database and committed private objects. Keep audit checkpoints outside the workspace for independent protection. This fixed-pool demonstration excludes horizontal reservations, supernumerary seats and category conversion. Chance bands use synthetic history and are not calibrated probabilities. Vacancy links show possible propagation, not exact causation. History is system-time, not business-effective time.
