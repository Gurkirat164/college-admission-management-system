SET search_path=admission,pg_catalog,public;
CREATE MATERIALIZED VIEW mv_cutoff_trend AS
 SELECT program_id,seat_category,count(*) AS years_of_data,min(closing_rank) AS toughest_close,max(closing_rank) AS easiest_close,
 greatest(1,round(coalesce(regr_intercept(closing_rank,year)+regr_slope(closing_rank,year)*(max(year)+1),avg(closing_rank))))::int AS projected_close,
 bool_and(source='synthetic') AS synthetic
 FROM hist_closing GROUP BY program_id,seat_category;
CREATE UNIQUE INDEX ON mv_cutoff_trend(program_id,seat_category);
CREATE FUNCTION my_chances(p_year int) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT');
BEGIN
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('program_id',p.program_id,'program',p.code,'institute',p.institute,'seat_category',m.seat_category,'your_rank',CASE WHEN m.seat_category='OPEN' THEN r.crl_rank ELSE r.cat_rank END,
 'projected_close',m.projected_close,'years_of_data',m.years_of_data,'synthetic',m.synthetic,'band',
 CASE WHEN m.years_of_data<2 THEN 'INSUFFICIENT_DATA'
 WHEN (CASE WHEN m.seat_category='OPEN' THEN r.crl_rank ELSE r.cat_rank END)<=m.toughest_close*0.9 THEN 'SAFE'
 WHEN (CASE WHEN m.seat_category='OPEN' THEN r.crl_rank ELSE r.cat_rank END)<=greatest(m.projected_close,m.toughest_close*0.9) THEN 'LIKELY'
 WHEN (CASE WHEN m.seat_category='OPEN' THEN r.crl_rank ELSE r.cat_rank END)<=greatest(m.easiest_close*1.1,m.projected_close,m.toughest_close*0.9) THEN 'REACH' ELSE 'UNLIKELY' END) ORDER BY p.program_id,m.seat_category)
 FROM admission.mv_cutoff_trend m JOIN admission.program p USING(program_id) JOIN admission.exam_result r ON r.student_id=u.student_id AND r.year=p_year JOIN admission.application a ON a.student_id=r.student_id AND a.year=r.year
 WHERE (m.seat_category='OPEN' OR m.seat_category=a.admission_category) AND (m.seat_category='OPEN' OR r.cat_rank IS NOT NULL)),'[]'::jsonb);
END $$;

CREATE FUNCTION open_spot(p_year int) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 IF NOT EXISTS(SELECT 1 FROM admission.counselling_round WHERE year=p_year AND status='CLOSED') OR EXISTS(SELECT 1 FROM admission.counselling_round WHERE year=p_year AND status<>'CLOSED') THEN RAISE EXCEPTION 'All counselling rounds must be closed before spot allocation'; END IF;
 IF EXISTS(SELECT 1 FROM admission.spot_pool WHERE year=p_year) THEN RAISE EXCEPTION 'Spot allocation is already initialized'; END IF;
 INSERT INTO admission.spot_pool(year,program_id,seat_category,initial_capacity,seats_left)
 SELECT p_year,m.program_id,m.seat_category,m.seats-count(h.student_id)::int,m.seats-count(h.student_id)::int FROM admission.seat_matrix m LEFT JOIN admission.seat_holding h USING(year,program_id,seat_category) WHERE m.year=p_year GROUP BY m.program_id,m.seat_category,m.seats;
 PERFORM admission.append_event('spot_pool','OPEN',jsonb_build_object('year',p_year));
