# Database dictionary

Generated from the complete migrated PostgreSQL 16 schema. Migrations remain authoritative.


## admission_cycle

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| year | integer | NO |  |
| input_revision | bigint | NO | 0 |
| choices_locked | boolean | NO | false |
| choice_deadline | timestamp with time zone | NO |  |
| policy_version | text | NO | 'academic-fixed-pools-v1'::text |

## allocation

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| round_id | integer | NO |  |
| student_id | bigint | NO |  |
| program_id | integer | NO |  |
| seat_category | USER-DEFINED | NO |  |
| pref_order | integer | NO |  |
| k | integer | NO |  |
| rank_used | integer | NO |  |

## allocation_trace

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| round_id | integer | YES |  |
| sim_id | bigint | YES |  |
| student_id | bigint | YES |  |
| program_id | integer | YES |  |
| seat_category | USER-DEFINED | YES |  |
| pref_order | integer | YES |  |
| k | integer | YES |  |
| rank_used | integer | YES |  |
| closing_rank | integer | YES |  |
| outcome | text | YES |  |

## app_session

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| token_hash | text | NO |  |
| user_id | bigint | NO |  |
| csrf_hash | text | NO |  |
| expires_at | timestamp with time zone | NO |  |

## app_user

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| user_id | bigint | NO |  |
| email | text | NO |  |
| password_hash | text | NO |  |
| full_name | text | NO |  |
| role | text | NO |  |
| student_id | bigint | YES |  |
| enabled | boolean | NO | true |

## application

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| student_id | bigint | NO |  |
| year | integer | NO |  |
| admission_category | USER-DEFINED | NO | 'OPEN'::seat_cat |
| status | text | NO | 'DRAFT'::text |
| choices_locked_at | timestamp with time zone | YES |  |
| review_reason | text | YES |  |

## audit_chain_head

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| singleton | boolean | NO | true |
| last_seq | bigint | NO | 0 |
| last_hash | text | NO | repeat('0'::text, 64) |

## audit_ledger

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| seq | bigint | NO |  |
| envelope | jsonb | NO |  |
| prev_hash | text | NO |  |
| hash | text | NO |  |

## choice

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| student_id | bigint | NO |  |
| year | integer | NO |  |
| pref_order | smallint | NO |  |
| program_id | integer | NO |  |

## counselling_round

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| round_id | integer | NO |  |
| year | integer | NO |  |
| round_no | integer | NO |  |
| status | text | NO | 'CHOICES_OPEN'::text |
| response_deadline | timestamp with time zone | NO |  |
| published_at | timestamp with time zone | YES |  |
| published_sim_id | bigint | YES |  |
| publish_key | text | YES |  |

## document_submission

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| document_id | bigint | NO |  |
| student_id | bigint | YES |  |
| year | integer | YES |  |
| original_name | text | NO |  |
| storage_key | text | NO |  |
| mime_type | text | NO |  |
| checksum | text | NO |  |
| byte_count | integer | NO |  |
| status | text | NO | 'PENDING'::text |
| reason | text | YES |  |
| created_at | timestamp with time zone | NO | clock_timestamp() |

## exam_result

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| student_id | bigint | NO |  |
| year | integer | NO |  |
| total_marks | numeric | NO |  |
| crl_rank | integer | NO |  |
| cat_rank | integer | YES |  |
| maths | numeric | YES |  |
| physics | numeric | YES |  |
| chemistry | numeric | YES |  |

## final_admission

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| year | integer | NO |  |
| student_id | bigint | NO |  |
| confirmed_by | bigint | NO |  |
| confirmed_at | timestamp with time zone | NO | clock_timestamp() |

## hist_closing

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| year | integer | NO |  |
| program_id | integer | NO |  |
| seat_category | USER-DEFINED | NO |  |
| closing_rank | integer | NO |  |
| source | text | NO | 'synthetic'::text |
| round_no | integer | NO | 1 |
| opening_rank | integer | NO | 1 |

