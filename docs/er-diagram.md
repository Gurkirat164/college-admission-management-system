# Entity relationships

```mermaid
erDiagram
    INSTITUTE ||--o{ PROGRAM : offers
    ADMISSION_CYCLE ||--o{ COUNSELLING_ROUND : contains
    ADMISSION_CYCLE ||--o{ SEAT_MATRIX : configures
    PROGRAM ||--o{ SEAT_MATRIX : has_pools
    STUDENT ||--o{ APPLICATION : submits
    STUDENT ||--o{ EXAM_RESULT : receives
    STUDENT ||--o| APP_USER : signs_in
    APP_USER ||--o{ USER_SESSION : owns
    APPLICATION ||--o{ APPLICATION_DOCUMENT : includes
    STUDENT ||--o{ CHOICE : ranks
    PROGRAM ||--o{ CHOICE : selected
    COUNSELLING_ROUND ||--o{ SIM_RUN : snapshots
    SIM_RUN ||--o{ SIM_RESULT : assigns
    SIM_RUN ||--o{ PROPOSAL_LOG : explains
    STUDENT ||--o{ CURRENT_HOLDING : holds_by_year
    CURRENT_HOLDING ||--o| FINAL_ADMISSION : confirms
    PROGRAM ||--o{ HIST_CLOSING : historical_cutoffs
    SIM_RUN |o--o{ JOB_RUN : produces
```

Annual application/exam/holding identity uses year and student. Program identity includes its institute; pools use program/year/category. Unique and foreign-key constraints enforce boundaries. Immutable snapshots make replay independent of live edits. Audit events/system-time seat history track changes; prediction materialized views are derived caches. Exact columns and types are in the generated data dictionary and schema.
