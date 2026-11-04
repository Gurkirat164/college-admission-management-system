SET search_path=admission,pg_catalog,public;

ALTER TABLE student ADD COLUMN dob date;
ALTER TABLE exam_result ADD COLUMN maths numeric CHECK(maths BETWEEN 0 AND 100);
ALTER TABLE exam_result ADD COLUMN physics numeric CHECK(physics BETWEEN 0 AND 100);
ALTER TABLE exam_result ADD COLUMN chemistry numeric CHECK(chemistry BETWEEN 0 AND 100);
ALTER TABLE exam_result DROP CONSTRAINT exam_result_year_crl_rank_key;
ALTER TABLE exam_result ADD CONSTRAINT exam_result_year_crl_rank_key UNIQUE(year,crl_rank) DEFERRABLE INITIALLY DEFERRED;
-- Only the supplied synthetic fixture receives synthetic subject marks.
UPDATE student SET dob=date '2007-01-01'+student_id::int WHERE student_id BETWEEN 1 AND 12 AND dob IS NULL;
UPDATE exam_result SET maths=round(total_marks/3,2),physics=round(total_marks/3,2),chemistry=total_marks-2*round(total_marks/3,2)
 WHERE student_id BETWEEN 1 AND 12 AND maths IS NULL;
ALTER TABLE hist_closing ADD COLUMN round_no int NOT NULL DEFAULT 1 CHECK(round_no>0);
ALTER TABLE hist_closing ADD COLUMN opening_rank int NOT NULL DEFAULT 1 CHECK(opening_rank>0 AND opening_rank<=closing_rank);
ALTER TABLE hist_closing DROP CONSTRAINT hist_closing_pkey;
ALTER TABLE hist_closing ADD PRIMARY KEY(year,round_no,program_id,seat_category);
ALTER TABLE sim_run ADD COLUMN is_mock boolean NOT NULL DEFAULT false;
ALTER TABLE sim_run ADD COLUMN pinned boolean NOT NULL DEFAULT false;
CREATE INDEX ON sim_run(started_at);
CREATE INDEX ON document_submission(student_id,year,status);
CREATE INDEX ON audit_ledger((envelope->>'entity'));
CREATE TABLE final_admission (
 year int,student_id bigint,confirmed_by bigint NOT NULL REFERENCES app_user,confirmed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(year,student_id),FOREIGN KEY(year,student_id) REFERENCES seat_holding
);
CREATE TABLE prediction_state (
 year int PRIMARY KEY REFERENCES admission_cycle,refreshed_at timestamptz,stale boolean NOT NULL DEFAULT true,error text,
 rules_version text NOT NULL DEFAULT 'historic-bands-v1'
);
INSERT INTO prediction_state(year) SELECT year FROM admission_cycle;
CREATE TABLE job_run (
 job_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,job_name text NOT NULL,year int NOT NULL REFERENCES admission_cycle,
 slot text NOT NULL,status text NOT NULL CHECK(status IN ('RUNNING','SUCCEEDED','FAILED','SKIPPED')),
 started_at timestamptz NOT NULL DEFAULT clock_timestamp(),completed_at timestamptz,sim_id bigint REFERENCES sim_run,message text,
 UNIQUE(job_name,year,slot)
);
CREATE TABLE login_attempt (
 ip_hash text NOT NULL,email_hash text NOT NULL,at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ON login_attempt(ip_hash,at);
CREATE INDEX ON login_attempt(email_hash,at);
CREATE FUNCTION record_login_attempt(p_ip text,p_email text) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('login:'||p_ip,0));
 DELETE FROM admission.login_attempt WHERE at<clock_timestamp()-interval '10 minutes';
 IF (SELECT count(*) FROM admission.login_attempt WHERE ip_hash=p_ip AND at>clock_timestamp()-interval '1 minute')>=30
 OR (SELECT count(*) FROM admission.login_attempt WHERE email_hash=p_email AND at>clock_timestamp()-interval '1 minute')>=10 THEN RETURN false; END IF;
 INSERT INTO admission.login_attempt(ip_hash,email_hash) VALUES(p_ip,p_email);RETURN true;