## job_run

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| job_id | bigint | NO |  |
| job_name | text | NO |  |
| year | integer | NO |  |
| slot | text | NO |  |
| status | text | NO |  |
| started_at | timestamp with time zone | NO | clock_timestamp() |
| completed_at | timestamp with time zone | YES |  |
| sim_id | bigint | YES |  |
| message | text | YES |  |

## login_attempt

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| ip_hash | text | NO |  |
| email_hash | text | NO |  |
| at | timestamp with time zone | NO | clock_timestamp() |

## prediction_state

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| year | integer | NO |  |
| refreshed_at | timestamp with time zone | YES |  |
| stale | boolean | NO | true |
| error | text | YES |  |
| rules_version | text | NO | 'historic-bands-v1'::text |

## program

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| program_id | integer | NO |  |
| institute | text | NO |  |
| code | text | NO |  |
| name | text | NO |  |

## program_eligibility

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| year | integer | NO |  |
| program_id | integer | NO |  |
| min_marks | numeric | NO | 0 |

## seat_holding

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| year | integer | NO |  |
| student_id | bigint | NO |  |
| program_id | integer | NO |  |
| seat_category | USER-DEFINED | NO |  |
| source | text | NO |  |
| final | boolean | NO | false |

## seat_matrix

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| year | integer | NO |  |
| program_id | integer | NO |  |
| seat_category | USER-DEFINED | NO |  |
| seats | integer | NO |  |

## seat_matrix_history

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| history_id | bigint | NO |  |
| year | integer | NO |  |
| program_id | integer | NO |  |
| seat_category | USER-DEFINED | NO |  |
| seats | integer | NO |  |
| valid | tstzrange | NO |  |

## sim_diff

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| sim_id | bigint | NO |  |
| student_id | bigint | NO |  |
| base_program | integer | YES |  |
| sim_program | integer | YES |  |
| base_category | USER-DEFINED | YES |  |
| sim_category | USER-DEFINED | YES |  |
| base_k | integer | YES |  |
| sim_k | integer | YES |  |
| change_type | text | NO |  |

## sim_input_snapshot

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| snapshot_id | bigint | NO |  |
| year | integer | NO |  |
| round_id | integer | NO |  |
| source_revision | bigint | NO |  |
| captured_at | timestamp with time zone | NO | clock_timestamp() |
| policy_version | text | NO |  |
| engine_version | text | NO | 'da-sql-v1'::text |
| payload | jsonb | NO |  |
| payload_hash | text | NO |  |

## sim_result

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| sim_id | bigint | NO |  |
| student_id | bigint | NO |  |
| program_id | integer | NO |  |
| seat_category | USER-DEFINED | NO |  |
| pref_order | integer | NO |  |
| k | integer | NO |  |
| rank_used | integer | NO |  |

## sim_run

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| sim_id | bigint | NO |  |
| round_id | integer | NO |  |
| snapshot_id | bigint | NO |  |
| base_sim_id | bigint | YES |  |
| run_by | bigint | NO |  |
| scenario | jsonb | NO |  |
| label | text | NO |  |
| started_at | timestamp with time zone | NO | clock_timestamp() |
| duration_ms | integer | NO | 0 |
| is_published | boolean | NO | false |
| checks | jsonb | NO | '{}'::jsonb |
| summary | jsonb | NO | '{}'::jsonb |
| is_mock | boolean | NO | false |
| pinned | boolean | NO | false |

## sim_student_outcome

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| sim_id | bigint | NO |  |
| student_id | bigint | NO |  |
| outcome | text | NO |  |
| reason_code | text | YES |  |

## sim_trace

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| sim_id | bigint | NO |  |
| student_id | bigint | NO |  |
| program_id | integer | YES |  |
| seat_category | USER-DEFINED | YES |  |
| pref_order | integer | NO |  |
| k | integer | NO |  |
| rank_used | integer | NO |  |
| closing_rank | integer | YES |  |
| outcome | text | NO |  |

## spot_acceptance

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| acceptance_id | bigint | NO |  |
| pool_id | bigint | NO |  |
| student_id | bigint | NO |  |
| year | integer | NO |  |
| idempotency_key | text | NO |  |
| accepted_at | timestamp with time zone | NO | clock_timestamp() |

