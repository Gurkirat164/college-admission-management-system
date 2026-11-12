-- Concepts: joins, GROUP BY / HAVING, FILTER, window functions, subqueries, CTEs, views,
-- temporal range queries and query plans. All read-only; safe to run on the demo database.
-- Run as the owner:  psql "$MIGRATION_DATABASE_URL" -f database/showcase/04_queries.sql

SET search_path = admission, pg_catalog;

\echo '1. Joins: who holds which seat in the latest live baseline'
WITH latest AS (
  SELECT max(sim_id) AS sim_id FROM sim_run WHERE label = 'Live baseline'
)
SELECT s.full_name, p.code || ' ' || p.institute AS program, r.seat_category, r.rank_used, r.pref_order
FROM sim_result r
JOIN latest l ON l.sim_id = r.sim_id
JOIN student s ON s.student_id = r.student_id
JOIN program p ON p.program_id = r.program_id
ORDER BY r.rank_used, s.full_name;

\echo '2. GROUP BY + HAVING: programs with more first-choice applicants than seats'
SELECT p.code, p.institute,
       count(*) FILTER (WHERE c.pref_order = 1) AS first_choice,
       (SELECT sum(seats) FROM seat_matrix m WHERE m.program_id = p.program_id AND m.year = 2026) AS seats
FROM choice c
JOIN program p USING (program_id)
WHERE c.year = 2026
GROUP BY p.program_id, p.code, p.institute
HAVING count(*) FILTER (WHERE c.pref_order = 1)
     > (SELECT sum(seats) FROM seat_matrix m WHERE m.program_id = p.program_id AND m.year = 2026);

\echo '3. Window functions: rank inside each category without collapsing rows'
SELECT s.full_name, a.admission_category, e.crl_rank,
       rank() OVER (PARTITION BY a.admission_category ORDER BY e.crl_rank) AS rank_in_category,
       count(*) OVER (PARTITION BY a.admission_category) AS category_size
FROM application a
JOIN exam_result e USING (student_id, year)
JOIN student s USING (student_id)
WHERE a.year = 2026
ORDER BY a.admission_category, e.crl_rank;

\echo '4. Correlated subquery: each placed student against the closing rank of their pool'
SELECT s.full_name, r.seat_category, r.rank_used,
       (SELECT max(r2.rank_used) FROM sim_result r2
        WHERE r2.sim_id = r.sim_id AND r2.program_id = r.program_id
          AND r2.seat_category = r.seat_category) AS pool_closing_rank
FROM sim_result r
JOIN student s USING (student_id)
WHERE r.sim_id = (SELECT max(sim_id) FROM sim_run WHERE label = 'Live baseline')
ORDER BY r.program_id, r.seat_category, r.rank_used;

\echo '5. Recursive CTE: walk the audit hash chain from the first event'
WITH RECURSIVE chain AS (
  SELECT seq, hash, prev_hash, 1 AS depth FROM audit_ledger WHERE seq = 1
  UNION ALL
  SELECT l.seq, l.hash, l.prev_hash, c.depth + 1
  FROM audit_ledger l JOIN chain c ON l.prev_hash = c.hash AND l.seq = c.seq + 1
)
SELECT count(*) AS linked_events, (SELECT count(*) FROM audit_ledger) AS total_events FROM chain;

\echo '6. Temporal query: CSE North Open capacity as it was at the start of the cycle'
SELECT seats, lower(valid) AS from_time, upper(valid) AS to_time
FROM seat_matrix_history
WHERE year = 2026 AND program_id = 1 AND seat_category = 'OPEN'
  AND valid @> (SELECT min(lower(valid)) FROM seat_matrix_history WHERE year = 2026);

\echo '7. View: allocation_trace joins published runs to their explanation rows'
SELECT count(*) AS published_trace_rows FROM allocation_trace;

\echo '8. Query plan: the composite index serves this pool lookup'
EXPLAIN (COSTS OFF)
SELECT student_id FROM allocation WHERE round_id = 1 AND program_id = 1 AND seat_category = 'OPEN'
ORDER BY rank_used;
