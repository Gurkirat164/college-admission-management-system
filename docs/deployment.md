# Deployment configuration

GitHub is the source for Git-connected Render and Cloudflare Pages. Use default `onrender.com` and `pages.dev` domains. Resources created on 4 November 2026:

| Component | Resource |
|---|---|
| GitHub source (private; pushed using Git CLI) | https://github.com/Gurkirat164/college-admission-management-system |
| Frontend | https://college-admission-164.pages.dev |
| Backend readiness | https://college-admission-api-164.onrender.com/api/v1/ready |
| Neon project | `college-admission-management-system` / `twilight-sound-37433215` |
| Neon production branch / private bucket | `main` / `admission-documents` |

Migrations and synthetic seed were checked on the expiring `deployment-check` branch before main. Both branches passed the cloud solver checks and denied runtime base-table reads. Private S3 write/read/delete was verified. Hosted account credentials are saved only in ignored `.local/deployment/demo-credentials.txt`; the production development-account endpoint stays disabled. No custom domain or paid service was configured.

## Cloudflare Pages

Repository-root build: `npm run build`; output: `frontend/dist`; Node 24. Root `functions/api/[[path]].js` proxies `/api/*`; `_routes.json` limits function invocations. Leave `VITE_API_BASE` unset (default `/api/v1`). Runtime bindings: `API_ORIGIN` is the Render HTTPS origin and `PROXY_SECRET` is a server-only secret. Never put credentials into Vite variables. Preview domains are not automatically trusted.

## Render

Python 3.12.14, repository root, free Singapore web service. Build: `pip install -r backend/requirements.s3.lock.txt && pip install './backend[s3]'`. Start: `uvicorn app.main:app --host 0.0.0.0 --port $PORT`. Readiness path: `/api/v1/ready`. See `render.yaml`.

Runtime values: non-owner direct `DATABASE_URL`, `APP_ENV=production`, `COOKIE_SECURE=true`, exact Pages `FRONTEND_ORIGIN`, `STORAGE_BACKEND=s3`, `S3_BUCKET`, `S3_ENDPOINT`, `S3_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `PROXY_SECRET`, `JOB_TOKEN`, `SCHEDULER_USER_ID`. Do not deploy `MIGRATION_DATABASE_URL`.

The solver uses temporary tables/session state, so use a direct Neon connection. The Python pool is bounded to eight connections. Web startup never migrates/reseeds.

## Neon and scheduled jobs

New PostgreSQL 16 project in AWS Singapore. Verify migrations on an isolated branch before main. Create the non-owner `admission_app` role, migrate as owner, seed synthetic records and a separate scheduler identity. Keep account passwords private. Documents use a private bucket with SigV4/path-style S3 access; authorized API routes stream objects by private key.

GitHub Actions calls `/internal/jobs/daily` at 02:00 India time using repository secret `ADMISSION_JOB_TOKEN` and variable `ADMISSION_API_ORIGIN`. The dedicated token guards the endpoint and schedule slots are idempotent. Free scheduling can be delayed; manual dispatch supports catch-up without a paid Render cron service.

Cloud secrets/account credentials stay under ignored `.local/deployment/`; local `backend/.env` is preserved. Rotate proxy values in both Pages/Render and job tokens in both GitHub/Render. Review staged files for credentials before pushing.


## Verified hosted behavior

The default Pages domain passed real sign-in for student/admin/analyst/auditor roles, Secure same-origin session/CSRF cookies, private document upload/download, denial of anonymous/other-student document access, role/CSRF/Origin guards, masked CSV export, a PostgreSQL allocation and ledger verification. Direct API bypass and unauthenticated scheduling were rejected. The browser loaded the updated student workspace without errors or horizontal overflow.

GitHub verification passed 40 PostgreSQL/API tests, six frontend tests, two proxy tests and the production build. A manual execution of the scheduled workflow completed both nightly mock and maintenance jobs. Scheduling remains best-effort on free services. The measured large-data five-second target is still unmet as documented in local evidence. See `evidence/deployment-verification.json` for dated results and run links.
