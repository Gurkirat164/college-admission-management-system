# Migrations

Files run in name order. `app.cli migrate` records each file's SHA-256 in `public.schema_migration` and refuses to continue if an applied file later changes, so **never edit an applied migration: add a new one**. Reformatting counts as a change. For readable, commented versions of the important SQL, see [`../showcase/`](../showcase/README.md).

| File | What it adds |
|---|---|
| 0001_core_schema | Schema, `seat_cat` enum, all core tables, keys and constraints; `actor()` / `require_role()`; row-level security policies on student tables |
| 0002_integrity | Hash-chained audit ledger and its triggers, seat-capacity history (`tstzrange` + exclusion constraint), the choice-deadline guard trigger, `verify_ledger()` |
| 0003_accounts_and_workflows | Sessions, registration, sign-in lookups, documents, application and document review, choices, responses, round lock/close, `workspace()` |
| 0004_allocation_and_simulations | First version of `run_allocation()` (deferred acceptance), `why_not()` explanations |
| 0005_predictor_spot_and_access | Chance bands and the `mv_cutoff_trend` materialized view, spot round (`accept_spot()`), final admission, seat history lookup, runtime-role grants |
| 0006_round_management | Later rounds and response deadlines |
| 0007_allocator_record_scope | `run_allocation()` v2: variable scoping fix |
| 0008_complete_local_workflows | Subject marks, CSV rank and history imports, durable jobs, login throttling, final admission table, prediction freshness, retention |
| 0009_allocator_validation_and_scale | `run_allocation()` v3: input validation, linear-time stability check |
| 0010_simulation_analysis | `simulation_analysis()` (cutoffs, vacancy links), `own_holding()` |
| 0011_jobs_and_failures | Job targets and operation-failure logging |
| 0012_solver_working_set | `run_allocation()` v4: bounded working tables per iteration |
| 0013_prediction_year_and_audit_views | Target-year exclusion for predictions, audit event paging, checkpoints, `allocation_trace` view |
| 0014_explanation_reason_codes | `run_allocation()` v5: reason codes for unplaced applicants |
| 0015_allocation_phase_timings | **Live `run_allocation()`** (v6): per-phase timings |
| 0016_result_consistency | Subject-marks total CHECK, stricter application review |
| 0017_retention_and_simulation_summary | Simulation pruning; job history survives pruned runs |
| 0018_later_round_state | Later rounds start locked |
| 0019_admin_overview | `admin_overview(year)` for the admin Overview page: seat plan, demand, funnel, solver timings, recent activity |
| 0020_login_attempt_key | Primary key for `login_attempt`, the only table without one |

`run_allocation()` appears six times (0004, 0007, 0009, 0012, 0014, 0015) because each change re-created the whole function. Only the last definition is live.
