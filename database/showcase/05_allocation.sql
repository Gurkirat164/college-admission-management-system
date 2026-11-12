-- Concept: the allocation algorithm (deferred acceptance) written as set-based SQL.
-- Reading copy of the core of run_allocation(), formatted and commented. The live function is in
-- migration 0015 (migrations 0004, 0007, 0009, 0012 and 0014 hold its earlier versions). The
-- fragments below use the function's temporary tables, so this file is for reading, not running.
--
-- Idea: every unplaced student proposes to their next choice. Each seat pool keeps its best-ranked
-- proposers up to capacity and rejects the rest. Rejected students move to their next choice; a
-- kept student can still be displaced later by a better rank. Stop when nobody new is rejected.
-- The result is stable: no student and pool would both rather be matched with each other.

------------------------------------------------------------------------------------------------
-- Phase 1: freeze the inputs. Seats, applicants, choices and the previous round are copied into
-- one JSONB snapshot with a SHA-256, so the run can be replayed exactly later.
------------------------------------------------------------------------------------------------
INSERT INTO admission.sim_input_snapshot(year, round_id, source_revision, policy_version, payload, payload_hash)
VALUES (v_round.year, p_round, cycle.input_revision, cycle.policy_version, payload,
        encode(sha256(convert_to(payload::text, 'UTF8')), 'hex'));

------------------------------------------------------------------------------------------------
-- Phase 2: expand each ranked choice into proposals. Every program becomes up to two proposals:
-- the Open pool first (k odd), then the student's own category pool (k even), each with the rank
-- that pool uses. Ineligible choices (marks below the minimum) are dropped here. In later rounds the
-- live query also keeps FREEZE students out and limits FLOAT/SLIDE students to choices better than
-- their current seat (plus that seat as a fallback); that condition is left out here for clarity.
------------------------------------------------------------------------------------------------
CREATE TEMP TABLE w_choice ON COMMIT DROP AS
SELECT c.student_id, c.program_id, c.pref_order,
       c.pref_order * 2 - 2 + e.pool_order AS k,                 -- global proposal order
       e.seat_category,
       CASE WHEN e.seat_category = 'OPEN' THEN s.crl_rank ELSE s.cat_rank END AS rank_used
FROM jsonb_to_recordset(payload->'choices')
       AS c(student_id bigint, program_id int, pref_order int, institute text, min_marks numeric)
JOIN w_people s USING (student_id)
CROSS JOIN LATERAL (VALUES ('OPEN'::admission.seat_cat, 1), (s.admission_category, 2)) e(seat_category, pool_order)
WHERE s.active
  AND s.total_marks >= c.min_marks
  AND (e.pool_order = 1 OR s.admission_category <> 'OPEN');      -- Open applicants have one pool

-- Everyone starts free, pointing at their first proposal.
CREATE TEMP TABLE w_state ON COMMIT DROP AS
SELECT student_id, min(k) AS next_k, 'FREE'::text AS status FROM w_choice GROUP BY student_id;

------------------------------------------------------------------------------------------------
-- Phase 3: the proposal loop. One iteration = one round of proposals, processed as sets.
------------------------------------------------------------------------------------------------
LOOP
  iterations := iterations + 1;
  IF iterations > bound THEN RAISE EXCEPTION 'Solver exceeded its proposal bound'; END IF;

  -- Current holders plus every free student's next proposal, ranked inside each pool.
  TRUNCATE w_ranked;
  INSERT INTO w_ranked
  SELECT candidates.*,
         row_number() OVER (PARTITION BY candidates.program_id, candidates.seat_category
                            ORDER BY candidates.rank_used, candidates.student_id) AS rn,
         coalesce(seats.seats, 0) AS seats
  FROM (SELECT * FROM w_hold
        UNION ALL
        SELECT c.student_id, c.program_id, c.seat_category, c.pref_order, c.k, c.rank_used
        FROM w_state free
        JOIN w_choice c ON c.student_id = free.student_id AND c.k = free.next_k
        WHERE free.status = 'FREE') candidates
  LEFT JOIN w_seats seats
         ON seats.program_id = candidates.program_id AND seats.seat_category = candidates.seat_category;

  -- Each pool keeps its best `seats` candidates (deferred: they can still be displaced).
  TRUNCATE w_hold;
  INSERT INTO w_hold
  SELECT student_id, program_id, seat_category, pref_order, k, rank_used FROM w_ranked WHERE rn <= seats;

  -- Everyone else moves to their next proposal, if they have one left.
  TRUNCATE w_state;
  INSERT INTO w_state
  SELECT rejected.student_id, next.k, 'FREE'
  FROM w_ranked rejected
  CROSS JOIN LATERAL (SELECT min(c.k) AS k FROM w_choice c
                      WHERE c.student_id = rejected.student_id AND c.k > rejected.k) next
  WHERE rejected.rn > rejected.seats AND next.k IS NOT NULL;

  GET DIAGNOSTICS changed = ROW_COUNT;
  EXIT WHEN changed = 0;                                          -- nobody new was rejected
END LOOP;

------------------------------------------------------------------------------------------------
-- Phase 4: prove the result before saving it.
------------------------------------------------------------------------------------------------
-- Stability: count blocking pairs, i.e. a student who prefers pool X to their seat, while X has a
-- free seat or holds someone with a worse rank. Must be zero.
SELECT count(*) INTO stable_count
FROM w_choice c
LEFT JOIN w_hold mine ON mine.student_id = c.student_id
JOIN w_seats seats ON seats.program_id = c.program_id AND seats.seat_category = c.seat_category
LEFT JOIN w_pool_stats stats ON stats.program_id = c.program_id AND stats.seat_category = c.seat_category
WHERE c.k < coalesce(mine.k, 2147483647)
  AND (coalesce(stats.held, 0) < seats.seats
       OR (stats.worst_rank, stats.worst_student) > (c.rank_used, c.student_id));
IF stable_count <> 0 THEN RAISE EXCEPTION 'Stability check failed: % blocking pairs', stable_count; END IF;

-- Capacity: no pool holds more students than it has seats.
SELECT count(*) INTO violations
FROM (SELECT program_id, seat_category, count(*) AS n FROM w_hold GROUP BY 1, 2) h
JOIN w_seats s USING (program_id, seat_category)
WHERE h.n > s.seats;
IF violations <> 0 THEN RAISE EXCEPTION 'Capacity check failed'; END IF;

------------------------------------------------------------------------------------------------
-- Phase 5: persist the run (sim_run, sim_result, sim_trace) and, when publishing, write
-- allocation, seat_holding, the round status, cutoffs and an audit event in the same transaction.
-- See 03_transactions_and_locking.sql for how publication is serialized.
------------------------------------------------------------------------------------------------