END $$;

CREATE FUNCTION import_exams(p_year int,p_rows jsonb,p_commit boolean,p_revision bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); cycle admission.admission_cycle; result jsonb;
BEGIN
 SELECT * INTO cycle FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 IF cycle.year IS NULL OR cycle.choices_locked THEN RAISE EXCEPTION 'Exam imports require an unlocked cycle'; END IF;
 IF p_commit AND p_revision IS DISTINCT FROM cycle.input_revision THEN RAISE EXCEPTION 'Records changed after preview. Preview the import again'; END IF;
 IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 50000 THEN RAISE EXCEPTION 'Provide 1 to 50000 exam rows'; END IF;
 CREATE TEMP TABLE import_rows ON COMMIT DROP AS SELECT * FROM jsonb_to_recordset(p_rows)
 AS r(student_id bigint,dob date,maths numeric,physics numeric,chemistry numeric,category admission.seat_cat);
 IF EXISTS(SELECT 1 FROM import_rows GROUP BY student_id HAVING count(*)>1) THEN RAISE EXCEPTION 'Duplicate student in exam import'; END IF;
 IF EXISTS(SELECT 1 FROM import_rows r LEFT JOIN admission.application a ON a.student_id=r.student_id AND a.year=p_year
   LEFT JOIN admission.student s ON s.student_id=r.student_id
   WHERE a.student_id IS NULL OR r.dob IS NULL OR r.dob NOT BETWEEN date '1900-01-01' AND make_date(p_year-10,1,1)
    OR (s.dob IS NOT NULL AND s.dob<>r.dob) OR r.maths IS NULL OR r.physics IS NULL OR r.chemistry IS NULL OR r.category IS NULL
    OR r.maths NOT BETWEEN 0 AND 100 OR r.physics NOT BETWEEN 0 AND 100 OR r.chemistry NOT BETWEEN 0 AND 100
    OR scale(r.maths)>2 OR scale(r.physics)>2 OR scale(r.chemistry)>2) THEN RAISE EXCEPTION 'Each row needs an existing annual applicant, consistent birth date and subject marks from 0 to 100 with at most two decimals'; END IF;
 CREATE TEMP TABLE ranked_import ON COMMIT DROP AS
 WITH candidates AS (
 SELECT e.student_id,s.dob,e.maths,e.physics,e.chemistry,a.admission_category category FROM admission.exam_result e
 JOIN admission.application a USING(student_id,year) JOIN admission.student s USING(student_id)
 WHERE e.year=p_year AND NOT EXISTS(SELECT 1 FROM import_rows i WHERE i.student_id=e.student_id)
 UNION ALL SELECT student_id,dob,maths,physics,chemistry,category FROM import_rows
 ) SELECT *,maths+physics+chemistry total_marks,
 row_number() OVER(ORDER BY maths+physics+chemistry DESC,maths DESC,physics DESC,dob,student_id)::int crl_rank,
 row_number() OVER(PARTITION BY category ORDER BY maths+physics+chemistry DESC,maths DESC,physics DESC,dob,student_id)::int cat_rank
 FROM candidates;
 IF EXISTS(SELECT 1 FROM ranked_import WHERE dob IS NULL OR maths IS NULL OR physics IS NULL OR chemistry IS NULL) THEN
   RAISE EXCEPTION 'Include raw marks and birth dates for every existing result before reranking the cohort'; END IF;
 SELECT jsonb_build_object('input_revision',cycle.input_revision,'payload_hash',encode(sha256(convert_to(p_rows::text,'UTF8')),'hex'),
   'imported_rows',(SELECT count(*) FROM import_rows),'cohort_size',count(*),'committed',p_commit,
   'results',coalesce(jsonb_agg(to_jsonb(r) ORDER BY crl_rank),'[]'::jsonb)) INTO result FROM ranked_import r;
 IF p_commit THEN
   UPDATE admission.student s SET dob=i.dob FROM import_rows i WHERE i.student_id=s.student_id;
   UPDATE admission.application a SET admission_category=i.category FROM import_rows i WHERE a.student_id=i.student_id AND a.year=p_year;
   INSERT INTO admission.exam_result(student_id,year,total_marks,crl_rank,cat_rank,maths,physics,chemistry)
   SELECT student_id,p_year,total_marks,crl_rank,CASE WHEN category='OPEN' THEN NULL ELSE cat_rank END,maths,physics,chemistry FROM ranked_import
   ON CONFLICT(student_id,year) DO UPDATE SET total_marks=excluded.total_marks,crl_rank=excluded.crl_rank,cat_rank=excluded.cat_rank,
    maths=excluded.maths,physics=excluded.physics,chemistry=excluded.chemistry;
   UPDATE admission.admission_cycle SET input_revision=input_revision+1 WHERE year=p_year;
   PERFORM admission.append_event('exam_result','IMPORT',jsonb_build_object('year',p_year,'rows',jsonb_array_length(p_rows),'hash',result->>'payload_hash'));
 END IF;
 RETURN result;
