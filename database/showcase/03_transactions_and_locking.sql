-- Concepts: transactions, row locks, atomic conditional updates, idempotency and advisory locks.
-- Reading copy, formatted and commented. The live definitions are in the migrations named below;
-- this file is for reading in the viva, not for running.
-- To watch the locking work under real concurrency, run:  npm run demo:race

------------------------------------------------------------------------------------------------
-- 1. Spot-round acceptance (migration 0005): many students click "Accept" on the last seat at once.
------------------------------------------------------------------------------------------------
CREATE FUNCTION accept_spot(p_pool bigint, p_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, admission, pg_temp AS $$
DECLARE
  u        admission.app_user := admission.require_role('STUDENT');  -- authorization inside the DB
  p        admission.spot_pool;
  a        admission.application;
  existing admission.spot_acceptance;
  n        bigint;
BEGIN
  IF length(p_key) NOT BETWEEN 8 AND 100 THEN RAISE EXCEPTION 'Invalid idempotency key'; END IF;
  SELECT * INTO p FROM admission.spot_pool WHERE pool_id = p_pool;
  IF p.pool_id IS NULL THEN RAISE EXCEPTION 'Spot pool not found'; END IF;

  -- Row lock on the student's own application: two tabs from the same student queue up here.
  SELECT * INTO a FROM admission.application
  WHERE year = p.year AND student_id = u.student_id
  FOR UPDATE;

  -- Idempotency: a retried request with the same key returns the first answer instead of
  -- accepting twice (double-click, flaky network).
  SELECT * INTO existing FROM admission.spot_acceptance
  WHERE student_id = u.student_id AND idempotency_key = p_key;
  IF existing.acceptance_id IS NOT NULL THEN
    IF existing.pool_id <> p_pool THEN RAISE EXCEPTION 'Idempotency key belongs to another pool'; END IF;
    RETURN jsonb_build_object('status', 'ACCEPTED', 'acceptance_id', existing.acceptance_id, 'replayed', true);
  END IF;

  IF a.status IS DISTINCT FROM 'VERIFIED' OR p.status <> 'OPEN' THEN
    RAISE EXCEPTION 'Applicant or spot pool is not eligible';
  END IF;
  IF p.seat_category <> 'OPEN' AND p.seat_category <> a.admission_category THEN
    RAISE EXCEPTION 'You are not eligible for this category pool';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM admission.exam_result r
                 JOIN admission.program_eligibility e ON e.year = r.year AND e.program_id = p.program_id
                 WHERE r.student_id = u.student_id AND r.year = p.year AND r.total_marks >= e.min_marks) THEN
    RAISE EXCEPTION 'Program eligibility check failed';
  END IF;
  IF EXISTS (SELECT 1 FROM admission.seat_holding WHERE year = p.year AND student_id = u.student_id) THEN
    RAISE EXCEPTION 'You already hold a seat';
  END IF;

  -- The key line. Read, check and decrement happen in ONE statement. PostgreSQL row-locks the
  -- pool row; a second transaction waits, then re-checks "seats_left > 0" against the committed
  -- value and updates zero rows. No "read 1, both write 0" lost update is possible.
  UPDATE admission.spot_pool SET seats_left = seats_left - 1
  WHERE pool_id = p_pool AND status = 'OPEN' AND seats_left > 0;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'SEAT_UNAVAILABLE'); END IF;

  -- Both inserts commit with the decrement or not at all (atomicity). UNIQUE(year, student_id)
  -- and the seat_holding primary key are a second guarantee of one seat per student.
  INSERT INTO admission.spot_acceptance(pool_id, student_id, year, idempotency_key)
  VALUES (p_pool, u.student_id, p.year, p_key)
  RETURNING acceptance_id INTO n;
  INSERT INTO admission.seat_holding VALUES (p.year, u.student_id, p.program_id, p.seat_category, 'SPOT', false);
  RETURN jsonb_build_object('status', 'ACCEPTED', 'acceptance_id', n, 'replayed', false);
END $$;

------------------------------------------------------------------------------------------------
-- 2. Publishing a round (migration 0015, inside run_allocation): two admins press Publish together.
------------------------------------------------------------------------------------------------
-- The API opens the transaction at REPEATABLE READ, so the whole run sees one consistent snapshot:
--
--   SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
--   SELECT admission.run_allocation(round_id, '{}', NULL, true, idempotency_key);
--
-- Inside, publication is serialized and checked before anything is written:
--
--   PERFORM pg_advisory_xact_lock(hashtextextended('publish:' || p_round, 0));  -- one publisher per round
--   SELECT * INTO cycle   FROM admission.admission_cycle   WHERE year = ...     FOR UPDATE;
--   SELECT * INTO v_round FROM admission.counselling_round WHERE round_id = ... FOR UPDATE;
--   IF v_round.published_sim_id IS NOT NULL THEN
--     IF v_round.publish_key = p_key THEN RETURN v_round.published_sim_id; END IF;  -- same click: idempotent
--     RAISE EXCEPTION 'This round has already been published';                     -- different click: refused
--   END IF;
--   IF v_round.status <> 'LOCKED' THEN RAISE EXCEPTION 'Lock the round before publishing'; END IF;
--
-- Then allocation rows, seat holdings, the round status, cutoffs and an audit event are written in
-- the same transaction: all of them commit together or none do.
--
-- If PostgreSQL aborts a transaction with a serialization failure (40001) or a deadlock (40P01),
-- backend/app/routes/workflows.py `call()` retries it up to three times with a random back-off.