## spot_pool

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| pool_id | bigint | NO |  |
| year | integer | YES |  |
| program_id | integer | YES |  |
| seat_category | USER-DEFINED | YES |  |
| initial_capacity | integer | NO |  |
| seats_left | integer | NO |  |
| status | text | NO | 'OPEN'::text |

## student

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| student_id | bigint | NO |  |
| full_name | text | NO |  |
| dob | date | YES |  |

## student_response

| Column | PostgreSQL type | Nullable | Default |
|---|---|---|---|
| round_id | integer | NO |  |
| student_id | bigint | NO |  |
| decision | text | NO |  |
| responded_at | timestamp with time zone | NO | clock_timestamp() |
| is_default | boolean | NO | false |

## Relational constraints

| Relation | Constraint | Definition |
|---|---|---|
| admission_cycle | admission_cycle_pkey | PRIMARY KEY (year) |
| admission_cycle | admission_cycle_year_check | CHECK (((year >= 2020) AND (year <= 2100))) |
| allocation | allocation_k_check | CHECK ((k > 0)) |
| allocation | allocation_pkey | PRIMARY KEY (round_id, student_id) |
| allocation | allocation_pref_order_check | CHECK ((pref_order > 0)) |
| allocation | allocation_program_id_fkey | FOREIGN KEY (program_id) REFERENCES program(program_id) |
| allocation | allocation_rank_used_check | CHECK ((rank_used > 0)) |
| allocation | allocation_round_id_fkey | FOREIGN KEY (round_id) REFERENCES counselling_round(round_id) |
| allocation | allocation_student_id_fkey | FOREIGN KEY (student_id) REFERENCES student(student_id) |
| app_session | app_session_pkey | PRIMARY KEY (token_hash) |
| app_session | app_session_user_id_fkey | FOREIGN KEY (user_id) REFERENCES app_user(user_id) |
| app_user | app_user_check | CHECK (((role = 'STUDENT'::text) = (student_id IS NOT NULL))) |
| app_user | app_user_email_check | CHECK ((email = lower(email))) |
| app_user | app_user_email_key | UNIQUE (email) |
| app_user | app_user_pkey | PRIMARY KEY (user_id) |
| app_user | app_user_role_check | CHECK ((role = ANY (ARRAY['STUDENT'::text, 'ADMIN'::text, 'ANALYST'::text, 'AUDITOR'::text]))) |
| app_user | app_user_student_id_fkey | FOREIGN KEY (student_id) REFERENCES student(student_id) |
| app_user | app_user_student_id_key | UNIQUE (student_id) |
| application | application_pkey | PRIMARY KEY (student_id, year) |
| application | application_status_check | CHECK ((status = ANY (ARRAY['DRAFT'::text, 'SUBMITTED'::text, 'VERIFIED'::text, 'REJECTED'::text, 'WITHDRAWN'::text]))) |
| application | application_student_id_fkey | FOREIGN KEY (student_id) REFERENCES student(student_id) |
| application | application_year_fkey | FOREIGN KEY (year) REFERENCES admission_cycle(year) |
| audit_chain_head | audit_chain_head_pkey | PRIMARY KEY (singleton) |
| audit_chain_head | audit_chain_head_singleton_check | CHECK (singleton) |
| audit_ledger | audit_ledger_pkey | PRIMARY KEY (seq) |
| choice | choice_pkey | PRIMARY KEY (student_id, year, pref_order) |
| choice | choice_pref_order_check | CHECK (((pref_order >= 1) AND (pref_order <= 30))) |
| choice | choice_program_id_fkey | FOREIGN KEY (program_id) REFERENCES program(program_id) |
| choice | choice_student_id_year_fkey | FOREIGN KEY (student_id, year) REFERENCES exam_result(student_id, year) |
| choice | choice_student_id_year_program_id_key | UNIQUE (student_id, year, program_id) |
| counselling_round | counselling_round_pkey | PRIMARY KEY (round_id) |
| counselling_round | counselling_round_published_sim_id_fkey | FOREIGN KEY (published_sim_id) REFERENCES sim_run(sim_id) |
| counselling_round | counselling_round_published_sim_id_key | UNIQUE (published_sim_id) |
| counselling_round | counselling_round_round_no_check | CHECK ((round_no > 0)) |
| counselling_round | counselling_round_status_check | CHECK ((status = ANY (ARRAY['CHOICES_OPEN'::text, 'LOCKED'::text, 'PUBLISHED'::text, 'CLOSED'::text]))) |
| counselling_round | counselling_round_year_fkey | FOREIGN KEY (year) REFERENCES admission_cycle(year) |
| counselling_round | counselling_round_year_round_no_key | UNIQUE (year, round_no) |
| document_submission | document_submission_byte_count_check | CHECK (((byte_count >= 1) AND (byte_count <= 5242880))) |
| document_submission | document_submission_pkey | PRIMARY KEY (document_id) |
| document_submission | document_submission_status_check | CHECK ((status = ANY (ARRAY['PENDING'::text, 'VERIFIED'::text, 'REJECTED'::text]))) |
| document_submission | document_submission_storage_key_key | UNIQUE (storage_key) |
| document_submission | document_submission_student_id_year_fkey | FOREIGN KEY (student_id, year) REFERENCES application(student_id, year) |
| exam_result | exam_result_cat_rank_check | CHECK ((cat_rank > 0)) |
| exam_result | exam_result_chemistry_check | CHECK (((chemistry >= (0)::numeric) AND (chemistry <= (100)::numeric))) |
| exam_result | exam_result_crl_rank_check | CHECK ((crl_rank > 0)) |
| exam_result | exam_result_maths_check | CHECK (((maths >= (0)::numeric) AND (maths <= (100)::numeric))) |
| exam_result | exam_result_physics_check | CHECK (((physics >= (0)::numeric) AND (physics <= (100)::numeric))) |
| exam_result | exam_result_pkey | PRIMARY KEY (student_id, year) |
| exam_result | exam_result_student_id_year_fkey | FOREIGN KEY (student_id, year) REFERENCES application(student_id, year) |
| exam_result | exam_result_total_marks_check | CHECK (((total_marks >= (0)::numeric) AND (total_marks <= (300)::numeric))) |
| exam_result | exam_result_year_crl_rank_key | UNIQUE (year, crl_rank) DEFERRABLE INITIALLY DEFERRED |
| exam_result | subject_marks_total | CHECK (((maths IS NULL) OR (physics IS NULL) OR (chemistry IS NULL) OR (total_marks = ((maths + physics) + chemistry)))) |
| final_admission | final_admission_confirmed_by_fkey | FOREIGN KEY (confirmed_by) REFERENCES app_user(user_id) |
| final_admission | final_admission_pkey | PRIMARY KEY (year, student_id) |
| final_admission | final_admission_year_student_id_fkey | FOREIGN KEY (year, student_id) REFERENCES seat_holding(year, student_id) |
| hist_closing | hist_closing_check | CHECK (((opening_rank > 0) AND (opening_rank <= closing_rank))) |
| hist_closing | hist_closing_closing_rank_check | CHECK ((closing_rank > 0)) |
| hist_closing | hist_closing_pkey | PRIMARY KEY (year, round_no, program_id, seat_category) |
| hist_closing | hist_closing_program_id_fkey | FOREIGN KEY (program_id) REFERENCES program(program_id) |
| hist_closing | hist_closing_round_no_check | CHECK ((round_no > 0)) |
| job_run | job_run_job_name_year_slot_key | UNIQUE (job_name, year, slot) |
| job_run | job_run_pkey | PRIMARY KEY (job_id) |
| job_run | job_run_sim_id_fkey | FOREIGN KEY (sim_id) REFERENCES sim_run(sim_id) ON DELETE SET NULL |
| job_run | job_run_status_check | CHECK ((status = ANY (ARRAY['RUNNING'::text, 'SUCCEEDED'::text, 'FAILED'::text, 'SKIPPED'::text]))) |
| job_run | job_run_year_fkey | FOREIGN KEY (year) REFERENCES admission_cycle(year) |
| prediction_state | prediction_state_pkey | PRIMARY KEY (year) |
| prediction_state | prediction_state_year_fkey | FOREIGN KEY (year) REFERENCES admission_cycle(year) |
| program | program_institute_code_key | UNIQUE (institute, code) |
| program | program_pkey | PRIMARY KEY (program_id) |
| program_eligibility | program_eligibility_min_marks_check | CHECK (((min_marks >= (0)::numeric) AND (min_marks <= (300)::numeric))) |
| program_eligibility | program_eligibility_pkey | PRIMARY KEY (year, program_id) |
| program_eligibility | program_eligibility_program_id_fkey | FOREIGN KEY (program_id) REFERENCES program(program_id) |
| program_eligibility | program_eligibility_year_fkey | FOREIGN KEY (year) REFERENCES admission_cycle(year) |
| seat_holding | seat_holding_pkey | PRIMARY KEY (year, student_id) |
| seat_holding | seat_holding_program_id_fkey | FOREIGN KEY (program_id) REFERENCES program(program_id) |
| seat_holding | seat_holding_source_check | CHECK ((source = ANY (ARRAY['ROUND'::text, 'SPOT'::text]))) |
| seat_holding | seat_holding_student_id_year_fkey | FOREIGN KEY (student_id, year) REFERENCES application(student_id, year) |
| seat_matrix | seat_matrix_pkey | PRIMARY KEY (year, program_id, seat_category) |
| seat_matrix | seat_matrix_program_id_fkey | FOREIGN KEY (program_id) REFERENCES program(program_id) |
| seat_matrix | seat_matrix_seats_check | CHECK (((seats >= 0) AND (seats <= 10000))) |
| seat_matrix | seat_matrix_year_fkey | FOREIGN KEY (year) REFERENCES admission_cycle(year) |
| seat_matrix_history | seat_matrix_history_pkey | PRIMARY KEY (history_id) |
| seat_matrix_history | seat_matrix_history_valid_check | CHECK ((NOT isempty(valid))) |
| seat_matrix_history | seat_matrix_history_year_program_id_seat_category_valid_excl | EXCLUDE USING gist (year WITH =, program_id WITH =, seat_category WITH =, valid WITH &&) |
| sim_diff | sim_diff_base_program_fkey | FOREIGN KEY (base_program) REFERENCES program(program_id) |
| sim_diff | sim_diff_change_type_check | CHECK ((change_type = ANY (ARRAY['UNCHANGED'::text, 'NEW_SEAT'::text, 'LOST_SEAT'::text, 'POOL_SHIFT'::text, 'UPGRADED'::text, 'DOWNGRADED'::text]))) |
| sim_diff | sim_diff_pkey | PRIMARY KEY (sim_id, student_id) |
| sim_diff | sim_diff_sim_id_fkey | FOREIGN KEY (sim_id) REFERENCES sim_run(sim_id) ON DELETE CASCADE |
| sim_diff | sim_diff_sim_program_fkey | FOREIGN KEY (sim_program) REFERENCES program(program_id) |
| sim_diff | sim_diff_student_id_fkey | FOREIGN KEY (student_id) REFERENCES student(student_id) |
| sim_input_snapshot | sim_input_snapshot_pkey | PRIMARY KEY (snapshot_id) |
| sim_input_snapshot | sim_input_snapshot_round_id_fkey | FOREIGN KEY (round_id) REFERENCES counselling_round(round_id) |
| sim_input_snapshot | sim_input_snapshot_year_fkey | FOREIGN KEY (year) REFERENCES admission_cycle(year) |
| sim_result | sim_result_pkey | PRIMARY KEY (sim_id, student_id) |
| sim_result | sim_result_program_id_fkey | FOREIGN KEY (program_id) REFERENCES program(program_id) |
| sim_result | sim_result_sim_id_fkey | FOREIGN KEY (sim_id) REFERENCES sim_run(sim_id) ON DELETE CASCADE |
| sim_result | sim_result_student_id_fkey | FOREIGN KEY (student_id) REFERENCES student(student_id) |
| sim_run | sim_run_base_sim_id_fkey | FOREIGN KEY (base_sim_id) REFERENCES sim_run(sim_id) |
| sim_run | sim_run_pkey | PRIMARY KEY (sim_id) |
| sim_run | sim_run_round_id_fkey | FOREIGN KEY (round_id) REFERENCES counselling_round(round_id) |
| sim_run | sim_run_run_by_fkey | FOREIGN KEY (run_by) REFERENCES app_user(user_id) |
| sim_run | sim_run_snapshot_id_fkey | FOREIGN KEY (snapshot_id) REFERENCES sim_input_snapshot(snapshot_id) |
| sim_student_outcome | sim_student_outcome_outcome_check | CHECK ((outcome = ANY (ARRAY['ALLOTTED'::text, 'UNASSIGNED'::text, 'WITHDRAWN'::text, 'EXCLUDED'::text]))) |
| sim_student_outcome | sim_student_outcome_pkey | PRIMARY KEY (sim_id, student_id) |
| sim_student_outcome | sim_student_outcome_sim_id_fkey | FOREIGN KEY (sim_id) REFERENCES sim_run(sim_id) ON DELETE CASCADE |
| sim_student_outcome | sim_student_outcome_student_id_fkey | FOREIGN KEY (student_id) REFERENCES student(student_id) |
| sim_trace | sim_trace_outcome_check | CHECK ((outcome = ANY (ARRAY['ALLOTTED'::text, 'REJECTED_FULL'::text, 'NOT_REACHED'::text, 'RETAINED'::text]))) |
| sim_trace | sim_trace_pkey | PRIMARY KEY (sim_id, student_id, k) |
| sim_trace | sim_trace_program_id_fkey | FOREIGN KEY (program_id) REFERENCES program(program_id) |
| sim_trace | sim_trace_sim_id_fkey | FOREIGN KEY (sim_id) REFERENCES sim_run(sim_id) ON DELETE CASCADE |
| sim_trace | sim_trace_student_id_fkey | FOREIGN KEY (student_id) REFERENCES student(student_id) |
| spot_acceptance | spot_acceptance_pkey | PRIMARY KEY (acceptance_id) |
| spot_acceptance | spot_acceptance_pool_id_fkey | FOREIGN KEY (pool_id) REFERENCES spot_pool(pool_id) |
| spot_acceptance | spot_acceptance_student_id_idempotency_key_key | UNIQUE (student_id, idempotency_key) |
| spot_acceptance | spot_acceptance_student_id_year_fkey | FOREIGN KEY (student_id, year) REFERENCES application(student_id, year) |
| spot_acceptance | spot_acceptance_year_student_id_key | UNIQUE (year, student_id) |
| spot_pool | spot_pool_check | CHECK (((seats_left >= 0) AND (seats_left <= initial_capacity))) |
| spot_pool | spot_pool_initial_capacity_check | CHECK ((initial_capacity >= 0)) |
| spot_pool | spot_pool_pkey | PRIMARY KEY (pool_id) |
| spot_pool | spot_pool_status_check | CHECK ((status = ANY (ARRAY['OPEN'::text, 'CLOSED'::text]))) |
| spot_pool | spot_pool_year_program_id_seat_category_fkey | FOREIGN KEY (year, program_id, seat_category) REFERENCES seat_matrix(year, program_id, seat_category) |
| spot_pool | spot_pool_year_program_id_seat_category_key | UNIQUE (year, program_id, seat_category) |
| student | student_full_name_check | CHECK (((length(full_name) >= 2) AND (length(full_name) <= 100))) |
| student | student_pkey | PRIMARY KEY (student_id) |
| student_response | student_response_decision_check | CHECK ((decision = ANY (ARRAY['FREEZE'::text, 'FLOAT'::text, 'SLIDE'::text, 'WITHDRAW'::text]))) |
| student_response | student_response_pkey | PRIMARY KEY (round_id, student_id) |
| student_response | student_response_round_id_student_id_fkey | FOREIGN KEY (round_id, student_id) REFERENCES allocation(round_id, student_id) |
