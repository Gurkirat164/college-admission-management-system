-- Concept: row-level security (RLS), and why the app does not depend on it.
-- Run as the owner:  psql "$MIGRATION_DATABASE_URL" -f database/showcase/06_row_level_security.sql
-- Everything happens inside one transaction that is rolled back, so nothing is left behind.
--
-- Migration 0001 enables RLS on nine student-data tables with the policy
--   USING (student_id = <the student linked to app.user_id>).
-- PostgreSQL skips RLS for a table's owner and for superusers. The app never queries tables
-- directly: its login has no table privileges at all and reaches data only through SECURITY DEFINER
-- functions, which run as the owner and check the caller's role themselves (require_role).
-- So in normal operation the policies are a second line of defence, not the main one.
-- This script shows they do work for any role that is not the owner.

\set ON_ERROR_STOP on
BEGIN;

-- A throwaway role with read access to two tables, like a reporting login might have.
CREATE ROLE rls_demo_reader NOLOGIN;
GRANT USAGE ON SCHEMA admission TO rls_demo_reader;
GRANT SELECT ON admission.application, admission.app_user TO rls_demo_reader;
GRANT EXECUTE ON FUNCTION admission.current_app_user_id() TO rls_demo_reader;

-- Act as the student Diya Sharma, the way the API tags every transaction with the signed-in user.
SELECT set_config('app.user_id',
                  (SELECT user_id::text FROM admission.app_user WHERE email = 'diya@example.com'), true);

\echo 'As the owner (RLS bypassed): every application'
SELECT count(*) AS applications_visible FROM admission.application;

SET LOCAL ROLE rls_demo_reader;
\echo 'As a non-owner role tagged as Diya (RLS applied): only Diya''s own row'
SELECT student_id, year, status FROM admission.application;

RESET ROLE;
ROLLBACK;