END $$;

DROP MATERIALIZED VIEW mv_cutoff_trend;
CREATE MATERIALIZED VIEW mv_cutoff_trend AS
WITH final AS(SELECT DISTINCT ON(year,program_id,seat_category) * FROM hist_closing ORDER BY year,program_id,seat_category,round_no DESC),
drift AS(SELECT year,program_id,seat_category,closing_rank,
 first_value(closing_rank) OVER(PARTITION BY year,program_id,seat_category ORDER BY round_no) first_close,
 row_number() OVER(PARTITION BY year,program_id,seat_category ORDER BY round_no DESC) n FROM hist_closing)
SELECT f.program_id,f.seat_category,count(*) years_of_data,min(f.closing_rank) toughest_close,max(f.closing_rank) easiest_close,
 greatest(1,least(2147483647,round(coalesce(regr_intercept(f.closing_rank,f.year)+regr_slope(f.closing_rank,f.year)*(max(f.year)+1),avg(f.closing_rank)))))::int projected_close,
 bool_and(f.source='synthetic') synthetic,
 (SELECT round(avg(100.0*(closing_rank-first_close)/nullif(first_close,0)),2) FROM drift d WHERE d.n=1 AND d.program_id=f.program_id AND d.seat_category=f.seat_category) drift_percent
FROM final f GROUP BY f.program_id,f.seat_category;
CREATE UNIQUE INDEX ON mv_cutoff_trend(program_id,seat_category);
CREATE FUNCTION refresh_predictions(p_year int) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 BEGIN
   REFRESH MATERIALIZED VIEW CONCURRENTLY admission.mv_cutoff_trend;
   INSERT INTO admission.prediction_state(year,refreshed_at,stale,error) VALUES(p_year,clock_timestamp(),false,NULL)
   ON CONFLICT(year) DO UPDATE SET refreshed_at=excluded.refreshed_at,stale=false,error=NULL;
 EXCEPTION WHEN OTHERS THEN
   INSERT INTO admission.prediction_state(year,stale,error) VALUES(p_year,true,'Prediction refresh failed; retry from administration')
   ON CONFLICT(year) DO UPDATE SET stale=true,error=excluded.error;
   RETURN jsonb_build_object('refreshed',false,'stale',true);
 END;
 RETURN jsonb_build_object('refreshed',true,'stale',false);
END $$;
CREATE FUNCTION import_history(p_rows jsonb) RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); n int;
BEGIN
 IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'Provide 1 to 10000 historical cutoff rows'; END IF;
 INSERT INTO admission.hist_closing(year,round_no,program_id,seat_category,opening_rank,closing_rank,source)
 SELECT year,round_no,program_id,seat_category,opening_rank,closing_rank,source FROM jsonb_to_recordset(p_rows)
 AS x(year int,round_no int,program_id int,seat_category admission.seat_cat,opening_rank int,closing_rank int,source text)
 WHERE year BETWEEN 2000 AND 2100 AND source IN ('synthetic','imported')
 ON CONFLICT(year,round_no,program_id,seat_category) DO UPDATE SET opening_rank=excluded.opening_rank,closing_rank=excluded.closing_rank,source=excluded.source;
 GET DIAGNOSTICS n=ROW_COUNT;
 IF n<>jsonb_array_length(p_rows) THEN RAISE EXCEPTION 'Every historical row needs a valid year and source'; END IF;
 UPDATE admission.prediction_state SET stale=true;
 PERFORM admission.append_event('hist_closing','IMPORT',jsonb_build_object('rows',n));RETURN n;
