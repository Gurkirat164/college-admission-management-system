-- Concepts: BEFORE and AFTER row triggers: a guard, an audit log and a temporal history.
-- Run as the owner:  psql "$MIGRATION_DATABASE_URL" -f database/showcase/02_triggers.sql
-- Everything is rolled back.

\set ON_ERROR_STOP on
SET search_path = admission, pg_catalog;

\echo 'Triggers on the admission tables'
SELECT c.relname AS table_name, t.tgname AS trigger_name,
       CASE WHEN t.tgtype & 2 = 2 THEN 'BEFORE' ELSE 'AFTER' END AS timing,
       p.proname AS function_name
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_proc p ON p.oid = t.tgfoid
WHERE n.nspname = 'admission' AND NOT t.tgisinternal
ORDER BY c.relname, t.tgname;

BEGIN;

-- 1. AFTER triggers: one seat change writes an audit event and closes/opens a history period.
SELECT last_seq AS audit_events_before FROM audit_chain_head;
UPDATE seat_matrix SET seats = seats + 1 WHERE year = 2026 AND program_id = 1 AND seat_category = 'OPEN';

\echo 'audit_change(): the newest ledger event, hash-chained to the one before it'
SELECT seq, envelope->>'entity' AS entity, envelope->>'op' AS op,
       envelope->'payload'->'old'->>'seats' AS old_seats,
       envelope->'payload'->'new'->>'seats' AS new_seats,
       left(prev_hash, 12) AS prev_hash, left(hash, 12) AS hash
FROM audit_ledger ORDER BY seq DESC LIMIT 1;

\echo 'history_change(): the old capacity now has an end time, the new one starts'
SELECT seats, lower(valid) AS valid_from, upper(valid) AS valid_to
FROM seat_matrix_history
WHERE year = 2026 AND program_id = 1 AND seat_category = 'OPEN'
ORDER BY lower(valid) DESC LIMIT 2;

-- 2. BEFORE trigger: guard_choices() rejects any change to choices after the deadline.
UPDATE admission_cycle SET choice_deadline = now() - interval '1 minute' WHERE year = 2026;
DO $$ BEGIN
  DELETE FROM choice WHERE student_id = 1 AND year = 2026 AND pref_order = 5;
  RAISE NOTICE 'Choice changed after the deadline (unexpected)';
EXCEPTION WHEN raise_exception THEN
  RAISE NOTICE 'guard_choices() refused the change: %', SQLERRM;
END $$;

ROLLBACK;
