# College Admission Management System — project report

## Architecture and data model

This four-member project demonstrates admission workflows with PostgreSQL enforcing allocation and consistency. React/TypeScript provides the workbench. Python/FastAPI authenticates requests, validates uploads and calls guarded SQL routines. Versioned migrations own the schema, permissions, solver, audit and history. The hosting layout is Cloudflare Pages for frontend/proxy, Render for Python and Neon for PostgreSQL/private objects.

Annual application/exam records separate student identity from changing cycle data. Institute-scoped programs avoid ambiguous names. Keys/constraints protect ranked choices, annual pools and capacities. Immutable simulation inputs and derived prediction views intentionally duplicate data for reproducibility and read performance; live records remain authoritative for publication.

## Allocation and consistency

The solver expands each student's ranked programs into eligible OPEN/category proposals. OPEN uses common rank; reserved pools use verified category rank. Original program preference is retained through expansion. Deferred acceptance holds each pool's best eligible candidates until proposals stop. FREEZE reserves previous capacity; FLOAT/SLIDE restrict improvements while preserving exact prior fallbacks. Withdrawals remove participation.

Runs persist immutable inputs/hash, results and proposal explanations. Capacity, blocking-pair stability and no-downgrade checks precede publication. Add-only scenarios check applicable monotonicity against identical saved inputs. Publication requires unchanged live inputs, a locked round, administrator identity and an idempotency key. Holdings/status/audit commit together. Bounded serialization/deadlock retries protect concurrent operations. Spot acceptance locks capacity and enforces one current annual holding.

## Security and audit

Argon2 protects passwords; opaque session and CSRF values are stored as digests. HTTPS Secure cookies stay on the frontend domain through the Pages proxy. Exact Origin validation, CSRF and a server-only upstream secret protect mutations. Login limits persist in PostgreSQL. Production hides development accounts. Files are size/type/signature-checked, privately stored and authorized on download.

The runtime role has approved EXECUTE privileges, not direct base writes. SECURITY DEFINER routines validate the API-supplied actor/role. The API credentials remain a trusted boundary: custom session identity does not replace an identity provider when an attacker possesses arbitrary database access. Owner credentials are excluded from the hosted runtime.

The audit ledger hashes complete event envelopes into a protected chain head. An independently retained checkpoint detects divergence; it cannot prevent an owner rewriting both the chain and all trusted copies. Seat history uses system statement time, not separately editable business-effective time.

## Verification and performance

The baseline passed 38 PostgreSQL/API tests on both 16.15 and 18.4, six frontend request tests and six Chrome workflows. It covers privacy, imports, roles/CSRF, replay, transitions, publication, jobs, audit, retention, final admissions and independent restore with a committed document. Deployment tests add proxy/token checks.

The scale fixture has 20,000 students, 240,000 choices, 30 programs and 150 pools. Five sequential runs gave median 38,306 ms and nearest-rank p95 43,251 ms. Correctness passed but the five-second target was not achieved. Solver and verification/persistence dominate phase timing. Three concurrent analyst runs passed with bounded retries. Under load, 922 student workspace requests had a 21.835 ms median and 254.81 ms maximum on the local machine.

For one available spot place, 500 requests through 50 clients produced one acceptance, 499 unavailable responses and no failure/overbooking. One hundred seeded add-only scenarios of 300 students produced zero violations. An intentionally unsafe disposable-table race accepted 50 requests for one place. Raw evidence/query plans are committed; local results do not promise free-cloud performance.

## Scope and operations

This fixed-pool college demo does not certify national admissions policy. Horizontal reservations, supernumerary places and category conversion are excluded. Vacancy links indicate possible propagation rather than exact causal tokens. Historical examples are synthetic; bands are not calibrated probabilities. Free services can sleep and scheduling is best-effort; durable jobs support retries/catch-up.

Migrations are checksum-verified. Recovery combines database state with committed private objects. Fresh-demo creation requires a new explicit name and preserves the active instance unless switching is requested. Both original plan files remain unchanged.
