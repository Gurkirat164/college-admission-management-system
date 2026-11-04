# College Admission Management System
### *The admission system you can audit*

**Team:** Arshdeep's team · **Course:** Advanced Database Management Systems · **Plan v1:** November 2026

> **Working assumptions (change these once confirmed):** PostgreSQL 16 · 4 team members · ~8 weeks.
> If the course requires Oracle or MySQL, see [Appendix B](#appendix-b--oracle-and-mysql-equivalents). Nearly every idea carries over.

---

## Contents

1. [The thesis](#1-the-thesis)
2. [What everyone else builds vs. what we build](#2-what-everyone-else-builds-vs-what-we-build)
3. [System overview](#3-system-overview)
4. [Data model](#4-data-model)
5. [Module 1: The allocation engine](#5-module-1--the-allocation-engine)
6. [Module 2: "Why didn't I get CSE?"](#6-module-2--why-didnt-i-get-cse)
7. [Module 3: Tamper-evident ledger and time travel](#7-module-3--tamper-evident-ledger-and-time-travel)
8. [Module 4: The last-seat race](#8-module-4--the-last-seat-race)
9. [**Module 5: What-if sandbox and chance predictor (deep dive)**](#9-module-5--what-if-sandbox-and-chance-predictor-deep-dive)
10. [Demo-day script](#10-demo-day-script)
11. [Timeline and team split](#11-timeline-and-team-split)
12. [Risks and how we handle them](#12-risks-and-how-we-handle-them)
13. [Appendix A: Synthetic data](#appendix-a--synthetic-data)
14. [Appendix B: Oracle and MySQL equivalents](#appendix-b--oracle-and-mysql-equivalents)

---

## 1. The thesis

Most "College Admission Management System" projects are CRUD apps: a student fills a form, an admin clicks approve, a dashboard shows counts. The database is just storage.

**Ours puts the database at the centre.** It allocates seats fairly, explains every decision, proves nobody tampered with the results, survives a stampede of simultaneous requests, and lets administrators safely ask "what if?" before they change anything.

Four promises, each backed by a module:

| Promise | What it means | Module |
|---|---|---|
| **Fair** | Seats are allocated by a provably stable matching algorithm with real Indian reservation rules | 1 |
| **Explainable** | Any student can ask why they didn't get a program and get a precise, data-backed answer | 2 |
| **Transparent** | Every change is hash-chained; history is queryable at any past moment | 3 |
| **Reliable** | Under heavy concurrent load, no seat is ever double-booked | 4 |
| **Foresighted** | Admins test policy changes without touching live data; students see realistic chances | 5 |

**One-line pitch for the viva:** *"Anyone can store admission data. Our database can prove its decisions were fair."*

---

## 2. What everyone else builds vs. what we build

| Typical project | Our project | ADBMS concepts shown |
|---|---|---|
| Admin approves/rejects forms | Multi-round counselling with stable matching and reservations | Stored procedures, set-based iteration, window functions |
| Status column says "Rejected" | Decision trace that explains every rejection | Data lineage, row-level security |
| `updated_at` column | Hash-chained audit ledger + bitemporal history | Triggers, cryptographic functions, range types, exclusion constraints |
| Works for one user at a time | Proven correct under 500 simultaneous requests | Isolation levels, row locks, MVCC, deadlock handling |
| Static reports | Transactional what-if simulation + statistical cutoff projection | Temp tables, subtransactions, recursive CTEs, materialized views, regression aggregates |

---

## 3. System overview

### 3.1 Actors

- **Student**: registers, uploads documents, fills a ranked list of program choices, responds after each round (Freeze / Float / Slide / Withdraw), asks "why not me?", checks chances.
- **Admission admin**: manages seat matrix, runs and publishes rounds, verifies the ledger.
- **Sandbox analyst** (may be the same person as admin, but a separate role): runs what-if scenarios. Cannot publish.
- **Auditor** (read-only): verifies the hash chain, runs time-travel queries.

### 3.2 Admission lifecycle

```
Registration ──► Document verification ──► Choice filling window ──► Choice lock
                                                │                          │
                                     (nightly mock allotment)              ▼
                                                                    Round 1 allocation
                                                                           │
                         ┌─────────────────────────────────────────────────┘
                         ▼
               Student responses: FREEZE / FLOAT / SLIDE / WITHDRAW
                         │
                         ▼
               Round 2 … Round N  ──►  Spot round (first-come vacancy filling)  ──►  Final admission
```

### 3.3 Architecture

```
┌──────────────────────────────┐
│  Web UI (student + admin)    │   thin: forms, tables, charts
└──────────────┬───────────────┘
               │ HTTPS / JSON
┌──────────────▼───────────────┐
│  API layer (FastAPI or Node) │   thin: auth, calls DB functions, no business logic
└──────────────┬───────────────┘
               │ SQL (calls functions/procedures)
┌──────────────▼──────────────────────────────────────────────────┐
│  PostgreSQL 16  ← the brain                                      │
│  • run_allocation()   • why_not()   • ledger triggers            │
│  • history triggers   • accept_spot_seat()   • mv_cutoff_trend   │
│  • RLS policies       • roles: student / admin / analyst / auditor│
└──────────────────────────────────────────────────────────────────┘
```

**Design rule:** business logic lives in the database. The API only authenticates and forwards. That way the database itself is what we're demonstrating, and the evaluator can see every rule in SQL.

---

## 4. Data model

Core tables (abbreviated; full DDL goes in `schema.sql`).

```sql
CREATE TYPE seat_cat AS ENUM ('OPEN', 'EWS', 'OBC_NCL', 'SC', 'ST');

CREATE TABLE student (
  student_id   bigserial PRIMARY KEY,
  full_name    text NOT NULL,
  dob          date NOT NULL,
  gender       char(1) CHECK (gender IN ('M','F','X')),
  category     seat_cat NOT NULL,
  is_pwd       boolean NOT NULL DEFAULT false,
  documents    jsonb NOT NULL DEFAULT '{}'      -- flexible, varies by board/state
);

CREATE TABLE exam_result (
  student_id   bigint PRIMARY KEY REFERENCES student,
  year         int NOT NULL,
  total_marks  numeric(6,2) NOT NULL,
  maths        numeric(5,2), physics numeric(5,2), chemistry numeric(5,2),
  crl_rank     int NOT NULL UNIQUE,             -- common rank list (tie-break already applied)
  cat_rank     int                               -- rank within own category
);

CREATE TABLE program (
  program_id   serial PRIMARY KEY,
  institute    text NOT NULL,
  code         text NOT NULL UNIQUE,            -- e.g. 'CSE', 'ECE'
  name         text NOT NULL
);

-- "Dense" seat matrix: one row for EVERY program × category, even when seats = 0.
-- This makes the sandbox (Module 5) trivial: changing seats is always an UPDATE, never an INSERT.
CREATE TABLE seat_matrix (
  year          int NOT NULL,
  program_id    int NOT NULL REFERENCES program,
  seat_category seat_cat NOT NULL,
  seats         int NOT NULL CHECK (seats >= 0),
  PRIMARY KEY (year, program_id, seat_category)
);

CREATE TABLE choice (
  student_id   bigint REFERENCES student,
  year         int NOT NULL,
  pref_order   smallint NOT NULL CHECK (pref_order > 0),
  program_id   int NOT NULL REFERENCES program,
  PRIMARY KEY (student_id, year, pref_order),
  UNIQUE (student_id, year, program_id)
);

CREATE TABLE counselling_round (
  round_id     serial PRIMARY KEY,
  year         int NOT NULL,
  round_no     smallint NOT NULL,
  status       text NOT NULL CHECK (status IN ('CHOICES_OPEN','LOCKED','PUBLISHED','CLOSED')),
  published_at timestamptz,
  UNIQUE (year, round_no)
);

CREATE TABLE allocation (
  round_id      int REFERENCES counselling_round,
  student_id    bigint REFERENCES student,
  program_id    int NOT NULL REFERENCES program,
  seat_category seat_cat NOT NULL,
  pref_order    smallint NOT NULL,
  rank_used     int NOT NULL,
  PRIMARY KEY (round_id, student_id)
);

CREATE TABLE allocation_trace (           -- powers Module 2
  round_id      int,
  student_id    bigint,
  pref_order    smallint,
  program_id    int,
  seat_category seat_cat,
  outcome       text CHECK (outcome IN ('ALLOTTED','REJECTED_FULL','NOT_REACHED')),
  closing_rank  int,                       -- last rank admitted to that seat pool
  PRIMARY KEY (round_id, student_id, pref_order, seat_category)
);

CREATE TABLE student_response (
  round_id     int, student_id bigint,
  decision     text CHECK (decision IN ('FREEZE','FLOAT','SLIDE','WITHDRAW')),
  responded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (round_id, student_id)
);

CREATE TABLE audit_ledger (               -- Module 3
  seq        bigserial PRIMARY KEY,
  at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  actor      text NOT NULL DEFAULT session_user,
  entity     text NOT NULL,
  op         text NOT NULL,
  payload    jsonb NOT NULL,
  prev_hash  bytea,
  hash       bytea NOT NULL
);

-- Module 5 tables are defined in section 9.
```

**ER summary:** `student 1—1 exam_result`, `student 1—N choice N—1 program`, `program 1—N seat_matrix`, `counselling_round 1—N allocation N—1 student`, `allocation_trace` is the explanation of `allocation`.

---

## 5. Module 1: The allocation engine

### 5.1 The idea

Use **student-proposing deferred acceptance** (Gale–Shapley):

1. Every unassigned student "proposes" to their next choice.
2. Every seat pool tentatively holds its best-ranked applicants up to capacity and rejects the rest.
3. Rejected students propose to their next choice. Repeat until nobody is rejected.

The result is **stable**: no student and seat pool would both prefer each other over what they got. It's also **strategy-proof** for students: listing your true preferences is always your best move. Both are viva gold.

### 5.2 Reservations: "virtual programs"

Each program is split into seat pools: `CSE-OPEN`, `CSE-OBC_NCL`, `CSE-SC`, and so on. A student's list is expanded so that for every program they try **OPEN first, then their own category**:

```
Diya (OBC_NCL) lists:  CSE, ECE
Expanded list:         CSE-OPEN, CSE-OBC_NCL, ECE-OPEN, ECE-OBC_NCL
```

This implements the real rule that a reserved-category student who makes it on open merit takes an OPEN seat and does not use up a reserved one. OPEN pools rank by `crl_rank`, category pools by `cat_rank`.

*Stretch:* PwD and female-supernumerary pools work the same way, as extra virtual pools.

### 5.3 Rounds

Before Round k+1, student responses filter the expanded lists:

- **FREEZE**: list truncated to exactly their current seat.
- **FLOAT**: list truncated at their current seat (can only move up).
- **SLIDE**: like FLOAT, but only programs at the same institute above the current one.
- **WITHDRAW**: removed.

The engine itself (section 9.5) is the same procedure for every round; only the input lists change.

---

## 6. Module 2: "Why didn't I get CSE?"

During allocation, the engine writes a trace row for every choice a student had above the seat they got. After the round:

```sql
CREATE FUNCTION why_not(p_round int, p_student bigint)
RETURNS TABLE (pref_order smallint, program text, seat_pool seat_cat,
               your_rank int, closing_rank int, verdict text)
LANGUAGE sql STABLE AS $$
  SELECT t.pref_order, p.code, t.seat_category,
         CASE WHEN t.seat_category = 'OPEN' THEN r.crl_rank ELSE r.cat_rank END,
         t.closing_rank,
         CASE t.outcome
           WHEN 'ALLOTTED'      THEN 'Allotted'
           WHEN 'REJECTED_FULL' THEN format('Full: last seat went to rank %s', t.closing_rank)
           ELSE 'Not reached: you were placed higher on your list'
         END
  FROM allocation_trace t
  JOIN program p     USING (program_id)
  JOIN exam_result r USING (student_id)
  WHERE t.round_id = p_round AND t.student_id = p_student
  ORDER BY t.pref_order, t.seat_category;
$$;
```

**Privacy:** row-level security so a student can only read their own trace.

```sql
ALTER TABLE allocation_trace ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_trace ON allocation_trace FOR SELECT TO student_role
  USING (student_id = current_setting('app.student_id')::bigint);
```

The UI turns the result into a sentence: *"Your OBC-NCL rank was 4,312. The last OBC-NCL seat in CSE went to rank 4,190. You were allotted ECE, your 2nd preference."*

---

## 7. Module 3: Tamper-evident ledger and time travel

### 7.1 Hash chain

Every insert/update/delete on `seat_matrix`, `allocation`, `exam_result` and `student_response` fires a trigger that appends to `audit_ledger`. Each entry's hash covers the previous entry's hash, so editing any old row breaks every hash after it.

```sql
CREATE FUNCTION ledger_append() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_prev bytea; v_payload jsonb;
BEGIN
  PERFORM pg_advisory_xact_lock(4242);   -- serialise appends so "previous hash" is unambiguous
  SELECT hash INTO v_prev FROM audit_ledger ORDER BY seq DESC LIMIT 1;
  v_payload := jsonb_build_object('old', to_jsonb(OLD), 'new', to_jsonb(NEW));
  INSERT INTO audit_ledger (entity, op, payload, prev_hash, hash)
  VALUES (TG_TABLE_NAME, TG_OP, v_payload, v_prev,
          sha256(coalesce(v_prev, '') || convert_to(TG_TABLE_NAME || TG_OP || v_payload::text, 'UTF8')));
  RETURN NULL;
END $$;
```

**Verification query:** recompute each hash with a window function (`LAG(hash) OVER (ORDER BY seq)`) and report the first `seq` where the stored hash doesn't match. Demo: an "insider" runs a raw `UPDATE audit_ledger SET payload = ...`, the verifier flags the exact row.

### 7.2 Time travel

History tables store every version of a row with a validity period:

```sql
CREATE EXTENSION btree_gist;
CREATE TABLE seat_matrix_history (
  LIKE seat_matrix,
  valid tstzrange NOT NULL,
  EXCLUDE USING gist (year WITH =, program_id WITH =, seat_category WITH =, valid WITH &&)
);
-- "What did the CSE seat matrix look like at 3 PM on Round 2 day?"
SELECT * FROM seat_matrix_history
WHERE program_id = 1 AND valid @> timestamptz '2026-07-02 15:00+05:30';
```

The exclusion constraint guarantees two versions of the same row can never overlap in time.

---

## 8. Module 4: The last-seat race

**Where it happens for real:** the spot round, where leftover vacant seats are offered first-come, first-served to eligible students.

### 8.1 The broken version (demo this first)

```sql
-- application code does "check, then insert" under READ COMMITTED
SELECT count(*) FROM spot_acceptance WHERE pool_id = 7;   -- everyone sees 0 of 1 taken
INSERT INTO spot_acceptance (pool_id, student_id) VALUES (7, :me);
```

Fire 500 concurrent requests with `pgbench -c 200 -j 8 -t 3 -f naive_accept.sql` and several students end up holding the same single seat.

### 8.2 Four lines of defence (demo the fix)

1. **Row lock:** `SELECT seats_left FROM spot_pool WHERE pool_id = 7 FOR UPDATE;` serialises contenders on that one row.
2. **Atomic conditional update** (the cleanest):
   ```sql
   UPDATE spot_pool SET seats_left = seats_left - 1
   WHERE pool_id = 7 AND seats_left > 0
   RETURNING pool_id;   -- zero rows returned = you lost the race
   ```
3. **SERIALIZABLE + retry loop** for the general case.
4. **`CHECK (seats_left >= 0)`**: even buggy code can't overbook; the database refuses.

Show the final count: exactly one winner, 499 clean "seat already taken" responses, zero deadlocks (or show one deadlock being detected and retried).

---

## 9. Module 5: What-if sandbox and chance predictor (deep dive)

This module has two halves:

- **5A: The admin what-if sandbox.** "What happens if we add 10 seats to CSE?" Run the real allocation engine on a hypothetical, measure the ripple effect, and leave live data untouched.
- **5B: The student chance predictor.** "With my rank, what are my chances at each program?" Statistical projection from past years, plus mock allotment from the same engine.

Both are powered by a single idea.

### 9.1 Core principle: *every run is a simulation*

We don't write a "real" allocator and a separate "simulator". There is **one** procedure, `run_allocation()`:

```
            ┌────────────── run_allocation(year, round, scenario, publish) ───────────────┐
 live data  │  1. SNAPSHOT  live tables ──► private temp tables (w_seats, w_choice, …)   │
 (read only)│  2. APPLY     scenario overrides to the temp tables                         │
            │  3. SOLVE     deferred acceptance on the temp tables                        │
            │  4. VERIFY    stability check (+ monotonicity check if seats only added)    │
            │  5. PERSIST   results into sim_run / sim_result                             │
            │  6. PUBLISH?  only if publish = true AND scenario is empty                  │
            └─────────────────────────────────────────────────────────────────────────────┘
```

**A live round is just a simulation with no changes that gets published.** This gives us:

- **No code duplication.** The sandbox can never drift from the real engine, because it *is* the real engine.
- **Every live round is reproducible.** Its sim run is stored next to every what-if, so you can diff them.
- **Safety by construction.** Steps 1–5 only *read* live tables. Only step 6 writes, and it refuses modified scenarios.

### 9.2 Three ways to build a sandbox (and why we pick the third)

This comparison is a strong viva section on its own. It shows we understand transactions rather than just using them.

#### Option A: `BEGIN … ROLLBACK` on live tables (the naive approach)

```sql
BEGIN;
UPDATE seat_matrix SET seats = seats + 10
 WHERE year = 2026 AND program_id = 1 AND seat_category = 'OPEN';
SELECT run_allocation(2026, 1);         -- engine sees the extra seats
SELECT * FROM sim_summary ORDER BY sim_id DESC LIMIT 1;   -- read results NOW
ROLLBACK;                                -- seats back to normal
```

| ✅ Good | ❌ Bad |
|---|---|
| Atomicity demo in 5 lines: change, observe, undo | The `UPDATE` holds a **row lock** on the CSE row until rollback. Anyone editing that seat row during a 5-second simulation waits |
| Others never see the change (no dirty reads in PostgreSQL) | `ROLLBACK` also deletes the simulation's results, so you must read everything before rolling back |
| | You can't keep scenarios to compare later |

**Verdict:** perfect as a 1-minute **teaching demo** in the viva ("here's the naive way and here's why it's wrong"). Not how we build it.

#### Option B: PL/pgSQL subtransaction trick

In PL/pgSQL, a `BEGIN … EXCEPTION … END` block runs as a **subtransaction** (an implicit savepoint). If an exception is caught, all database changes inside the block are undone, **but local variables keep their values.** So we can make changes, run the engine, copy results into a variable, then deliberately throw:

```sql
CREATE FUNCTION what_if_subtxn(p_scenario jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_summary jsonb;
BEGIN
  BEGIN                                            -- subtransaction starts
    UPDATE seat_matrix s SET seats = s.seats + (c->>'delta')::int
    FROM jsonb_array_elements(p_scenario->'seat_changes') c
    WHERE s.program_id = (c->>'program_id')::int
      AND s.seat_category = (c->>'seat_category')::seat_cat;

    PERFORM run_allocation(2026, 1);
    SELECT to_jsonb(x) INTO v_summary FROM sim_summary x ORDER BY sim_id DESC LIMIT 1;

    RAISE EXCEPTION USING ERRCODE = 'SB001', MESSAGE = 'sandbox rollback';
  EXCEPTION WHEN SQLSTATE 'SB001' THEN
    NULL;                                          -- every change above is undone
  END;                                             -- v_summary still holds the results
  RETURN v_summary;
END $$;
```

We use a **custom SQLSTATE (`SB001`)** so we only swallow our own deliberate rollback, never a genuine error from inside the engine.

**Verdict:** clever and very "advanced DBMS", and great to show in the report. But it still takes row locks on live tables during the run, and the summary is all that survives.

#### Option C: Private temp working tables ✅ (chosen)

The engine copies what it needs into **temporary tables**, which are private to the database session. Scenarios modify those copies, never live rows.

| Property | Why it holds |
|---|---|
| Never blocks live counselling | We only **read** live tables. Under MVCC, readers never block writers and writers never block readers |
| Five admins can simulate at once | Temp tables are per-session; same names, separate data, no collisions |
| Results are kept | Written to permanent `sim_run` / `sim_result` tables, so scenarios can be compared later |
| Consistent input | The whole snapshot is taken inside one `REPEATABLE READ` transaction (section 9.8) |

### 9.3 Sandbox tables

```sql
CREATE TABLE sim_run (
  sim_id       bigserial PRIMARY KEY,
  year         int NOT NULL,
  round_no     smallint NOT NULL,
  base_sim_id  bigint REFERENCES sim_run,     -- what this scenario is compared against
  label        text,
  scenario     jsonb NOT NULL DEFAULT '{}',
  run_by       text NOT NULL DEFAULT session_user,
  started_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
  duration_ms  int,
  is_published boolean NOT NULL DEFAULT false,
  checks       jsonb                          -- results of stability / monotonicity checks
);

CREATE TABLE sim_result (
  sim_id        bigint REFERENCES sim_run ON DELETE CASCADE,
  student_id    bigint NOT NULL,
  program_id    int NOT NULL,
  seat_category seat_cat NOT NULL,
  pref_order    smallint NOT NULL,   -- position of the PROGRAM in the student's list
  k             smallint NOT NULL,   -- position in the EXPANDED list (program × pool)
  rank_used     int NOT NULL,
  PRIMARY KEY (sim_id, student_id)
);

CREATE TABLE sim_diff (
  sim_id        bigint REFERENCES sim_run ON DELETE CASCADE,
  student_id    bigint,
  base_program  int, base_cat seat_cat, base_pref smallint, base_k smallint,
  sim_program   int, sim_cat  seat_cat, sim_pref  smallint, sim_k  smallint,
  change_type   text,
  PRIMARY KEY (sim_id, student_id)
);
```

### 9.4 Scenario format (JSONB)

A scenario is a small JSON document. It's stored with the run, so every result is reproducible and auditable.

```json
{
  "label": "Add 10 CSE open seats, withdraw Civil",
  "seat_changes": [
    { "program_id": 1, "seat_category": "OPEN", "delta": 10 },
    { "program_id": 2, "seat_category": "SC",   "delta": -1 }
  ],
  "withdraw_programs": [4],
  "withdrawal_rate": 0.05,
  "seed": "demo-2026"
}
```

| Field | Effect |
|---|---|
| `seat_changes` | Add or remove seats in any pool (deltas summed if a pool appears twice) |
| `withdraw_programs` | Program shut down: all its pools set to 0 |
| `withdrawal_rate` + `seed` | That fraction of students drop out, chosen deterministically (section 9.7) |
| *(stretch)* `tie_break` | Swap tie-break rules, e.g. maths-first vs. age-first |

### 9.5 The engine, step by step

```sql
CREATE OR REPLACE FUNCTION run_allocation(
  p_year      int,
  p_round_no  int,
  p_scenario  jsonb   DEFAULT '{}',
  p_publish   boolean DEFAULT false,
  p_base_sim  bigint  DEFAULT NULL
) RETURNS bigint                       -- the new sim_id
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp      -- pg_temp LAST: safe SECURITY DEFINER practice
AS $$
DECLARE
  v_sim_id bigint;
  v_t0     timestamptz := clock_timestamp();
  v_bad    int;
BEGIN
  -- ── Guardrails ──────────────────────────────────────────────────────────
  IF p_publish AND p_scenario <> '{}'::jsonb THEN
    RAISE EXCEPTION 'A modified scenario can never be published';
  END IF;
  IF p_publish AND NOT pg_has_role(session_user, 'admission_admin', 'MEMBER') THEN
    RAISE EXCEPTION 'Only admission_admin may publish';     -- session_user, not current_user,
  END IF;                                                    -- because SECURITY DEFINER changes current_user
  IF NOT pg_try_advisory_xact_lock(hashtext('sim:' || session_user)) THEN
    RAISE EXCEPTION 'You already have a simulation running';
  END IF;

  -- ── 1. SNAPSHOT into private temp tables ────────────────────────────────
  CREATE TEMP TABLE w_seats ON COMMIT DROP AS
    SELECT program_id, seat_category, seats
    FROM seat_matrix WHERE year = p_year;

  CREATE TEMP TABLE w_choice ON COMMIT DROP AS
    SELECT ch.student_id,
           ROW_NUMBER() OVER (PARTITION BY ch.student_id
                              ORDER BY ch.pref_order, e.pool_order)::smallint AS k,
           ch.pref_order, ch.program_id, e.seat_category,
           CASE WHEN e.seat_category = 'OPEN' THEN r.crl_rank ELSE r.cat_rank END AS rank_used
    FROM choice ch
    JOIN student st     USING (student_id)
    JOIN exam_result r  USING (student_id)
    CROSS JOIN LATERAL (VALUES ('OPEN'::seat_cat, 1), (st.category, 2)) e(seat_category, pool_order)
    WHERE ch.year = p_year
      AND (e.pool_order = 1 OR st.category <> 'OPEN');   -- OPEN students get one pool per program
    -- (round 2+: responses filter w_choice here: FREEZE / FLOAT / SLIDE / WITHDRAW, see 5.3)

  CREATE TEMP TABLE w_state ON COMMIT DROP AS
    SELECT DISTINCT student_id, 1::smallint AS next_k, 'FREE'::text AS status FROM w_choice;

  CREATE TEMP TABLE w_hold (
    student_id bigint PRIMARY KEY, program_id int, seat_category seat_cat,
    k smallint, rank_used int
  ) ON COMMIT DROP;

  CREATE UNIQUE INDEX ON w_choice (student_id, k);
  CREATE INDEX ON w_hold (program_id, seat_category, rank_used);
  ANALYZE w_seats; ANALYZE w_choice; ANALYZE w_state;   -- autovacuum never analyses temp tables!

  -- ── 2. APPLY the scenario to the copies ─────────────────────────────────
  UPDATE w_seats ws SET seats = GREATEST(0, ws.seats + d.delta)
  FROM (
    SELECT (x->>'program_id')::int AS program_id,
           (x->>'seat_category')::seat_cat AS seat_category,
           SUM((x->>'delta')::int) AS delta          -- aggregate first: UPDATE … FROM uses
    FROM jsonb_array_elements(COALESCE(p_scenario->'seat_changes', '[]')) x   -- only ONE matching row
    GROUP BY 1, 2
  ) d
  WHERE ws.program_id = d.program_id AND ws.seat_category = d.seat_category;

  UPDATE w_seats SET seats = 0
  WHERE program_id IN (SELECT jsonb_array_elements_text(
                              COALESCE(p_scenario->'withdraw_programs', '[]'))::int);

  IF p_scenario ? 'withdrawal_rate' THEN
    DELETE FROM w_state s
    WHERE ('x' || substr(md5(s.student_id::text || ':' || (p_scenario->>'seed')), 1, 7))::bit(28)::int
          < (p_scenario->>'withdrawal_rate')::numeric * 268435456;      -- 2^28
  END IF;

  -- ── 3. SOLVE ────────────────────────────────────────────────────────────
  CALL da_solve();

  -- ── 4. VERIFY: no blocking pairs (section 9.6.4) ────────────────────────
  SELECT count(*) INTO v_bad FROM stability_violations();
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'Engine bug: % blocking pairs found', v_bad;   -- whole run rolls back
  END IF;

  -- ── 5. PERSIST ──────────────────────────────────────────────────────────
  INSERT INTO sim_run (year, round_no, base_sim_id, label, scenario)
  VALUES (p_year, p_round_no, p_base_sim, p_scenario->>'label', p_scenario)
  RETURNING sim_id INTO v_sim_id;

  INSERT INTO sim_result
  SELECT v_sim_id, h.student_id, h.program_id, h.seat_category, c.pref_order, h.k, h.rank_used
  FROM w_hold h JOIN w_choice c ON c.student_id = h.student_id AND c.k = h.k;

  IF p_base_sim IS NOT NULL THEN
    PERFORM compute_diff(v_sim_id, p_base_sim);
  END IF;

  UPDATE sim_run SET duration_ms = (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int
  WHERE sim_id = v_sim_id;

  -- ── 6. PUBLISH (live rounds only) ──────────────────────────────────────
  IF p_publish THEN
    INSERT INTO allocation (round_id, student_id, program_id, seat_category, pref_order, rank_used)
    SELECT cr.round_id, r.student_id, r.program_id, r.seat_category, r.pref_order, r.rank_used
    FROM sim_result r
    JOIN counselling_round cr ON cr.year = p_year AND cr.round_no = p_round_no
    WHERE r.sim_id = v_sim_id;                     -- ledger trigger fires on these inserts
    UPDATE sim_run SET is_published = true WHERE sim_id = v_sim_id;
  END IF;

  RETURN v_sim_id;
END $$;
```

#### The solver: set-based deferred acceptance

The naive way loops student by student (slow, very "programming"). We do it **set-based**: every iteration, *all* free students propose at once, and *all* seat pools trim at once with a window function. A few dozen iterations finish even 20,000 students.

```sql
CREATE OR REPLACE PROCEDURE da_solve() LANGUAGE plpgsql AS $$
DECLARE v_rejected int;
BEGIN
  LOOP
    -- (1) all FREE students propose to their next choice
    WITH prop AS (
      INSERT INTO w_hold (student_id, program_id, seat_category, k, rank_used)
      SELECT c.student_id, c.program_id, c.seat_category, c.k, c.rank_used
      FROM w_state s
      JOIN w_choice c ON c.student_id = s.student_id AND c.k = s.next_k
      WHERE s.status = 'FREE'
      RETURNING student_id
    )
    UPDATE w_state s SET status = 'HELD' FROM prop p WHERE p.student_id = s.student_id;

    -- anyone still FREE had no next choice left
    UPDATE w_state SET status = 'EXHAUSTED' WHERE status = 'FREE';

    -- (2) every pool keeps its best `seats` holders, rejects the rest
    WITH ranked AS (
      SELECT h.student_id, h.k,
             ROW_NUMBER() OVER (PARTITION BY h.program_id, h.seat_category
                                ORDER BY h.rank_used, h.student_id) AS rn,
             COALESCE(ws.seats, 0) AS seats            -- LEFT JOIN: a pool with no row has 0 seats
      FROM w_hold h
      LEFT JOIN w_seats ws USING (program_id, seat_category)
    ), rejected AS (
      DELETE FROM w_hold h USING ranked r
      WHERE h.student_id = r.student_id AND r.rn > r.seats
      RETURNING h.student_id, h.k
    )
    UPDATE w_state s SET status = 'FREE', next_k = r.k + 1
    FROM rejected r WHERE r.student_id = s.student_id;
    GET DIAGNOSTICS v_rejected = ROW_COUNT;

    EXIT WHEN v_rejected = 0;          -- nobody rejected → matching is stable
  END LOOP;
END $$;
```

Concepts packed in here: **data-modifying CTEs** (`INSERT … RETURNING` feeding an `UPDATE` in one statement), **window functions** for capacity trimming, `GET DIAGNOSTICS` for loop control. (In the real build, the `rejected` CTE also inserts `REJECTED_FULL` rows into the trace table for Module 2.)

### 9.6 Measuring the impact

A simulation is only useful if it tells you *what changed*. Four outputs.

#### 9.6.1 Student-level diff

```sql
CREATE OR REPLACE FUNCTION compute_diff(p_sim bigint, p_base bigint) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO sim_diff
  SELECT p_sim,
         COALESCE(b.student_id, s.student_id),
         b.program_id, b.seat_category, b.pref_order, b.k,
         s.program_id, s.seat_category, s.pref_order, s.k,
         CASE
           WHEN b.student_id IS NULL                         THEN 'NEW_SEAT'
           WHEN s.student_id IS NULL                         THEN 'LOST_SEAT'
           WHEN b.program_id = s.program_id
            AND b.seat_category = s.seat_category            THEN 'UNCHANGED'
           WHEN b.program_id = s.program_id                  THEN 'POOL_SHIFT'   -- e.g. OBC → OPEN, same program
           WHEN s.pref_order < b.pref_order                  THEN 'UPGRADED'
           ELSE                                                   'DOWNGRADED'
         END
  FROM      (SELECT * FROM sim_result WHERE sim_id = p_base) b
  FULL JOIN (SELECT * FROM sim_result WHERE sim_id = p_sim)  s ON s.student_id = b.student_id;
$$;
```

The `FULL JOIN` is the key: students who gained or lost a seat appear on only one side.

**Admin summary card:**

```sql
SELECT change_type, count(*) FROM sim_diff
WHERE sim_id = :sim AND change_type <> 'UNCHANGED'
GROUP BY change_type ORDER BY count(*) DESC;
```

#### 9.6.2 Closing-rank shifts

The number admins actually care about: *how did cutoffs move?*

```sql
WITH closing AS (
  SELECT sim_id, program_id, seat_category, MAX(rank_used) AS closing_rank, COUNT(*) AS filled
  FROM sim_result WHERE sim_id IN (:base, :sim)
  GROUP BY 1, 2, 3
)
SELECT p.code, COALESCE(b.seat_category, s.seat_category) AS pool,
       b.closing_rank AS before, s.closing_rank AS after,
       s.closing_rank - b.closing_rank AS shift
FROM      (SELECT * FROM closing WHERE sim_id = :base) b
FULL JOIN (SELECT * FROM closing WHERE sim_id = :sim)  s USING (program_id, seat_category)
JOIN program p ON p.program_id = COALESCE(b.program_id, s.program_id)
WHERE b.closing_rank IS DISTINCT FROM s.closing_rank
ORDER BY abs(COALESCE(s.closing_rank - b.closing_rank, 0)) DESC;
```

`IS DISTINCT FROM` handles NULLs correctly (a pool that becomes empty or newly filled).

#### 9.6.3 The ripple chain (recursive CTE) ⭐

This is the most visually impressive output. Adding seats to CSE doesn't just help a few students: each student who moves *up* into CSE frees their old ECE seat, which pulls someone up from ME, which frees an ME seat… A **vacancy chain**.

```sql
WITH RECURSIVE moves AS (
  SELECT student_id,
         (base_program, base_cat) AS left_pool,
         (sim_program,  sim_cat)  AS joined_pool
  FROM sim_diff
  WHERE sim_id = :sim AND change_type IN ('UPGRADED','NEW_SEAT','POOL_SHIFT')
),
chain AS (
  -- seeds: students who moved INTO a pool the admin changed
  SELECT m.student_id, m.left_pool, m.joined_pool,
         1 AS depth, ARRAY[m.student_id] AS path
  FROM moves m
  WHERE m.joined_pool IN (
    SELECT ((x->>'program_id')::int, (x->>'seat_category')::seat_cat)
    FROM sim_run, jsonb_array_elements(scenario->'seat_changes') x
    WHERE sim_id = :sim
  )
  UNION ALL
  -- next link: someone who moved INTO the pool the previous student LEFT
  SELECT n.student_id, n.left_pool, n.joined_pool,
         c.depth + 1, c.path || n.student_id
  FROM chain c
  JOIN moves n ON n.joined_pool = c.left_pool
  WHERE NOT n.student_id = ANY (c.path)        -- cycle guard
    AND c.depth < 50                           -- safety cap
)
SELECT depth, student_id, left_pool, joined_pool, path
FROM chain ORDER BY path;
```

UI output: *"+1 CSE-OPEN seat → Kunal moves ECE→CSE → Tara moves ME→ECE → Dev gets ME (previously no seat). Ripple depth 3, 3 students helped."* The interactive page shows this live.

#### 9.6.4 Correctness checks built into every run

**Stability check.** A *blocking pair* is a student who prefers some pool to what they got, where that pool either has a free seat or holds someone ranked worse. Zero rows means the matching is stable. Run on every simulation; a non-zero count aborts the run.

```sql
CREATE OR REPLACE FUNCTION stability_violations()
RETURNS TABLE (student_id bigint, program_id int, seat_category seat_cat)
LANGUAGE sql AS $$
  SELECT c.student_id, c.program_id, c.seat_category
  FROM w_choice c
  LEFT JOIN w_hold mine ON mine.student_id = c.student_id
  JOIN w_seats ws ON ws.program_id = c.program_id AND ws.seat_category = c.seat_category
  JOIN w_state st ON st.student_id = c.student_id          -- skip withdrawn students
  WHERE c.k < COALESCE(mine.k, 32767)                      -- student prefers this pool
    AND (   (SELECT count(*) FROM w_hold h
              WHERE h.program_id = c.program_id AND h.seat_category = c.seat_category) < ws.seats
         OR EXISTS (SELECT 1 FROM w_hold h
                     WHERE h.program_id = c.program_id AND h.seat_category = c.seat_category
                       AND h.rank_used > c.rank_used));
$$;
```

**Monotonicity check: the engine testing itself.** A known result in matching theory: in student-proposing deferred acceptance, **adding capacity can never make any student worse off** (by their own expanded preference list). So for any scenario that only *adds* seats:

```sql
SELECT count(*) AS violations
FROM sim_diff
WHERE sim_id = :sim
  AND (change_type = 'LOST_SEAT' OR sim_k > base_k);   -- must be 0
```

We use this as a **property-based test**: generate 100 random add-only scenarios, run each, assert zero violations. If one ever appears, we've found a bug. Stored in `sim_run.checks` and shown as a green badge in the UI.

> **Viva nuance:** this holds for plain deferred acceptance over fixed pools. If we later add seat-conversion rules (e.g. unfilled PwD seats reverting to the parent pool), the theorem may not strictly hold, so a violation becomes "investigate", not automatically "bug". Knowing the limits of the theorem is what impresses.

### 9.7 Deterministic randomness

The withdrawal scenario needs "randomly pick 5% of students", but a simulation that gives different answers each time is useless for comparison. `random()` + `setseed()` isn't safe either, since row order can change between runs.

Instead, each student's "random" number is derived from a hash of their ID and the scenario seed:

```sql
('x' || substr(md5(student_id::text || ':' || seed), 1, 7))::bit(28)::int   -- 0 … 2^28-1
```

Same seed → same students withdraw, every time, regardless of row order or plan. Different seed → a different sample. That makes runs **reproducible and comparable**.

### 9.8 Isolation and concurrency

| Concern | Answer |
|---|---|
| Choices edited while snapshot is copied? | (1) Business rule: a trigger rejects `INSERT/UPDATE` on `choice` once the round is `LOCKED`. (2) The API runs every simulation as `BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT run_allocation(…); COMMIT;` so all snapshot statements see one consistent point in time. Under default READ COMMITTED, each statement gets a fresh snapshot, so the three `CREATE TEMP TABLE … AS SELECT` could disagree |
| Does a simulation slow live counselling? | No. It only reads live tables, and MVCC means readers take no row locks. The heavy work happens in session-private temp tables |
| Two admins simulate simultaneously? | Fine: separate sessions, separate temp tables. One admin spamming runs is stopped by `pg_try_advisory_xact_lock` |
| Simulation crashes halfway? | The whole function is one transaction, so nothing partial is persisted, and `ON COMMIT DROP` cleans up the temp tables |

### 9.9 Security and abuse prevention

A sandbox in admissions can be misused: someone could hunt for a seat tweak that benefits one particular student. Our answer comes from Module 3:

- **Every simulation is logged in the hash-chained ledger** (op `SIMULATE`, with scenario and summary). Nobody can quietly experiment.
- **Roles:** `sandbox_analyst` can call `run_allocation(…, publish => false)` only; `admission_admin` can publish; only an empty scenario can be published.
- **Privacy:** analysts see diffs through a view that masks names (`'Student #' || student_id`); only admins can unmask.
- **`SECURITY DEFINER` hardening:** fixed `search_path` with `pg_temp` last, and role checks use `session_user`.

### 9.10 Performance plan

| Item | Plan |
|---|---|
| Test size | 20,000 students, ~12 choices each → ~400k expanded rows; 30 programs × 5 pools |
| Target | Under ~5 seconds per simulation on a laptop (we measure and report the real number) |
| Indexes | `w_choice(student_id, k)` unique; `w_hold(program_id, seat_category, rank_used)` |
| Statistics | Manual `ANALYZE` on temp tables, since autovacuum can't see them (a detail most people miss) |
| Evidence | `EXPLAIN (ANALYZE, BUFFERS)` of the proposal and trimming steps in the report; iteration count and `duration_ms` per run |
| Growth | `sim_result` grows 20k rows per run → nightly purge of unpinned sims older than 7 days (`ON DELETE CASCADE` from `sim_run`). Stretch: partition `sim_result` by month so purge is a cheap `DROP PARTITION` |

### 9.11 Part 5B: The student chance predictor

#### Inputs

```sql
CREATE TABLE hist_closing (
  year          int,
  round_no      smallint,
  program_id    int,
  seat_category seat_cat,
  opening_rank  int,
  closing_rank  int,
  PRIMARY KEY (year, round_no, program_id, seat_category)
);
```

Filled with three past years of synthetic data (and, once live, our own published rounds).

#### Trend model as a materialized view

PostgreSQL has built-in **linear regression aggregates** (`regr_slope`, `regr_intercept`), so the projection runs entirely in SQL:

```sql
CREATE MATERIALIZED VIEW mv_cutoff_trend AS
WITH final_round AS (
  SELECT DISTINCT ON (year, program_id, seat_category)
         year, program_id, seat_category, closing_rank
  FROM hist_closing
  ORDER BY year, program_id, seat_category, round_no DESC     -- last round of each year
), target AS (SELECT MAX(year) + 1 AS y FROM hist_closing)
SELECT f.program_id, f.seat_category,
       COUNT(*)                         AS years_of_data,
       MIN(f.closing_rank)              AS toughest_close,     -- lowest = hardest year
       MAX(f.closing_rank)              AS easiest_close,
       ROUND(AVG(f.closing_rank))       AS avg_close,
       regr_slope(f.closing_rank, f.year) AS slope_per_year,
       ROUND(COALESCE(
         regr_intercept(f.closing_rank, f.year) + regr_slope(f.closing_rank, f.year) * t.y,
         AVG(f.closing_rank)))          AS projected_close
FROM final_round f CROSS JOIN target t
GROUP BY f.program_id, f.seat_category, t.y;

CREATE UNIQUE INDEX ON mv_cutoff_trend (program_id, seat_category);
-- the unique index is what allows non-blocking refreshes:
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_cutoff_trend;
```

**Round drift:** closing ranks usually relax between Round 1 and the final round as students withdraw. A second view computes the average drift per pool with `FIRST_VALUE(closing_rank) OVER (PARTITION BY year, program_id, seat_category ORDER BY round_no)`, so we can tell students *"CSE-OPEN typically relaxes ~6% after Round 1."*

#### Chance bands

Lower rank number = better.

```sql
CREATE FUNCTION chance_band(p_rank int, p_toughest int, p_projected int, p_easiest int)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_rank <= p_toughest * 0.90  THEN 'SAFE'       -- would have got in even in the hardest year
    WHEN p_rank <= p_projected        THEN 'LIKELY'
    WHEN p_rank <= p_easiest * 1.10   THEN 'REACH'
    ELSE                                   'UNLIKELY'
  END
$$;
```

For a reserved-category student we compute both the OPEN band (with `crl_rank`) and the category band (with `cat_rank`) and show the better one, mirroring how the engine expands their list.

#### Mock allotment: the bridge between 5A and 5B

While the choice-filling window is open, a scheduled job (pg_cron or the API's scheduler) runs `run_allocation(year, 0, '{"label":"mock"}')` every night with **current** choices. Students see: *"If allocation ran tonight, you'd get ECE (your 2nd choice)."* Real national counselling systems run mock allocation rounds for exactly this reason. Ours is free, because the sandbox engine already exists.

#### The preference-list advisor

Because deferred acceptance is **strategy-proof** for students, the advisor never tells anyone to reorder or "game" their list. It only warns:

- *"None of your choices are SAFE. Consider adding at least one."*
- *"You have only 3 choices. Longer lists can only help you."*

> **Viva nuance:** strategy-proofness strictly assumes students can list as many programs as they like. If the list length is capped, small strategic effects appear. Mention this; it shows depth.

### 9.12 Screens for Module 5

**Admin: Sandbox**

```
┌─ Scenario builder ───────────────┐ ┌─ Results: "Add 10 CSE open seats" ──────────────────┐
│ Base: Round 1 (published)        │ │ ⏱ 3.4 s   ✅ Stable   ✅ Monotonic (0 downgraded)   │
│                                  │ │                                                     │
│ CSE   OPEN  [ 60 ] (+10)  ▲ ▼    │ │  47 affected · 31 upgraded · 10 new seat · 6 shift  │
│ CSE   OBC   [ 16 ]        ▲ ▼    │ │                                                     │
│ ECE   OPEN  [ 50 ]        ▲ ▼    │ │ Closing ranks         before → after     shift      │
│ …                                │ │ CSE-OPEN               1,203 → 1,290      +87       │
│ ☐ Withdraw program: Civil        │ │ ECE-OPEN               2,410 → 2,466      +56       │
│ Withdrawal rate [ 0 % ] seed […] │ │                                                     │
│                                  │ │ Ripple chain (depth 6)  CSE ◄ ECE ◄ ME ◄ Civil …   │
│ [ Run simulation ]  [ Compare ]  │ │ Diff table  [filter: upgraded ▾]  [export CSV]      │
└──────────────────────────────────┘ └─────────────────────────────────────────────────────┘
   Live data untouched ✓   Logged to ledger as SIMULATE #1042 ✓
```

**Student: My chances**

| Choice | Pool | Projected close | Your rank | Band |
|---|---|---|---|---|
| 1. CSE | OBC_NCL | 4,050 | 4,312 | 🟠 Reach |
| 2. ECE | OBC_NCL | 6,900 | 4,312 | 🟢 Likely |
| 3. ME | OPEN | 9,800 | 11,840 | 🔴 Unlikely |

Plus: *"Mock allotment tonight: ECE (2nd choice)."*

### 9.13 Module 5 demo script (3 minutes)

1. **Baseline:** "Round 1 is published. Here's CSE-OPEN closing at rank 1,203."
2. **Naive approach (30 s):** run Option A in psql: `BEGIN; UPDATE …; ROLLBACK;`. Point out the row lock in `pg_locks` from a second terminal. "That's why we didn't build it this way."
3. **The real sandbox:** in the UI, add 10 CSE-OPEN seats → Run. Show time, badges, summary cards.
4. **Ripple chain:** click it. "Ten extra CSE seats helped 47 students across 5 programs."
5. **Safety proof:** in psql, `SELECT seats FROM seat_matrix WHERE …` → unchanged. Show the `SIMULATE` entry in the ledger.
6. **Withdraw Civil** → the downgraded/lost-seat cards light up, and the monotonicity badge correctly says "not applicable (seats removed)".
7. **Student side:** log in as a student, show chance bands and tonight's mock allotment.

### 9.14 ADBMS concepts covered by Module 5 alone

Transactions & atomicity · savepoints / subtransactions · isolation levels (READ COMMITTED vs REPEATABLE READ) · MVCC · row locks & `pg_locks` · advisory locks · temporary tables · `SECURITY DEFINER` & role-based access · data-modifying CTEs · window functions · recursive CTEs · `FULL OUTER JOIN` & `IS DISTINCT FROM` · JSONB processing · materialized views & concurrent refresh · regression aggregates · query planning (`EXPLAIN ANALYZE`, temp-table statistics) · partitioning (stretch).

### 9.15 Viva questions we should be ready for

| Question | Short answer |
|---|---|
| Why not just copy the whole database for simulation? | Too slow and stale. We copy only the ~3 tables the engine needs, into session-private temp tables, in milliseconds |
| How can a simulation run during live counselling without slowing it? | MVCC: we only read live tables, and readers never block writers. All writes go to temp tables |
| What if the seat matrix changes mid-simulation? | The whole snapshot runs under REPEATABLE READ, so it sees one consistent moment |
| Why are your results reproducible? | Unique ranks + deterministic tie-breaks + hash-based pseudo-randomness keyed by a stored seed |
| How do you know the engine is correct? | Every run is checked for blocking pairs (stability), and add-only scenarios are checked for monotonicity: a theorem used as a test |
| Couldn't an admin misuse the sandbox? | Every simulation is written to the hash-chained ledger. Only empty scenarios can be published |
| Why a materialized view for the predictor? | The trend calculation scans all history; students query it constantly. Precompute once per round, refresh concurrently |

---

## 10. Demo-day script

Roughly 12 minutes, ordered to build excitement:

| Time | Beat | Shows |
|---|---|---|
| 0:00 | The hook: *"Anyone can store admission data. Our database can prove its decisions were fair."* | Thesis |
| 0:30 | A student registers, fills choices; mock allotment appears | Flow, Module 5B |
| 2:00 | Admin publishes Round 1; engine runs; stability ✅ | Module 1 |
| 3:30 | Student asks "Why didn't I get CSE?" | Module 2 |
| 5:00 | What-if sandbox: +10 CSE seats, ripple chain | **Module 5A** |
| 7:00 | Insider edits the ledger; verifier catches the exact row. Time-travel query | Module 3 |
| 9:00 | Spot round: 500 concurrent requests, broken version overbooks, fixed version has one winner | Module 4 |
| 11:00 | Wrap-up: concept checklist, performance numbers | Report |

---

## 11. Timeline and team split

**Roles (4 people):**

| Role | Owns |
|---|---|
| **Engine lead** | Schema, synthetic data, Module 1, Module 2 trace |
| **Integrity lead** | Module 3 (ledger, history, time travel), Module 4 (concurrency, pgbench scripts) |
| **Analytics lead** | Module 5 (sandbox, diff, ripple, checks, predictor) |
| **App & demo lead** | API, UI, roles/RLS wiring, demo script, report assembly |

**8-week plan:**

| Week | Milestone |
|---|---|
| 1 | Final scope, ER diagram, `schema.sql`, synthetic data generator (Appendix A) |
| 2 | Deferred acceptance working on temp tables (single round, OPEN only) |
| 3 | Reservations (virtual pools), trace table, stability check · Ledger triggers start |
| 4 | Multi-round responses · Ledger verifier, history tables · Sandbox scenario + diff |
| 5 | Ripple chain, monotonicity test suite · Spot round + concurrency scripts · UI skeleton |
| 6 | Predictor MV, bands, mock allotment · Why-not-me UI · RLS and roles |
| 7 | Load testing, `EXPLAIN ANALYZE`, tuning, bug fixing |
| 8 | Report, slides, two full demo rehearsals |

**Minimum viable version (if time runs short):** Modules 1, 2, 4, plus 5A without the ripple chain. Still distinctive.

---

## 12. Risks and how we handle them

| Risk | Mitigation |
|---|---|
| Reservation logic gets complicated | Start with OPEN + one category; add others as extra pools later. The virtual-pool design makes this additive |
| Engine is slow | Set-based solver from day one; test at 20k students by week 3, not week 7 |
| Frontend eats all the time | Business logic stays in SQL; the UI is deliberately simple. A psql demo is a valid fallback for any module |
| "Is this real?" from the evaluator | Every claim is backed by a query they can watch run: stability check, ledger verify, pgbench count |
| Teammate drops out | Each module is independent; the Minimum viable version above still stands |

---

## Appendix A: Synthetic data

Generate everything in SQL so the dataset is reproducible:

```sql
INSERT INTO student (full_name, dob, gender, category)
SELECT 'Student ' || g,
       date '2007-01-01' + (g % 700),
       (ARRAY['M','F'])[1 + g % 2],
       (ARRAY['OPEN','OPEN','OPEN','OPEN','EWS','OBC_NCL','OBC_NCL','SC','ST']::seat_cat[])[1 + g % 9]
FROM generate_series(1, 20000) g;
```

- Marks drawn from a skewed distribution; `crl_rank` via `ROW_NUMBER() OVER (ORDER BY total_marks DESC, maths DESC, physics DESC, dob)`, which also implements the tie-break rule.
- `cat_rank` via the same window, `PARTITION BY category`.
- Choices: students prefer popular programs (CSE, ECE first) with noise, list length 5–15.
- Past three years of `hist_closing`: run the engine on three generated cohorts, which is more realistic than inventing numbers.

---

## Appendix B: Oracle and MySQL equivalents

| Feature | PostgreSQL (plan) | Oracle | MySQL 8 |
|---|---|---|---|
| Engine | PL/pgSQL | PL/SQL | Stored procedures |
| Private working tables | `TEMP … ON COMMIT DROP` | Global temporary tables | `CREATE TEMPORARY TABLE` |
| Keep a log after rollback | Exception-block trick | `PRAGMA AUTONOMOUS_TRANSACTION` (even cleaner) | Not available; log from the app |
| Time travel | History tables + `tstzrange` | **Flashback Query** `AS OF TIMESTAMP` (built in!) | History tables + triggers |
| Hashing | `sha256()` | `STANDARD_HASH()` | `SHA2()` |
| Row locks / skip locked | `FOR UPDATE [SKIP LOCKED]` | Same | Same (8.0+) |
| Window functions, recursive CTE | Yes | Yes | Yes (8.0+) |
| Materialized views | Yes, concurrent refresh | Yes, with fast refresh | No; emulate with table + event scheduler |
| Regression aggregates | `regr_slope` / `regr_intercept` | `REGR_SLOPE` / `REGR_INTERCEPT` | Compute from `SUM`s manually |
| Row-level security | `CREATE POLICY` | Virtual Private Database | Not available; use views |

**If we get a choice: PostgreSQL**, for the best balance of features and free tooling. Oracle is a strong second (Flashback and autonomous transactions are great showpieces). MySQL can do it, with more workarounds.