END $$;
CREATE FUNCTION spot_availability(p_year int) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.actor();
BEGIN
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(s)||jsonb_build_object('program',p.code,'institute',p.institute) ORDER BY pool_id) FROM admission.spot_pool s JOIN admission.program p USING(program_id) WHERE year=p_year),'[]'::jsonb);
END $$;
CREATE FUNCTION accept_spot(p_pool bigint,p_key text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT'); p admission.spot_pool; a admission.application; existing admission.spot_acceptance; n bigint;
BEGIN
 IF length(p_key) NOT BETWEEN 8 AND 100 THEN RAISE EXCEPTION 'Invalid idempotency key'; END IF;
 SELECT * INTO p FROM admission.spot_pool WHERE pool_id=p_pool;
 IF p.pool_id IS NULL THEN RAISE EXCEPTION 'Spot pool not found'; END IF;
 SELECT * INTO a FROM admission.application WHERE year=p.year AND student_id=u.student_id FOR UPDATE;
 SELECT * INTO existing FROM admission.spot_acceptance WHERE student_id=u.student_id AND idempotency_key=p_key;
 IF existing.acceptance_id IS NOT NULL THEN
   IF existing.pool_id<>p_pool THEN RAISE EXCEPTION 'Idempotency key belongs to another pool'; END IF;
   RETURN jsonb_build_object('status','ACCEPTED','acceptance_id',existing.acceptance_id,'replayed',true);
 END IF;
 IF a.status IS DISTINCT FROM 'VERIFIED' OR p.status<>'OPEN' THEN RAISE EXCEPTION 'Applicant or spot pool is not eligible'; END IF;
 IF p.seat_category<>'OPEN' AND p.seat_category<>a.admission_category THEN RAISE EXCEPTION 'You are not eligible for this category pool'; END IF;
 IF NOT EXISTS(SELECT 1 FROM admission.exam_result r JOIN admission.program_eligibility e ON e.year=r.year AND e.program_id=p.program_id WHERE r.student_id=u.student_id AND r.year=p.year AND r.total_marks>=e.min_marks) THEN RAISE EXCEPTION 'Program eligibility check failed'; END IF;
 IF EXISTS(SELECT 1 FROM admission.seat_holding WHERE year=p.year AND student_id=u.student_id) THEN RAISE EXCEPTION 'You already hold a seat'; END IF;
 UPDATE admission.spot_pool SET seats_left=seats_left-1 WHERE pool_id=p_pool AND status='OPEN' AND seats_left>0;
 IF NOT FOUND THEN RETURN jsonb_build_object('status','SEAT_UNAVAILABLE'); END IF;
 INSERT INTO admission.spot_acceptance(pool_id,student_id,year,idempotency_key) VALUES(p_pool,u.student_id,p.year,p_key) RETURNING acceptance_id INTO n;
 INSERT INTO admission.seat_holding VALUES(p.year,u.student_id,p.program_id,p.seat_category,'SPOT',false);
 RETURN jsonb_build_object('status','ACCEPTED','acceptance_id',n,'replayed',false);
END $$;
CREATE FUNCTION finalize_admission(p_student bigint,p_year int) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 IF EXISTS(SELECT 1 FROM admission.counselling_round WHERE year=p_year AND status<>'CLOSED') THEN RAISE EXCEPTION 'Close all rounds before final confirmation'; END IF;
 UPDATE admission.seat_holding SET final=true WHERE student_id=p_student AND year=p_year;
 IF NOT FOUND THEN RAISE EXCEPTION 'No holding to confirm'; END IF;
 PERFORM admission.append_event('seat_holding','FINALIZE',jsonb_build_object('year',p_year,'student_id',p_student));
END $$;
CREATE FUNCTION seat_history(p_year int,p_at timestamptz) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN','AUDITOR');
BEGIN
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(h)||jsonb_build_object('program',p.code) ORDER BY h.program_id,h.seat_category) FROM admission.seat_matrix_history h JOIN admission.program p USING(program_id) WHERE year=p_year AND valid @> p_at),'[]'::jsonb);
END $$;

CREATE FUNCTION submit_application(p_year int) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT');
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year AND NOT choices_locked AND choice_deadline>clock_timestamp() FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Application window is closed'; END IF;
 IF NOT EXISTS(SELECT 1 FROM admission.document_submission WHERE student_id=u.student_id AND year=p_year) THEN RAISE EXCEPTION 'Upload an exam document before submitting'; END IF;
 UPDATE admission.application SET status='SUBMITTED' WHERE student_id=u.student_id AND year=p_year AND status IN ('DRAFT','REJECTED');
 IF NOT FOUND THEN RAISE EXCEPTION 'Application cannot be submitted in its current state'; END IF;
END $$;
CREATE FUNCTION record_exam(p_student bigint,p_year int,p_category admission.seat_cat,p_marks numeric,p_crl int,p_cat int) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year AND NOT choices_locked FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Exam results are locked'; END IF;
 IF p_category<>'OPEN' AND (p_cat IS NULL OR p_cat<1) THEN RAISE EXCEPTION 'A reserved-category result requires a positive category rank'; END IF;
 UPDATE admission.application SET admission_category=p_category WHERE student_id=p_student AND year=p_year;
 INSERT INTO admission.exam_result VALUES(p_student,p_year,p_marks,p_crl,p_cat) ON CONFLICT(student_id,year) DO UPDATE SET total_marks=excluded.total_marks,crl_rank=excluded.crl_rank,cat_rank=excluded.cat_rank;
 UPDATE admission.admission_cycle SET input_revision=input_revision+1 WHERE year=p_year;
END $$;

REVOKE ALL ON SCHEMA admission FROM PUBLIC;
GRANT USAGE ON SCHEMA admission TO admission_app;
GRANT EXECUTE ON FUNCTION login_record(text),create_session(bigint,text,text,timestamptz),session_identity(text),remove_session(text),register_student(text,text,text),
 workspace(),save_choices(int,int[],boolean),set_seats(int,int,admission.seat_cat,int),lock_round(int),respond(int,text),close_round(int),review_application(bigint,int,boolean,text),
 add_document(int,text,text,text,text,int),get_document(bigint),review_document(bigint,boolean,text),run_allocation(int,jsonb,bigint,boolean,text),run_details(bigint),why_not(int),
 verify_ledger(),my_chances(int),open_spot(int),spot_availability(int),accept_spot(bigint,text),finalize_admission(bigint,int),seat_history(int,timestamptz),submit_application(int),record_exam(bigint,int,admission.seat_cat,numeric,int,int)
TO admission_app;
