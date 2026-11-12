# Entity relationships

Generated from the migrated schema by `npm run docs:er` (`backend/app/er_diagram.py`). Do not edit by hand; change a migration and regenerate.

The `admission` schema has 31 tables. Each diagram covers one area; a table from another area appears by name only. Each relationship is drawn in the area of the table holding the foreign key. `PK` marks primary-key columns, `FK` foreign-key columns and `UK` columns in a unique constraint.

Relationship notation: `||--o{` one to many, `||--o|` one to zero-or-one. A composite key such as `(student_id, year)` gives one row per student per admission cycle.

## Identity and applications

Who applies, how they sign in, and what they submit for each annual cycle.

```mermaid
erDiagram
    app_user ||--o{ app_session : "user_id"
    student |o--o| app_user : "student_id"
    student ||--o{ application : "student_id"
    admission_cycle ||--o{ application : "year"
    application |o--o{ document_submission : "student_id, year"
    application ||--o| exam_result : "student_id, year"
    student {
        bigint student_id PK
        text full_name
        date dob
    }
    app_user {
        bigint user_id PK
        text email UK
        text password_hash
        text full_name
        text role
        bigint student_id FK,UK
        boolean enabled
    }
    app_session {
        text token_hash PK
        bigint user_id FK
        text csrf_hash
        timestamptz expires_at
    }
    login_attempt {
        text ip_hash
        text email_hash
        timestamptz at
        bigint attempt_id PK
    }
    admission_cycle {
        integer year PK
        bigint input_revision
        boolean choices_locked
        timestamptz choice_deadline
        text policy_version
    }
    application {
        bigint student_id PK,FK
        integer year PK,FK
        seat_cat admission_category
        text status
        timestamptz choices_locked_at
        text review_reason
    }
    exam_result {
        bigint student_id PK,FK
        integer year PK,FK,UK
        numeric total_marks
        integer crl_rank UK
        integer cat_rank
        numeric maths
        numeric physics
        numeric chemistry
    }
    document_submission {
        bigint document_id PK
        bigint student_id FK
        integer year FK
        text original_name
        text storage_key UK
        text mime_type
        text checksum
        integer byte_count
        text status
        text reason
        timestamptz created_at
    }
```

## Programs, seats and choices

What can be chosen, how many seats each pool has, and each ranked choice.

```mermaid
erDiagram
    program ||--o{ choice : "program_id"
    exam_result ||--o{ choice : "student_id, year"
    program ||--o{ hist_closing : "program_id"
    admission_cycle ||--o| prediction_state : "year"
    program ||--o{ program_eligibility : "program_id"
    admission_cycle ||--o{ program_eligibility : "year"
    program ||--o{ seat_matrix : "program_id"
    admission_cycle ||--o{ seat_matrix : "year"
    program {
        integer program_id PK
        text institute UK
        text code UK
        text name
    }
    program_eligibility {
        integer year PK,FK
        integer program_id PK,FK
        numeric min_marks
    }
    seat_matrix {
        integer year PK,FK
        integer program_id PK,FK
        seat_cat seat_category PK
        integer seats
    }
    choice {
        bigint student_id PK,FK,UK
        integer year PK,FK,UK
        smallint pref_order PK
        integer program_id FK,UK
    }
    hist_closing {
        integer year PK
        integer program_id PK,FK
        seat_cat seat_category PK
        integer closing_rank
        text source
        integer round_no PK
        integer opening_rank
    }
    prediction_state {
        integer year PK,FK
        timestamptz refreshed_at
        boolean stale
        text error
        text rules_version
    }
```

## Rounds and outcomes

Published rounds, student responses, the seat each student holds, and the spot round.

