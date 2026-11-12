# Normalization

This page lists the functional dependencies (FDs) of the core tables, the normal form each table reaches, and the places where the design stores something twice on purpose. Column names match the migrations; the full diagram is in [er-diagram.md](er-diagram.md).

Notation: `A → B` means a value of A determines exactly one value of B. A *candidate key* is a minimal set of columns that determines every other column.

## Quick refresher

| Form | Rule | How this schema meets it |
|---|---|---|
| 1NF | Every column holds one atomic value, and every row is identifiable by a key. | Every table has a primary key (migration 0020 added the last one, to `login_attempt`). Lists are rows, not comma-separated text: a student's preferences are rows of `choice`, not an array. |
| 2NF | 1NF, and no non-key column depends on only part of a composite key. | Composite keys such as `(student_id, year)` exist because the dependent facts really are per student *per year*. |
| 3NF | 2NF, and no non-key column depends on another non-key column. | Lookups live in their own tables: a program's name is in `program`, not repeated on every `choice`. |
| BCNF | For every non-trivial FD `X → Y`, X is a candidate key. | True for the core tables below, including those with two candidate keys. |

## Core tables

| Table | Candidate keys | Functional dependencies | Form |
|---|---|---|---|
| `student` | `student_id` | `student_id → full_name, dob` | BCNF |
| `app_user` | `user_id`; `email`; `student_id` (when not null) | `user_id → email, password_hash, full_name, role, student_id, enabled`; `email → user_id`; `student_id → user_id` | BCNF (see note 1) |
| `admission_cycle` | `year` | `year → input_revision, choices_locked, choice_deadline, policy_version` | BCNF |
| `application` | `(student_id, year)` | `(student_id, year) → admission_category, status, choices_locked_at, review_reason` | BCNF |
| `exam_result` | `(student_id, year)`; `(year, crl_rank)` | `(student_id, year) → total_marks, crl_rank, cat_rank, maths, physics, chemistry`; `(year, crl_rank) → student_id` | BCNF (see note 2) |
| `program` | `program_id`; `(institute, code)` | `program_id → institute, code, name`; `(institute, code) → program_id` | BCNF |
| `program_eligibility` | `(year, program_id)` | `(year, program_id) → min_marks` | BCNF |
| `seat_matrix` | `(year, program_id, seat_category)` | `(year, program_id, seat_category) → seats` | BCNF |
| `choice` | `(student_id, year, pref_order)`; `(student_id, year, program_id)` | `(student_id, year, pref_order) → program_id`; `(student_id, year, program_id) → pref_order` | BCNF |
| `counselling_round` | `round_id`; `(year, round_no)`; `published_sim_id` (when not null) | `round_id → year, round_no, status, response_deadline, published_at, published_sim_id, publish_key` | BCNF |
| `student_response` | `(round_id, student_id)` | `(round_id, student_id) → decision, responded_at, is_default` | BCNF |
| `seat_holding` | `(year, student_id)` | `(year, student_id) → program_id, seat_category, source, final` | BCNF; the key itself enforces "one seat per student per year" |
| `final_admission` | `(year, student_id)` | `(year, student_id) → confirmed_by, confirmed_at` | BCNF |
| `spot_pool` | `pool_id`; `(year, program_id, seat_category)` | `pool_id → year, program_id, seat_category, initial_capacity, seats_left, status` | BCNF |
| `document_submission` | `document_id`; `storage_key` | `document_id → student_id, year, original_name, storage_key, mime_type, checksum, byte_count, status, reason, created_at` | BCNF |

### Notes

1. **`full_name` appears in both `student` and `app_user`.** Staff accounts (admin, analyst, auditor) have no `student` row but still need a display name, so `app_user` carries one. For a student account the name is therefore stored twice. It is a known redundancy: a fully normalized design would move the name into a shared `person` table referenced by both.
2. **`total_marks` is derivable from the three subject marks.** It is stored because manual rank entry may have a total without subject marks. Migration 0016 adds a CHECK that keeps `total_marks = maths + physics + chemistry` whenever all three are present, so the copy cannot drift.

## Deliberate denormalization

These tables repeat data on purpose. Each repetition has a reason and a rule that keeps it correct.

| Where | What is repeated | Why | What keeps it correct |
|---|---|---|---|
| `allocation.rank_used`, `allocation.pref_order` | The rank and preference number that won the seat, also derivable from `exam_result` and `choice` | A published allocation is a historical record. If a rank is corrected later, the allocation must still show the rank that was actually used. | Rows are written once at publication, inside the same transaction that locks the round. |
| `spot_acceptance.year` | Also reachable as `pool_id → spot_pool.year` (a transitive dependency, so strictly not 3NF) | `UNIQUE(year, student_id)` needs `year` in the same table to enforce "one spot acceptance per student per year" declaratively. | A foreign key on `(student_id, year)` to `application`, and the acceptance function copies `year` from the pool. |
| `sim_input_snapshot.payload` (JSONB) | A full copy of seats, applicants, choices and the previous round | Any run can be replayed exactly, even after live data changes. Not 1NF by design. | `payload_hash` (SHA-256) is checked before every replay. |
| `sim_result`, `sim_trace`, `sim_diff` | Allocation-shaped rows per run | Runs are immutable experiments; comparing two runs must not depend on live tables. | Cascade-deleted with their `sim_run`. |
| `hist_closing`, `mv_cutoff_trend` | Opening and closing ranks derived from results | Read speed for the predictor. | Rewritten on publish; the materialized view is refreshed and `prediction_state.stale` records when it is out of date. |
| `audit_ledger.prev_hash` | The previous row's hash | Tamper evidence: changing any row breaks every link after it. | `verify_ledger()` recomputes the chain. |

## Viva answers in one line each

- **Which normal form?** The core tables are in BCNF. Snapshots, results and caches are deliberately denormalized for reproducibility and speed.
- **Show a partial dependency you avoided.** `program.name` depends only on `program_id`, so it is not stored on `choice` (whose key is `(student_id, year, pref_order)`).
- **Show a table with two candidate keys.** `choice`: either `(student_id, year, pref_order)` or `(student_id, year, program_id)` identifies a row. Both are enforced (PRIMARY KEY and UNIQUE).
- **Where do you break 3NF, and why?** `spot_acceptance.year`, so a UNIQUE constraint can enforce one spot seat per student per year.
