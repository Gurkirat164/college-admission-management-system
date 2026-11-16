# College Admission Management System

A full-stack college admission management platform built with **React, FastAPI, and PostgreSQL**. It provides student application workflows, administrative admission management, automated seat allocation, analytics, document verification, and auditable admission history.

The system is designed around database-enforced admission rules, controlled access to sensitive operations, and reproducible allocation workflows.

## Live Demo

**Hosted Application:** [College Admission Management System](https://college-admission-164.pages.dev)

- **Frontend:** Cloudflare Pages
- **Backend:** Python / FastAPI on Render
- **Database:** PostgreSQL on Neon
- **Deployment:** Git-based deployments from the connected repository

Both original project plan documents are preserved.

> Hosted demonstration credentials are shared privately and are never exposed through the public application.

## Architecture

The application follows a layered architecture with clearly separated frontend, backend, and database responsibilities.

| Layer | Technology | Responsibility |
|---|---|---|
| Frontend | React | Student and staff interfaces, forms, dashboards and API communication |
| Backend | Python, FastAPI | Authentication, authorization, document handling, business workflows and background jobs |
| Database | PostgreSQL | Admission rules, constraints, allocation logic, transactions, permissions and audit history |
| Deployment Proxy | Cloudflare Pages Functions | Same-origin API proxy to the hosted backend |
| Storage | Private local / S3-compatible storage | Secure document storage |

**Key architectural decisions:**
- Database functions and constraints enforce critical admission rules.
- The application runtime uses a restricted database login rather than the database owner.
- Sensitive database operations are exposed through guarded backend workflows.
- Private documents are stored separately from public application assets.
- Hosted requests pass through Cloudflare Pages to maintain same-origin authentication cookies.
- Database migrations are checksum-verified to prevent accidental modification of previously applied migrations.

## Features

### Student Portal
- Student registration and authentication.
- Admission application submission.
- Private document uploads and management.
- Ranked course and college preferences.
- Admission chance bands and mock allocation outcomes.
- Allocation explanations and published result review.
- Admission response and confirmation workflows.

### Administration Portal
- Centralized administrative overview.
- Seat allocation dashboard showing who holds each seat and why.
- Rank-versus-choice analytics.
- Document and result verification.
- Rank-list import with preview and commit workflows.
- Admission rounds, deadlines and capacity configuration.
- Checked allocation publication.
- Admission confirmation and spot-seat management.

### Analytics and Simulation
- Replayable allocation runs using immutable inputs.
- Scenario analysis involving seat capacity and student withdrawals.
- Cutoff analysis and possible vacancy propagation.
- Masked CSV exports.
- Pinned simulation runs for comparison.
- Synthetic admission scenarios for testing allocation behavior.

### Audit and Historical Tracking
- Immutable audit ledger events.
- Audit checkpoint verification.
- System-time seat history queries.
- Traceability of administrative and allocation operations.

### Background Processing
- Scheduled mock allocation and maintenance jobs.
- Job execution status tracking.
- Automated prediction refreshes.
- Private document storage using local or S3-compatible backends.

## Technology Stack

| Category | Technologies |
|---|---|
| Frontend | React, TypeScript, CSS |
| Backend | Python, FastAPI |
| Database | PostgreSQL |
| API Documentation | OpenAPI, Swagger UI |
| Deployment | Cloudflare Pages, Render |
| Database Hosting | Neon |
| Storage | Private local / S3-compatible storage |
| Testing | Database/API tests, frontend request tests, Chrome E2E tests |
| Formatting | Prettier |

## Project Structure

```text
college-admission-management-system/
│
├── frontend/                # React screens, forms and API client
│
├── backend/                 # FastAPI, authentication, storage and jobs
│   └── tests/               # Backend tests
│
├── database/
│   ├── migrations/          # Authoritative schema and database logic
│   ├── showcase/             # Commented SQL examples for DBMS concepts
│   └── seeds/                # Synthetic demonstration records
│
├── functions/
│   └── api/                  # Cloudflare Pages API proxy
│
├── tests/                    # Browser and proxy tests
│
├── scripts/                  # Setup and verification utilities
│
├── docs/                     # Reports, architecture and documentation
│
└── evidence/                 # Test results and verification evidence
```

## Getting Started

### Prerequisites

Install the following before setting up the project:

| Dependency | Requirement |
|---|---|
| Node.js | 20.19+ or 22.12+ |
| Python | 3.11+ |
| PostgreSQL | Version 16 or 18 binaries |

The setup process automatically detects PostgreSQL installations in common locations, including Windows installers, Postgres.app, Homebrew and Debian/Ubuntu packages.

Python must be available through PATH.

Optional environment overrides:

- `PG_BIN`: PostgreSQL binary directory.
- `ADMISSION_PYTHON`: Python executable path.

### Installation and Execution

Run the following commands from the project root.

```powershell
npm run setup
npm run dev
```

Open the application:

- **Frontend:** http://127.0.0.1:5173
- **API Documentation:** http://127.0.0.1:8000/docs

### Local Environment Behavior

The setup process:

- Initializes a separate, project-owned PostgreSQL cluster on port `55432`.
- Generates synthetic demonstration records.
- Creates random development credentials.
- Stores generated local files under the Git-ignored `.local/` directory.
- Does not modify existing PostgreSQL services.
- Does not deploy or modify hosted environments.

Development sign-in shortcuts perform real authentication and are disabled in production.

**Stopping services:**

- `Ctrl + C` stops the website, API and worker.
- `npm run stop` stops the project-owned PostgreSQL instance.

## Database Engineering and Security

The database is a core part of the application's architecture, not simply a persistence layer.

- Database migrations define the authoritative schema, functions, constraints and permissions.
- Admission operations use controlled database functions and guarded SQL calls.
- The application runtime login is not the database owner and cannot directly write to admission tables.
- Applied migrations are checksum-verified. New changes must be introduced through additional migrations rather than modifying previously applied files.
- Credentials are never stored in frontend build variables or committed to Git.
- Private documents are not exposed through public application assets.

For database demonstrations, `database/showcase/` contains readable and commented SQL examples covering major DBMS concepts. Most examples are independently executable and suitable for the project viva.

## Interface and Design

The interface follows a consistent design system:

- Single top navigation bar.
- Minimal page titles and uncluttered layouts.
- Light and dark themes.
- System theme detection until the user selects a preference.
- Bundled Host Grotesk and Fragment Mono fonts, licensed under SIL Open Font License.

Font assets are maintained in:

```text
frontend/src/assets/fonts/
```

Frontend formatting uses Prettier.

```powershell
npx prettier@3.6.2 --write "frontend/src/**/*.{ts,tsx,css}"
```

## Testing and Verification

Run the verification commands from the project root.

```powershell
npm run build
npm run test:ui
npm run test:proxy
npm test
npm run verify:pg16
```

For end-to-end browser testing, with `npm run dev` running and Chrome installed:

```powershell
npm run test:e2e
```

### Recorded Verification Results

| Test Category | Result |
|---|---|
| Database/API tests | 41 passing |
| Frontend request tests | 6 passing |
| Chrome end-to-end workflows | 6 passing |
| PostgreSQL 18 local suite | Passing |
| PostgreSQL 16.15 baseline | Earlier 38-test suite passing |
| Recovery testing | Passed |
| 100 randomized scenarios | Passed |
| 500-request spot allocation race | Passed |

The current local suite contains 41 database/API tests, six frontend request tests and six Chrome workflows.

The committed verification evidence also includes an earlier baseline covering PostgreSQL 16.15 and PostgreSQL 18.4.

See [Local Verification Evidence](evidence/local-verification.md) for recorded results.

### Performance Benchmark

The 20,000-student benchmark passed its correctness checks but did not meet the five-second performance target.

| Metric | Measured Result |
|---|---:|
| Dataset | 20,000 students |
| Median execution time | 38.3 seconds |
| P95 execution time | 43.3 seconds |
| Samples | 5 sequential runs |
| Target | 5 seconds |

The performance target remains unmet. These measurements are local benchmark results, not guarantees of hosted performance. Free hosting instances may also experience cold starts or sleep periods.

## Documentation

| Document | Description |
|---|---|
| [Demo and Operating Guide](docs/demo-guide.md) | Demonstration workflows and operational instructions |
| [Project Report](PROJECT_REPORT.md) · [PDF](PROJECT_REPORT.pdf) | Project report with diagrams and screenshots |
| [Technical Summary](docs/project-report.md) | Architecture, security, and verification notes |
| [ER Diagram](docs/er-diagram.md) | Entity relationships and database structure |
| [Normalization](docs/normalization.md) | Database normalization documentation |
| [Data Dictionary](docs/data-dictionary.md) | Database entities, attributes and definitions |
| [DBMS Showcase](database/showcase/README.md) | SQL demonstrations of DBMS concepts |
| [Migration Index](database/migrations/README.md) | Database migration history |
| [Implementation Status](docs/implementation-status.md) | Implementation progress and current status |
| [Deployment Configuration](docs/deployment.md) | Hosting and deployment details |

## Useful Maintenance Commands

### Background Jobs

```powershell
npm run jobs:once
```

### Backup Verification

```powershell
npm run backup:verify
```

### Create a Fresh Demonstration Dataset

```powershell
npm run demo:new -- --name admission_demo_fresh
```

Creating a fresh demonstration dataset preserves the active dataset. Switching to the new dataset requires the explicit `--activate` option.

### Export Database Schema

```powershell
npm run schema:export
```

### Regenerate ER Diagram

```powershell
npm run docs:er
```

Generates `docs/er-diagram.md` from the migrated database schema.

### Allocation Race Demonstration

```powershell
npm run demo:race
```

Demonstrates the difference between naive seat updates and atomic database operations under concurrent requests.

### Create Audit Checkpoint

```powershell
node scripts/python.mjs -m app.cli checkpoint
```

## Known Limitations and Design Constraints

The system has several explicitly documented limitations:

1. **Fixed seat pool:** The demonstration currently excludes horizontal reservations, supernumerary seats and category conversion.
2. **Admission predictions:** Chance bands are derived from synthetic historical data and are not calibrated probabilities.
3. **Vacancy propagation:** Vacancy links illustrate possible propagation paths, not exact causal relationships.
4. **Historical tracking:** Seat history uses system-time tracking rather than business-effective time.
5. **Performance:** The 20,000-student benchmark currently exceeds the five-second target.
6. **Hosting:** Free-tier infrastructure may introduce cold starts and availability delays.

---

**College Admission Management System**  
A database-driven admission platform demonstrating full-stack development, relational database engineering, transaction safety, automated allocation, and auditable administrative workflows.