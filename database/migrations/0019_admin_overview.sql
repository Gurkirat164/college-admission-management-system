-- Admin overview: one read-only call for the Overview page.
-- Picks the allocation to show (published result, else the latest live baseline),
-- then returns every seat pool, who holds each seat, who is unplaced, and recent activity.
SET search_path = admission, pg_catalog, public;

CREATE FUNCTION admin_overview(p_year int) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, admission, pg_temp AS $$
DECLARE
  u        admission.app_user := admission.require_role('ADMIN');
  cycle    admission.admission_cycle;
  latest   admission.counselling_round;
  shown    admission.sim_run;
  snap     admission.sim_input_snapshot;
BEGIN
  SELECT * INTO cycle FROM admission.admission_cycle WHERE year = p_year;
  IF cycle.year IS NULL THEN
    RAISE EXCEPTION 'Admission cycle not found' USING ERRCODE = 'P0002';
  END IF;

  -- The round the cycle is currently in.
  SELECT * INTO latest
  FROM admission.counselling_round
  WHERE year = p_year
  ORDER BY round_no DESC
  LIMIT 1;

  -- 1. The published allocation of the current round, if any.
  IF latest.published_sim_id IS NOT NULL THEN
    SELECT * INTO shown FROM admission.sim_run WHERE sim_id = latest.published_sim_id;
  END IF;

  -- 2. Otherwise the newest live baseline for the current round
  --    (not a mock, no what-if scenario, not compared against another run).
  IF shown.sim_id IS NULL AND latest.round_id IS NOT NULL THEN
    SELECT * INTO shown
    FROM admission.sim_run
    WHERE round_id = latest.round_id
      AND NOT is_mock
      AND base_sim_id IS NULL
      AND (scenario - 'label') = '{}'::jsonb
    ORDER BY sim_id DESC
    LIMIT 1;
  END IF;

  IF shown.sim_id IS NOT NULL THEN
    SELECT * INTO snap FROM admission.sim_input_snapshot WHERE snapshot_id = shown.snapshot_id;
  END IF;

  RETURN jsonb_build_object(
    'year', p_year,
    'choice_deadline', cycle.choice_deadline,
    'choices_locked', cycle.choices_locked,
    'round', CASE WHEN latest.round_id IS NULL THEN NULL ELSE jsonb_build_object(
      'round_id', latest.round_id,
      'round_no', latest.round_no,
      'status', latest.status,
      'response_deadline', latest.response_deadline,
      'published_at', latest.published_at) END,

    -- Applicants by status and by category (GROUP BY, then folded into objects).
    'applicants', jsonb_build_object(
      'total', (SELECT count(*) FROM admission.application WHERE year = p_year),
      'by_status', coalesce((
        SELECT jsonb_object_agg(status, n)
        FROM (SELECT status, count(*) AS n FROM admission.application
              WHERE year = p_year GROUP BY status) s), '{}'::jsonb),
      'by_category', coalesce((
        SELECT jsonb_object_agg(admission_category, n)
        FROM (SELECT admission_category, count(*) AS n FROM admission.application
              WHERE year = p_year GROUP BY admission_category) c), '{}'::jsonb)),

    -- Which run the page shows, and whether choices changed after it ran.
    'run', CASE WHEN shown.sim_id IS NULL THEN NULL ELSE jsonb_build_object(
      'sim_id', shown.sim_id,
      'is_published', shown.is_published,
      'started_at', shown.started_at,
      'duration_ms', shown.duration_ms,
      'checks', shown.checks,
      'inputs_changed', snap.source_revision IS DISTINCT FROM cycle.input_revision) END,

    -- Every pool that has seats this year, in program order.
    'pools', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'program_id', p.program_id,
               'code', p.code,
               'institute', p.institute,
               'seat_category', m.seat_category,
               'seats', m.seats)
             ORDER BY p.program_id, m.seat_category)
      FROM admission.seat_matrix m
      JOIN admission.program p USING (program_id)
      WHERE m.year = p_year AND m.seats > 0), '[]'::jsonb),

    -- Who holds each seat in the shown run, with the ranks and choice that won it.
    'seats', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'program_id', r.program_id,
               'seat_category', r.seat_category,
               'student_id', r.student_id,
               'student_name', s.full_name,
               'admission_category', a.admission_category,
               'rank_used', r.rank_used,
               'crl_rank', e.crl_rank,
               'cat_rank', e.cat_rank,
               'pref_order', r.pref_order,
               'choice_count', (SELECT count(*) FROM admission.choice c
                                WHERE c.student_id = r.student_id AND c.year = p_year))
             ORDER BY r.program_id, r.seat_category, r.rank_used)
      FROM admission.sim_result r
      JOIN admission.student s USING (student_id)
      JOIN admission.application a ON a.student_id = r.student_id AND a.year = p_year
      LEFT JOIN admission.exam_result e ON e.student_id = r.student_id AND e.year = p_year
      WHERE r.sim_id = shown.sim_id), '[]'::jsonb),

    -- Applicants the shown run did not place, with the recorded reason.
    'unplaced', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'student_id', o.student_id,
               'student_name', s.full_name,
               'crl_rank', e.crl_rank,
               'outcome', o.outcome,
               'reason_code', o.reason_code)
             ORDER BY e.crl_rank NULLS LAST, o.student_id)
      FROM admission.sim_student_outcome o
      JOIN admission.student s USING (student_id)
      LEFT JOIN admission.exam_result e ON e.student_id = o.student_id AND e.year = p_year
      WHERE o.sim_id = shown.sim_id AND o.outcome <> 'ALLOTTED'), '[]'::jsonb),

    -- Demand: how many verified applicants put each program first, or anywhere, against its seats.
    'demand', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'program_id', p.program_id,
               'code', p.code,
               'institute', p.institute,
               'seats', coalesce(m.seats, 0),
               'first_choice', coalesce(d.first_choice, 0),
               'listed', coalesce(d.listed, 0))
             ORDER BY coalesce(d.first_choice, 0) DESC, p.program_id)
      FROM admission.program p
      LEFT JOIN (SELECT program_id, sum(seats) AS seats
                 FROM admission.seat_matrix WHERE year = p_year GROUP BY program_id) m
             ON m.program_id = p.program_id
      LEFT JOIN (SELECT c.program_id,
                        count(*) FILTER (WHERE c.pref_order = 1) AS first_choice,
                        count(*) AS listed
                 FROM admission.choice c
                 JOIN admission.application a
                   ON a.student_id = c.student_id AND a.year = c.year AND a.status = 'VERIFIED'
                 WHERE c.year = p_year
                 GROUP BY c.program_id) d
             ON d.program_id = p.program_id
      WHERE m.seats IS NOT NULL), '[]'::jsonb),

    -- Funnel: each stage counts applicants who reached it (conditional aggregation).
    'funnel', (
      SELECT jsonb_build_object(
               'applied', count(*),
               'submitted', count(*) FILTER (WHERE a.status <> 'DRAFT'),
               'verified', count(*) FILTER (WHERE a.status = 'VERIFIED'),
               'ranked', count(*) FILTER (WHERE a.status = 'VERIFIED' AND e.crl_rank IS NOT NULL),
               'chose', count(*) FILTER (WHERE a.status = 'VERIFIED' AND EXISTS (
                          SELECT 1 FROM admission.choice c
                          WHERE c.student_id = a.student_id AND c.year = a.year)))
      FROM admission.application a
      LEFT JOIN admission.exam_result e ON e.student_id = a.student_id AND e.year = a.year
      WHERE a.year = p_year),

    -- Solver timings for the latest live runs (oldest first), for the runs chart.
    'runs', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'sim_id', sim_id, 'duration_ms', duration_ms,
               'assigned', summary->'assigned', 'started_at', started_at)
             ORDER BY sim_id)
      FROM (SELECT r.*
            FROM admission.sim_run r
            JOIN admission.counselling_round cr USING (round_id)
            WHERE cr.year = p_year AND NOT r.is_mock
            ORDER BY r.sim_id DESC LIMIT 12) latest), '[]'::jsonb),

    -- Latest allocation runs and scheduled jobs, newest first.
    'recent', coalesce((
      SELECT jsonb_agg(item ORDER BY at DESC)
      FROM (
        (SELECT r.started_at AS at,
                jsonb_build_object('at', r.started_at, 'kind', 'run', 'label', r.label,
                                   'sim_id', r.sim_id, 'by', au.full_name,
                                   'assigned', r.summary->'assigned',
                                   'applicants', r.summary->'applicants',
                                   'passed', r.checks->>'stability' = 'PASS') AS item
         FROM admission.sim_run r
         JOIN admission.counselling_round cr USING (round_id)
         JOIN admission.app_user au ON au.user_id = r.run_by
         WHERE cr.year = p_year AND NOT r.is_mock
         ORDER BY r.sim_id DESC LIMIT 5)
        UNION ALL
        (SELECT coalesce(j.completed_at, j.started_at),
                jsonb_build_object('at', coalesce(j.completed_at, j.started_at), 'kind', 'job',
                                   'label', j.job_name, 'status', j.status, 'sim_id', j.sim_id)
         FROM admission.job_run j
         WHERE j.year = p_year
         ORDER BY j.job_id DESC LIMIT 5)
        ORDER BY at DESC LIMIT 5
      ) recent), '[]'::jsonb)
  );
END $$;

GRANT EXECUTE ON FUNCTION admin_overview(int) TO admission_app;
