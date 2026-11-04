-- Complete input validation, preserve snapshot policy metadata, and make stability linear in choice count.
SET search_path=admission,pg_catalog,public;

CREATE OR REPLACE FUNCTION run_allocation(p_round int,p_scenario jsonb DEFAULT '{}',p_base bigint DEFAULT NULL,
                              p_publish boolean DEFAULT false,p_key text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE
 u admission.app_user:=admission.require_role('ADMIN','ANALYST');
 v_round admission.counselling_round; cycle admission.admission_cycle; base admission.sim_run;
 snapshot admission.sim_input_snapshot; payload jsonb; sid bigint; v_sim bigint;
 t0 timestamptz:=clock_timestamp(); changed int; iterations int:=0; bound int;
 violations int; stable_count int; mono text:='NOT_APPLICABLE'; item jsonb;
BEGIN
 IF jsonb_typeof(p_scenario) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Scenario must be a JSON object'; END IF;
 IF p_scenario ? 'label' AND jsonb_typeof(p_scenario->'label') IS DISTINCT FROM 'string' THEN RAISE EXCEPTION 'Scenario label must be text'; END IF;
 IF p_scenario ? 'seat_changes' AND jsonb_typeof(p_scenario->'seat_changes') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'seat_changes must be an array'; END IF;
 IF p_scenario ? 'withdraw_programs' AND jsonb_typeof(p_scenario->'withdraw_programs') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'withdraw_programs must be an array'; END IF;
 IF p_scenario ? 'withdrawal_rate' AND (jsonb_typeof(p_scenario->'withdrawal_rate') IS DISTINCT FROM 'number' OR jsonb_typeof(p_scenario->'seed') IS DISTINCT FROM 'string' OR length(coalesce(p_scenario->>'seed',''))=0) THEN RAISE EXCEPTION 'Withdrawal requires a numeric rate and a text seed'; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(coalesce(p_scenario->'seat_changes','[]')) LOOP
   IF jsonb_typeof(item) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Seat changes must be objects'; END IF;
   IF NOT item ?& ARRAY['program_id','seat_category','delta'] OR EXISTS(SELECT 1 FROM jsonb_object_keys(item) k WHERE k NOT IN('program_id','seat_category','delta')) THEN RAISE EXCEPTION 'A seat change needs program_id, seat_category and delta'; END IF;
 END LOOP;
 IF pg_column_size(p_scenario)>65536 OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_scenario) k WHERE k NOT IN ('label','seat_changes','withdraw_programs','withdrawal_rate','seed')) THEN RAISE EXCEPTION 'Unknown or oversized scenario'; END IF;
 IF p_publish AND (u.role<>'ADMIN' OR p_scenario<>'{}' OR p_base IS NOT NULL OR length(coalesce(p_key,''))<8) THEN RAISE EXCEPTION 'Publication requires an admin, fresh live inputs, an empty scenario and an idempotency key'; END IF;
 IF NOT pg_try_advisory_xact_lock(hashtextextended('simulation-user:'||u.user_id,0)) THEN RAISE EXCEPTION 'A simulation is already running for this account'; END IF;
 SELECT year INTO v_round.year FROM admission.counselling_round WHERE round_id=p_round;
 IF v_round.year IS NULL THEN RAISE EXCEPTION 'Round not found'; END IF;
 IF p_publish THEN
   PERFORM pg_advisory_xact_lock(hashtextextended('publish:'||p_round,0));
   SELECT * INTO cycle FROM admission.admission_cycle WHERE year=v_round.year FOR UPDATE;
   SELECT * INTO v_round FROM admission.counselling_round WHERE round_id=p_round FOR UPDATE;
   IF v_round.published_sim_id IS NOT NULL THEN
     IF v_round.publish_key=p_key THEN RETURN v_round.published_sim_id; END IF;
     RAISE EXCEPTION 'This round has already been published';
   END IF;
   IF v_round.status<>'LOCKED' THEN RAISE EXCEPTION 'Lock the round before publishing'; END IF;
   IF v_round.round_no>1 AND NOT EXISTS(SELECT 1 FROM admission.counselling_round WHERE year=v_round.year AND round_no=v_round.round_no-1 AND status='CLOSED') THEN RAISE EXCEPTION 'Close the previous round first'; END IF;
   IF EXISTS(SELECT 1 FROM admission.spot_pool WHERE year=v_round.year) THEN RAISE EXCEPTION 'Ordinary rounds cannot run after spot allocation opens'; END IF;
 ELSE
   SELECT * INTO v_round FROM admission.counselling_round WHERE round_id=p_round;
   SELECT * INTO cycle FROM admission.admission_cycle WHERE year=v_round.year;
 END IF;
 IF p_base IS NOT NULL THEN
   SELECT * INTO base FROM admission.sim_run WHERE sim_id=p_base;
   IF base.round_id IS DISTINCT FROM p_round THEN RAISE EXCEPTION 'Baseline must belong to this round'; END IF;
   SELECT * INTO snapshot FROM admission.sim_input_snapshot WHERE snapshot_id=base.snapshot_id;
   IF snapshot.engine_version<>'da-sql-v1' THEN RAISE EXCEPTION 'Incompatible baseline engine'; END IF;
   IF snapshot.payload_hash<>encode(sha256(convert_to(snapshot.payload::text,'UTF8')),'hex') THEN RAISE EXCEPTION 'Saved input snapshot failed its integrity check'; END IF;
   payload:=snapshot.payload; sid:=snapshot.snapshot_id;
 ELSE
   SELECT jsonb_build_object(
    'seats',coalesce((SELECT jsonb_agg(to_jsonb(m) ORDER BY program_id,seat_category) FROM admission.seat_matrix m WHERE year=v_round.year),'[]'::jsonb),
    'applicants',coalesce((SELECT jsonb_agg(to_jsonb(a)||jsonb_build_object('crl_rank',e.crl_rank,'cat_rank',e.cat_rank,'total_marks',e.total_marks) ORDER BY a.student_id) FROM admission.application a LEFT JOIN admission.exam_result e USING(student_id,year) WHERE a.year=v_round.year),'[]'::jsonb),
    'choices',coalesce((SELECT jsonb_agg(to_jsonb(c)||jsonb_build_object('institute',p.institute,'min_marks',e.min_marks) ORDER BY student_id,pref_order) FROM admission.choice c JOIN admission.program p USING(program_id) JOIN admission.program_eligibility e USING(year,program_id) WHERE c.year=v_round.year),'[]'::jsonb),
    'previous',coalesce((SELECT jsonb_agg(to_jsonb(a)||jsonb_build_object('decision',coalesce(s.decision,'FREEZE'),'institute',p.institute) ORDER BY a.student_id)
       FROM admission.allocation a JOIN admission.counselling_round pr USING(round_id) JOIN admission.program p USING(program_id)
       LEFT JOIN admission.student_response s USING(round_id,student_id) WHERE pr.year=v_round.year AND pr.round_no=v_round.round_no-1),'[]'::jsonb)
   ) INTO payload;
   payload:=payload||jsonb_build_object('metadata',jsonb_build_object('year',v_round.year,'round_no',v_round.round_no,'response_deadline',v_round.response_deadline,'choice_deadline',cycle.choice_deadline,'policy_version',cycle.policy_version,'engine_version','da-sql-v1'));
   INSERT INTO admission.sim_input_snapshot(year,round_id,source_revision,policy_version,payload,payload_hash)
     VALUES(v_round.year,p_round,cycle.input_revision,cycle.policy_version,payload,encode(sha256(convert_to(payload::text,'UTF8')),'hex'))
     RETURNING snapshot_id INTO sid;
 END IF;
 IF p_scenario ? 'seat_changes' AND jsonb_typeof(p_scenario->'seat_changes')<>'array' THEN RAISE EXCEPTION 'seat_changes must be an array'; END IF;
 IF p_scenario ? 'withdraw_programs' AND jsonb_typeof(p_scenario->'withdraw_programs')<>'array' THEN RAISE EXCEPTION 'withdraw_programs must be an array'; END IF;
 IF p_scenario ? 'withdrawal_rate' AND ((p_scenario->>'withdrawal_rate')::numeric NOT BETWEEN 0 AND 1 OR length(coalesce(p_scenario->>'seed',''))=0) THEN RAISE EXCEPTION 'Withdrawal rate requires a seed and a value between zero and one'; END IF;
 IF to_regclass('pg_temp.w_people') IS NOT NULL THEN RAISE EXCEPTION 'Use a dedicated transaction for each run'; END IF;

 CREATE TEMP TABLE w_seats ON COMMIT DROP AS SELECT program_id,seat_category,seats FROM jsonb_to_recordset(payload->'seats') AS x(program_id int,seat_category admission.seat_cat,seats int);
 CREATE TEMP TABLE w_previous ON COMMIT DROP AS SELECT * FROM jsonb_to_recordset(payload->'previous') AS x(student_id bigint,program_id int,seat_category admission.seat_cat,pref_order int,k int,rank_used int,decision text,institute text);
 CREATE TEMP TABLE w_people ON COMMIT DROP AS
  SELECT x.*,coalesce(p.decision,'NEW') AS decision,
    (x.status='VERIFIED' AND x.crl_rank IS NOT NULL AND coalesce(p.decision,'NEW')<>'WITHDRAW') AS active
  FROM jsonb_to_recordset(payload->'applicants') AS x(student_id bigint,status text,admission_category admission.seat_cat,crl_rank int,cat_rank int,total_marks numeric)
  LEFT JOIN w_previous p USING(student_id);
 IF EXISTS(SELECT 1 FROM w_people WHERE active AND admission_category<>'OPEN' AND cat_rank IS NULL) THEN RAISE EXCEPTION 'A verified reserved-category applicant is missing a category rank'; END IF;

 IF EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(p_scenario->'seat_changes','[]')) x
   WHERE jsonb_typeof(x->'delta') IS DISTINCT FROM 'number' OR (x->>'delta') !~ '^-?[0-9]+$'
      OR (SELECT count(*) FROM jsonb_object_keys(x))<>3
      OR NOT EXISTS(SELECT 1 FROM w_seats s WHERE s.program_id=(x->>'program_id')::int AND s.seat_category=(x->>'seat_category')::admission.seat_cat)) THEN RAISE EXCEPTION 'Each seat change needs an existing program/pool and an integer delta'; END IF;
 UPDATE w_seats s SET seats=s.seats+d.delta FROM
  (SELECT (x->>'program_id')::int AS program_id,(x->>'seat_category')::admission.seat_cat AS seat_category,sum((x->>'delta')::int)::int AS delta
   FROM jsonb_array_elements(coalesce(p_scenario->'seat_changes','[]')) x GROUP BY 1,2) d
  WHERE s.program_id=d.program_id AND s.seat_category=d.seat_category;
 IF EXISTS(SELECT 1 FROM w_seats WHERE seats<0 OR seats>10000) THEN RAISE EXCEPTION 'Scenario capacity must be between zero and 10000'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(coalesce(p_scenario->'withdraw_programs','[]')) p WHERE NOT EXISTS(SELECT 1 FROM w_seats WHERE program_id=p::int)) THEN RAISE EXCEPTION 'Unknown withdrawn program'; END IF;
 UPDATE w_seats SET seats=0 WHERE program_id IN(SELECT jsonb_array_elements_text(coalesce(p_scenario->'withdraw_programs','[]'))::int);
 IF p_scenario ? 'withdrawal_rate' THEN
   UPDATE w_people SET active=false WHERE ('x'||substr(md5(student_id::text||':'||(p_scenario->>'seed')),1,7))::bit(28)::int < (p_scenario->>'withdrawal_rate')::numeric*268435456;
 END IF;

 CREATE TEMP TABLE w_fixed ON COMMIT DROP AS SELECT p.* FROM w_previous p JOIN w_people s USING(student_id) WHERE s.active AND p.decision='FREEZE';
 UPDATE w_seats s SET seats=s.seats-f.n FROM(SELECT program_id,seat_category,count(*)::int n FROM w_fixed GROUP BY 1,2) f WHERE s.program_id=f.program_id AND s.seat_category=f.seat_category;
 IF EXISTS(SELECT 1 FROM w_seats WHERE seats<0) THEN RAISE EXCEPTION 'Scenario removes capacity already committed to frozen students'; END IF;
 CREATE TEMP TABLE w_choice ON COMMIT DROP AS
  SELECT c.student_id,c.program_id,c.pref_order,c.pref_order*2-2+e.pool_order AS k,e.seat_category,
    CASE WHEN e.seat_category='OPEN' THEN s.crl_rank ELSE s.cat_rank END AS rank_used
  FROM jsonb_to_recordset(payload->'choices') AS c(student_id bigint,program_id int,pref_order int,institute text,min_marks numeric)
  JOIN w_people s USING(student_id) LEFT JOIN w_previous p USING(student_id)
  CROSS JOIN LATERAL(VALUES('OPEN'::admission.seat_cat,1),(s.admission_category,2)) e(seat_category,pool_order)
  WHERE s.active AND s.decision<>'FREEZE' AND s.total_marks>=c.min_marks AND (e.pool_order=1 OR s.admission_category<>'OPEN')
   AND (p.student_id IS NULL OR (c.pref_order<p.pref_order AND (s.decision='FLOAT' OR (s.decision='SLIDE' AND c.institute=p.institute)))
        OR (c.program_id=p.program_id AND e.seat_category=p.seat_category));
 CREATE UNIQUE INDEX ON w_choice(student_id,k);
 CREATE TEMP TABLE w_state ON COMMIT DROP AS SELECT student_id,min(k) AS next_k,'FREE'::text AS status FROM w_choice GROUP BY student_id;
 CREATE TEMP TABLE w_hold(student_id bigint PRIMARY KEY,program_id int,seat_category admission.seat_cat,pref_order int,k int,rank_used int) ON COMMIT DROP;
 CREATE INDEX ON w_hold(program_id,seat_category,rank_used);
 ANALYZE w_choice; ANALYZE w_seats; ANALYZE w_state;
 SELECT count(*)+1 INTO bound FROM w_choice;
 LOOP
  iterations:=iterations+1;
  IF iterations>bound THEN RAISE EXCEPTION 'Solver exceeded its proposal bound'; END IF;
  WITH proposals AS(INSERT INTO w_hold SELECT c.student_id,c.program_id,c.seat_category,c.pref_order,c.k,c.rank_used FROM w_state s JOIN w_choice c ON c.student_id=s.student_id AND c.k=s.next_k WHERE s.status='FREE' RETURNING student_id)
  UPDATE w_state s SET status='HELD' FROM proposals p WHERE s.student_id=p.student_id;
  UPDATE w_state SET status='EXHAUSTED' WHERE status='FREE';
  WITH ranked AS(SELECT h.student_id,h.k,row_number() OVER(PARTITION BY h.program_id,h.seat_category ORDER BY h.rank_used,h.student_id) rn,coalesce(s.seats,0) seats FROM w_hold h LEFT JOIN w_seats s USING(program_id,seat_category)),
  rejected AS(DELETE FROM w_hold h USING ranked r WHERE h.student_id=r.student_id AND r.rn>r.seats RETURNING h.student_id,h.k)
  UPDATE w_state s SET status='FREE',next_k=(SELECT min(c.k) FROM w_choice c WHERE c.student_id=s.student_id AND c.k>r.k) FROM rejected r WHERE s.student_id=r.student_id;
  GET DIAGNOSTICS changed=ROW_COUNT;
  EXIT WHEN changed=0;
 END LOOP;

 CREATE TEMP TABLE w_pool_stats ON COMMIT DROP AS
 SELECT DISTINCT ON(program_id,seat_category) program_id,seat_category,
 count(*) OVER(PARTITION BY program_id,seat_category) held,rank_used worst_rank,student_id worst_student
 FROM w_hold ORDER BY program_id,seat_category,rank_used DESC,student_id DESC;
 SELECT count(*) INTO stable_count FROM w_choice c LEFT JOIN w_hold mine ON mine.student_id=c.student_id
 JOIN w_seats seats ON seats.program_id=c.program_id AND seats.seat_category=c.seat_category
 LEFT JOIN w_pool_stats stats ON stats.program_id=c.program_id AND stats.seat_category=c.seat_category
 WHERE c.k<coalesce(mine.k,2147483647) AND (coalesce(stats.held,0)<seats.seats OR (stats.worst_rank,stats.worst_student)>(c.rank_used,c.student_id));
 IF stable_count<>0 THEN RAISE EXCEPTION 'Stability check failed: % blocking pairs',stable_count; END IF;
 SELECT count(*) INTO violations FROM(SELECT program_id,seat_category,count(*) n FROM w_hold GROUP BY 1,2) h JOIN w_seats s USING(program_id,seat_category) WHERE h.n>s.seats;
 IF violations<>0 THEN RAISE EXCEPTION 'Capacity check failed'; END IF;
 IF p_publish AND EXISTS(SELECT 1 FROM w_previous p JOIN w_people s USING(student_id) LEFT JOIN w_hold h USING(student_id) LEFT JOIN w_fixed f USING(student_id)
   WHERE s.active AND f.student_id IS NULL AND (h.student_id IS NULL OR h.pref_order>p.pref_order)) THEN RAISE EXCEPTION 'Seat retention check failed'; END IF;

 INSERT INTO admission.sim_run(round_id,snapshot_id,base_sim_id,run_by,scenario,label)
 VALUES(p_round,sid,p_base,u.user_id,p_scenario,coalesce(nullif(left(p_scenario->>'label',100),''),CASE WHEN p_publish THEN 'Published allocation' WHEN p_base IS NULL THEN 'Live baseline' ELSE 'What-if scenario' END)) RETURNING sim_id INTO v_sim;
 INSERT INTO admission.sim_result SELECT v_sim,student_id,program_id,seat_category,pref_order,k,rank_used FROM w_hold;
 INSERT INTO admission.sim_result SELECT v_sim,student_id,program_id,seat_category,pref_order,k,rank_used FROM w_fixed;
 INSERT INTO admission.sim_student_outcome SELECT v_sim,p.student_id,CASE WHEN a.student_id IS NOT NULL THEN 'ALLOTTED' WHEN p.status<>'VERIFIED' THEN 'EXCLUDED' WHEN NOT p.active THEN 'WITHDRAWN' ELSE 'UNASSIGNED' END FROM w_people p LEFT JOIN admission.sim_result a ON a.sim_id=v_sim AND a.student_id=p.student_id;
 INSERT INTO admission.sim_trace
 SELECT v_sim,c.student_id,c.program_id,c.seat_category,c.pref_order,c.k,c.rank_used,cutoff.closing_rank,
   CASE WHEN h.k=c.k THEN 'ALLOTTED' WHEN h.k<c.k THEN 'NOT_REACHED' ELSE 'REJECTED_FULL' END
 FROM w_choice c LEFT JOIN w_hold h USING(student_id)
 LEFT JOIN(SELECT program_id,seat_category,max(rank_used) closing_rank FROM admission.sim_result WHERE sim_id=v_sim GROUP BY 1,2) cutoff ON cutoff.program_id=c.program_id AND cutoff.seat_category=c.seat_category;
 INSERT INTO admission.sim_trace SELECT v_sim,student_id,program_id,seat_category,pref_order,k,rank_used,rank_used,'RETAINED' FROM w_fixed;
 IF p_base IS NOT NULL THEN
   INSERT INTO admission.sim_diff
   SELECT v_sim,coalesce(b.student_id,s.student_id),b.program_id,s.program_id,b.seat_category,s.seat_category,b.k,s.k,
     CASE WHEN b.student_id IS NULL THEN 'NEW_SEAT' WHEN s.student_id IS NULL THEN 'LOST_SEAT'
       WHEN b.program_id=s.program_id AND b.seat_category=s.seat_category THEN 'UNCHANGED'
       WHEN b.program_id=s.program_id THEN 'POOL_SHIFT' WHEN s.k<b.k THEN 'UPGRADED' ELSE 'DOWNGRADED' END
   FROM(SELECT * FROM admission.sim_result WHERE sim_id=p_base) b FULL JOIN(SELECT * FROM admission.sim_result WHERE sim_id=v_sim) s USING(student_id);
   IF (base.scenario-'label')='{}' AND NOT (p_scenario ? 'withdraw_programs') AND NOT (p_scenario ? 'withdrawal_rate')
       AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(p_scenario->'seat_changes','[]')) x WHERE (x->>'delta')::int<0) THEN
     SELECT count(*) INTO violations FROM admission.sim_diff WHERE sim_id=v_sim AND(change_type='LOST_SEAT' OR sim_k>base_k);
     IF violations<>0 THEN RAISE EXCEPTION 'Add-only monotonicity check failed'; END IF;
     mono:='PASS';
   END IF;
 END IF;
 UPDATE admission.sim_run SET duration_ms=(extract(epoch FROM clock_timestamp()-t0)*1000)::int,
   checks=jsonb_build_object('stability','PASS','blocking_pairs',stable_count,'capacity','PASS','monotonicity',mono,'iterations',iterations),
   summary=jsonb_build_object('assigned',(SELECT count(*) FROM admission.sim_result WHERE sim_id=v_sim),'applicants',(SELECT count(*) FROM w_people),'changes',coalesce((SELECT jsonb_object_agg(change_type,n) FROM(SELECT change_type,count(*) n FROM admission.sim_diff WHERE sim_id=v_sim GROUP BY change_type) d),'{}'::jsonb))
 WHERE sim_id=v_sim;
 PERFORM admission.append_event('sim_run','SIMULATE',jsonb_build_object('sim_id',v_sim,'snapshot_id',sid,'scenario',p_scenario));
 IF p_publish THEN
   INSERT INTO admission.allocation SELECT p_round,student_id,program_id,seat_category,pref_order,k,rank_used FROM admission.sim_result WHERE sim_id=v_sim;
   DELETE FROM admission.seat_holding WHERE year=v_round.year;
   INSERT INTO admission.seat_holding(year,student_id,program_id,seat_category,source) SELECT v_round.year,student_id,program_id,seat_category,'ROUND' FROM admission.sim_result WHERE sim_id=v_sim;
   UPDATE admission.counselling_round SET status='PUBLISHED',published_at=clock_timestamp(),published_sim_id=v_sim,publish_key=p_key WHERE round_id=p_round;
   UPDATE admission.sim_run SET is_published=true,pinned=true WHERE sim_id=v_sim;
   INSERT INTO admission.hist_closing(year,round_no,program_id,seat_category,opening_rank,closing_rank,source)
   SELECT v_round.year,v_round.round_no,program_id,seat_category,min(rank_used),max(rank_used),'imported' FROM admission.sim_result WHERE sim_id=v_sim GROUP BY program_id,seat_category
   ON CONFLICT(year,round_no,program_id,seat_category) DO UPDATE SET opening_rank=excluded.opening_rank,closing_rank=excluded.closing_rank,source=excluded.source;
   INSERT INTO admission.prediction_state(year,stale) VALUES(v_round.year,true) ON CONFLICT(year) DO UPDATE SET stale=true;
   PERFORM admission.append_event('counselling_round','PUBLISH',jsonb_build_object('round_id',p_round,'sim_id',v_sim,'source_revision',cycle.input_revision));
 END IF;
 RETURN v_sim;
END $$;

