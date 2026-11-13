-- Concepts: primary keys, composite keys, UNIQUE, CHECK, FOREIGN KEY, ENUM domains, exclusion constraints.
-- Run as the owner:  psql "$MIGRATION_DATABASE_URL" -f database/showcase/01_keys_and_constraints.sql
-- Each block tries to break one rule and prints the database's refusal. Everything is rolled back.

\set ON_ERROR_STOP on
SET search_path = admission, pg_catalog;
BEGIN;

-- UNIQUE(year, crl_rank): two students cannot share a common rank in the same year.
DO $$ BEGIN
  UPDATE exam_result SET crl_rank = 1 WHERE student_id = 2 AND year = 2026;
  SET CONSTRAINTS ALL IMMEDIATE;  -- this UNIQUE is DEFERRABLE so rank imports can swap ranks mid-transaction
  RAISE NOTICE 'Duplicate rank was accepted (unexpected)';
EXCEPTION WHEN unique_violation THEN
  RAISE NOTICE 'UNIQUE    refused a duplicate common rank: %', SQLERRM;
END $$;

-- CHECK(total_marks BETWEEN 0 AND 300): out-of-range marks never reach the table.
DO $$ BEGIN
  UPDATE exam_result SET total_marks = 350 WHERE student_id = 1 AND year = 2026;
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE 'CHECK     refused 350 marks: %', SQLERRM;
END $$;

-- ENUM seat_cat: a category outside OPEN, EWS, OBC_NCL, SC, ST cannot even be typed.
DO $$ BEGIN
  PERFORM 'GENERAL'::seat_cat;
EXCEPTION WHEN invalid_text_representation THEN
  RAISE NOTICE 'ENUM      refused category GENERAL: %', SQLERRM;
END $$;

-- FOREIGN KEY: a choice must point at a real program.
DO $$ BEGIN
  INSERT INTO choice(student_id, year, pref_order, program_id) VALUES (1, 2026, 29, 999);
EXCEPTION WHEN foreign_key_violation THEN
  RAISE NOTICE 'FK        refused a choice of program 999: %', SQLERRM;
WHEN raise_exception THEN
  RAISE NOTICE 'TRIGGER   refused the choice first (choices locked): %', SQLERRM;
END $$;

-- Composite PRIMARY KEY (year, student_id): a student holds at most one seat per year.
DO $$ BEGIN
  INSERT INTO seat_holding(year, student_id, program_id, seat_category, source) VALUES (2026, 1, 1, 'OPEN', 'SPOT');
  INSERT INTO seat_holding(year, student_id, program_id, seat_category, source) VALUES (2026, 1, 2, 'OPEN', 'SPOT');
EXCEPTION WHEN unique_violation THEN
  RAISE NOTICE 'PK        refused a second seat for one student: %', SQLERRM;
END $$;

-- EXCLUDE USING gist: two history rows for the same pool cannot cover overlapping time.
DO $$ BEGIN
  INSERT INTO seat_matrix_history(year, program_id, seat_category, seats, valid)
  VALUES (2026, 1, 'OPEN', 9, tstzrange(now() - interval '1 day', NULL));
EXCEPTION WHEN exclusion_violation THEN
  RAISE NOTICE 'EXCLUDE   refused an overlapping history period: %', SQLERRM;
END $$;

ROLLBACK;