```mermaid
erDiagram
    program ||--o{ allocation : "program_id"
    counselling_round ||--o{ allocation : "round_id"
    student ||--o{ allocation : "student_id"
    sim_run |o--o| counselling_round : "published_sim_id"
    admission_cycle ||--o{ counselling_round : "year"
    app_user ||--o{ final_admission : "confirmed_by"
    seat_holding ||--o| final_admission : "year, student_id"
    program ||--o{ seat_holding : "program_id"
    application ||--o| seat_holding : "student_id, year"
    spot_pool ||--o{ spot_acceptance : "pool_id"
    application ||--o| spot_acceptance : "student_id, year"
    seat_matrix |o--o| spot_pool : "year, program_id, seat_category"
    allocation ||--o| student_response : "round_id, student_id"
    counselling_round {
        integer round_id PK
        integer year FK,UK
        integer round_no UK
        text status
        timestamptz response_deadline
        timestamptz published_at
        bigint published_sim_id FK,UK
        text publish_key
    }
    allocation {
        integer round_id PK,FK
        bigint student_id PK,FK
        integer program_id FK
        seat_cat seat_category
        integer pref_order
        integer k
        integer rank_used
    }
    student_response {
        integer round_id PK,FK
        bigint student_id PK,FK
        text decision
        timestamptz responded_at
        boolean is_default
    }
    seat_holding {
        integer year PK,FK
        bigint student_id PK,FK
        integer program_id FK
        seat_cat seat_category
        text source
        boolean final
    }
    final_admission {
        integer year PK,FK
        bigint student_id PK,FK
        bigint confirmed_by FK
        timestamptz confirmed_at
    }
    spot_pool {
        bigint pool_id PK
        integer year FK,UK
        integer program_id FK,UK
        seat_cat seat_category FK,UK
        integer initial_capacity
        integer seats_left
        text status
    }
    spot_acceptance {
        bigint acceptance_id PK
        bigint pool_id FK
        bigint student_id FK,UK
        integer year FK,UK
        text idempotency_key UK
        timestamptz accepted_at
    }
```

## Simulation and replay

Immutable input snapshots, every allocation run, its results and explanations.

```mermaid
erDiagram
    sim_run |o--o{ job_run : "sim_id"
    admission_cycle ||--o{ job_run : "year"
    program |o--o{ sim_diff : "base_program"
    sim_run ||--o{ sim_diff : "sim_id"
    program |o--o{ sim_diff : "sim_program"
    student ||--o{ sim_diff : "student_id"
    counselling_round ||--o{ sim_input_snapshot : "round_id"
    admission_cycle ||--o{ sim_input_snapshot : "year"
    program ||--o{ sim_result : "program_id"
    sim_run ||--o{ sim_result : "sim_id"
    student ||--o{ sim_result : "student_id"
    sim_run |o--o{ sim_run : "base_sim_id"
    counselling_round ||--o{ sim_run : "round_id"
    app_user ||--o{ sim_run : "run_by"
    sim_input_snapshot ||--o{ sim_run : "snapshot_id"
    sim_run ||--o{ sim_student_outcome : "sim_id"
    student ||--o{ sim_student_outcome : "student_id"
    program |o--o{ sim_trace : "program_id"
    sim_run ||--o{ sim_trace : "sim_id"
    student ||--o{ sim_trace : "student_id"
    sim_input_snapshot {
        bigint snapshot_id PK
        integer year FK
        integer round_id FK
        bigint source_revision
        timestamptz captured_at
        text policy_version
        text engine_version
        jsonb payload
        text payload_hash
    }
    sim_run {
        bigint sim_id PK
        integer round_id FK
        bigint snapshot_id FK
        bigint base_sim_id FK
        bigint run_by FK
        jsonb scenario
        text label
        timestamptz started_at
        integer duration_ms
        boolean is_published
        jsonb checks
        jsonb summary
        boolean is_mock
        boolean pinned
    }
    sim_result {
        bigint sim_id PK,FK
        bigint student_id PK,FK
        integer program_id FK
        seat_cat seat_category
        integer pref_order
        integer k
        integer rank_used
    }
    sim_student_outcome {
        bigint sim_id PK,FK
        bigint student_id PK,FK
        text outcome
        text reason_code
    }
    sim_trace {
        bigint sim_id PK,FK
        bigint student_id PK,FK
        integer program_id FK
        seat_cat seat_category
        integer pref_order
        integer k PK
        integer rank_used
        integer closing_rank
        text outcome
    }
    sim_diff {
        bigint sim_id PK,FK
        bigint student_id PK,FK
        integer base_program FK
        integer sim_program FK
        seat_cat base_category
        seat_cat sim_category
        integer base_k
        integer sim_k
        text change_type
    }
    job_run {
        bigint job_id PK
        text job_name UK
        integer year FK,UK
        text slot UK
        text status
        timestamptz started_at
        timestamptz completed_at
        bigint sim_id FK
        text message
    }
```

## Audit and history

The hash-chained event ledger and the system-time history of seat capacity.

```mermaid
erDiagram
    audit_ledger {
        bigint seq PK
        jsonb envelope
        text prev_hash
        text hash
    }
    audit_chain_head {
        boolean singleton PK
        bigint last_seq
        text last_hash
    }
    seat_matrix_history {
        bigint history_id PK
        integer year
        integer program_id
        seat_cat seat_category
        integer seats
        tstzrange valid
    }
```