END $$;
CREATE FUNCTION predictor_dashboard(p_year int) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT'); latest admission.sim_run; revision bigint; bands jsonb;
BEGIN
 SELECT sr.* INTO latest FROM admission.sim_run sr JOIN admission.counselling_round cr USING(round_id) WHERE cr.year=p_year AND sr.is_mock ORDER BY sr.sim_id DESC LIMIT 1;
 SELECT input_revision INTO revision FROM admission.admission_cycle WHERE year=p_year;
 bands:=admission.my_chances(p_year);
 RETURN jsonb_build_object('bands',bands,'freshness',(SELECT to_jsonb(p) FROM admission.prediction_state p WHERE year=p_year),
  'round_drift',coalesce((SELECT jsonb_agg(jsonb_build_object('program_id',program_id,'seat_category',seat_category,'drift_percent',drift_percent)) FROM admission.mv_cutoff_trend),'[]'::jsonb),
  'choice_count',(SELECT count(*) FROM admission.choice WHERE year=p_year AND student_id=u.student_id),
  'has_safe_choice',EXISTS(SELECT 1 FROM jsonb_array_elements(bands) b JOIN admission.choice c ON c.program_id=(b->>'program_id')::int WHERE c.year=p_year AND c.student_id=u.student_id AND b->>'band'='SAFE'),
  'mock',CASE WHEN latest.sim_id IS NULL THEN NULL ELSE jsonb_build_object('sim_id',latest.sim_id,'captured_at',(SELECT captured_at FROM admission.sim_input_snapshot WHERE snapshot_id=latest.snapshot_id),
   'stale',(SELECT source_revision<>revision FROM admission.sim_input_snapshot WHERE snapshot_id=latest.snapshot_id),
   'allocation',(SELECT to_jsonb(r)||jsonb_build_object('program',p.code,'institute',p.institute) FROM admission.sim_result r JOIN admission.program p USING(program_id) WHERE sim_id=latest.sim_id AND student_id=u.student_id),
   'outcome',(SELECT outcome FROM admission.sim_student_outcome WHERE sim_id=latest.sim_id AND student_id=u.student_id)) END);
END $$;

CREATE FUNCTION run_mock(p_year int) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); n int; sid bigint;
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year AND NOT choices_locked AND choice_deadline>clock_timestamp();
 IF NOT FOUND THEN RAISE EXCEPTION 'Mock allotment requires an open choice window'; END IF;
 SELECT round_id INTO n FROM admission.counselling_round WHERE year=p_year AND status='CHOICES_OPEN' ORDER BY round_no LIMIT 1;
 IF n IS NULL THEN RAISE EXCEPTION 'No open round for mock allotment'; END IF;
 sid:=admission.run_allocation(n,'{"label":"Mock allotment"}',NULL,false,NULL);
 UPDATE admission.sim_run SET is_mock=true WHERE sim_id=sid;RETURN sid;
END $$;
CREATE FUNCTION job_start(p_name text,p_year int,p_slot text) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); n bigint;
BEGIN
 IF p_name NOT IN ('nightly_mock','maintenance') THEN RAISE EXCEPTION 'Unknown job'; END IF;
 INSERT INTO admission.job_run(job_name,year,slot,status) VALUES(p_name,p_year,p_slot,'RUNNING')
 ON CONFLICT(job_name,year,slot) DO UPDATE SET status='RUNNING',started_at=clock_timestamp(),completed_at=NULL,message=NULL
 WHERE job_run.status='FAILED' OR (job_run.status='RUNNING' AND job_run.started_at<clock_timestamp()-interval '15 minutes') RETURNING job_id INTO n;
 RETURN n;
