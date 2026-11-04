# Implementation status — 4 November 2026

Both original plan files are preserved. PostgreSQL, Python and the four-member team remain the agreed choices.

## Implemented

- Four roles, self-registration, Argon2 passwords, opaque sessions, CSRF and database-persistent login throttling.
- Annual applications, private document upload/review, verified exam records, CSV preview/commit and deterministic ranks from subject marks; manual external-rank entry is also supported.
- Ranked choices and PostgreSQL deferred acceptance over OPEN/verified category pools, with capacity/stability checks and applicable add-only monotonicity checks.
- Immutable snapshot replay, capacity and withdrawal controls, masked CSV, pinned comparisons, cutoff charts and possible vacancy links.
- Atomic/idempotent publication, configurable deadlines, FREEZE/FLOAT/SLIDE/WITHDRAW, later rounds, final confirmation and guarded spot acceptance/closure.
- Historical cutoff imports, target-year exclusion from historical prediction, freshness indicators, scheduled mock outcomes, durable jobs and maintenance retention.
- Audit hash chain/checkpoint comparison, system-time history, private local/S3 adapters, database-plus-document restore rehearsal and non-destructive fresh demos.
- Generated schema/data dictionary, operating guide, project report and deployment configuration for Git-connected Render/Cloudflare Pages with Neon.

## Verification and limits

The baseline passed 38 database/API tests on PostgreSQL 16.15 and 18.4, six request tests and six browser workflows. Additional deployment tests cover the proxy and protected scheduler. See `evidence/local-verification.md`.

The 20,000-student, 240,000-choice benchmark passed correctness checks but its 38,306 ms median and 43,251 ms p95 **do not meet the five-second target**. The p95 uses only five sequential samples. Free cloud compute is not covered by this local measurement.

The fixed-pool policy is a project demonstration, not national-policy certification. Horizontal reservations, supernumerary seats and category conversion are excluded. Possible vacancy links are not exact causal proof; history is system-time only. Synthetic chance bands are not calibrated probabilities. Runtime credentials are a trusted API boundary; arbitrary possession of them is outside that boundary. The audit chain requires an independently retained checkpoint to detect a complete owner-level rewrite.

Deployment resources and verified URLs are recorded in `docs/deployment.md` after provisioning.