END $$;
CREATE FUNCTION job_finish(p_id bigint,p_status text,p_sim bigint,p_message text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 UPDATE admission.job_run SET status=p_status,sim_id=p_sim,message=left(p_message,500),completed_at=clock_timestamp() WHERE job_id=p_id;
 PERFORM admission.append_event('job_run',p_status,jsonb_build_object('job_id',p_id,'sim_id',p_sim,'message',left(p_message,500)));
END $$;
CREATE FUNCTION admin_dashboard(p_year int) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 RETURN jsonb_build_object('holdings',coalesce((SELECT jsonb_agg(to_jsonb(h)||jsonb_build_object('student_name',s.full_name,'program',p.code,'institute',p.institute,'confirmed_at',f.confirmed_at) ORDER BY h.student_id)
 FROM admission.seat_holding h JOIN admission.student s USING(student_id) JOIN admission.program p USING(program_id) LEFT JOIN admission.final_admission f USING(year,student_id) WHERE year=p_year),'[]'::jsonb),
 'jobs',coalesce((SELECT jsonb_agg(to_jsonb(j) ORDER BY job_id DESC) FROM(SELECT * FROM admission.job_run WHERE year=p_year ORDER BY job_id DESC LIMIT 30) j),'[]'::jsonb),
 'freshness',(SELECT to_jsonb(p) FROM admission.prediction_state p WHERE year=p_year));
END $$;
CREATE OR REPLACE FUNCTION finalize_admission(p_student bigint,p_year int) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 IF EXISTS(SELECT 1 FROM admission.counselling_round WHERE year=p_year AND status<>'CLOSED') THEN RAISE EXCEPTION 'Close all rounds before final confirmation'; END IF;
 UPDATE admission.seat_holding SET final=true WHERE student_id=p_student AND year=p_year;
 IF NOT FOUND THEN RAISE EXCEPTION 'No holding to confirm'; END IF;
 INSERT INTO admission.final_admission(year,student_id,confirmed_by) VALUES(p_year,p_student,u.user_id) ON CONFLICT DO NOTHING;
 PERFORM admission.append_event('final_admission','CONFIRM',jsonb_build_object('year',p_year,'student_id',p_student));
END $$;
CREATE FUNCTION close_spot(p_year int) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 UPDATE admission.spot_pool SET status='CLOSED' WHERE year=p_year;
 PERFORM admission.append_event('spot_pool','CLOSE',jsonb_build_object('year',p_year));
END $$;
CREATE FUNCTION pin_simulation(p_sim bigint,p_pin boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN','ANALYST');
BEGIN
 UPDATE admission.sim_run SET pinned=p_pin WHERE sim_id=p_sim;
 IF NOT FOUND THEN RAISE EXCEPTION 'Simulation not found'; END IF;
 PERFORM admission.append_event('sim_run','PIN',jsonb_build_object('sim_id',p_sim,'pinned',p_pin));
END $$;
CREATE FUNCTION prune_simulations() RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); n int;
BEGIN
 DELETE FROM admission.sim_run s WHERE started_at<clock_timestamp()-interval '7 days' AND NOT pinned AND NOT is_published AND NOT is_mock
 AND NOT EXISTS(SELECT 1 FROM admission.sim_run child WHERE child.base_sim_id=s.sim_id);
 GET DIAGNOSTICS n=ROW_COUNT;
 DELETE FROM admission.sim_input_snapshot snap WHERE NOT EXISTS(SELECT 1 FROM admission.sim_run s WHERE s.snapshot_id=snap.snapshot_id);
 DELETE FROM admission.app_session WHERE expires_at<clock_timestamp();
 PERFORM admission.append_event('sim_run','RETENTION',jsonb_build_object('deleted',n));RETURN n;
END $$;
GRANT EXECUTE ON FUNCTION record_login_attempt(text,text),import_exams(int,jsonb,boolean,bigint),refresh_predictions(int),import_history(jsonb),predictor_dashboard(int),run_mock(int),job_start(text,int,text),job_finish(bigint,text,bigint,text),admin_dashboard(int),close_spot(int),pin_simulation(bigint,boolean),prune_simulations() TO admission_app;
