--
-- PostgreSQL database dump
--

\restrict hhcKYP5Nb1bUbrTJbBuTJWfogG7WXdwZaI0rtRkZkEpV4RCaYei6n3N6ulsceG2

-- Dumped from database version 16.15
-- Dumped by pg_dump version 16.15

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: admission; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA admission;


--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


--
-- Name: seat_cat; Type: TYPE; Schema: admission; Owner: -
--

CREATE TYPE admission.seat_cat AS ENUM (
    'OPEN',
    'EWS',
    'OBC_NCL',
    'SC',
    'ST'
);


--
-- Name: accept_spot(bigint, text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.accept_spot(p_pool bigint, p_key text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: app_user; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.app_user (
    user_id bigint NOT NULL,
    email text NOT NULL,
    password_hash text NOT NULL,
    full_name text NOT NULL,
    role text NOT NULL,
    student_id bigint,
    enabled boolean DEFAULT true NOT NULL,
    CONSTRAINT app_user_check CHECK (((role = 'STUDENT'::text) = (student_id IS NOT NULL))),
    CONSTRAINT app_user_email_check CHECK ((email = lower(email))),
    CONSTRAINT app_user_role_check CHECK ((role = ANY (ARRAY['STUDENT'::text, 'ADMIN'::text, 'ANALYST'::text, 'AUDITOR'::text])))
);


--
-- Name: actor(); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.actor() RETURNS admission.app_user
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user;
BEGIN
  SELECT * INTO u FROM admission.app_user WHERE user_id=admission.current_app_user_id() AND enabled;
  IF u.user_id IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
  RETURN u;
END $$;


--
-- Name: add_document(integer, text, text, text, text, integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.add_document(p_year integer, p_name text, p_key text, p_mime text, p_checksum text, p_bytes integer) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT'); c admission.admission_cycle; n bigint;
BEGIN
 SELECT * INTO c FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 IF c.choices_locked OR c.choice_deadline<=clock_timestamp() THEN RAISE EXCEPTION 'Document submission window is closed'; END IF;
 INSERT INTO admission.document_submission(student_id,year,original_name,storage_key,mime_type,checksum,byte_count)
 VALUES(u.student_id,p_year,p_name,p_key,p_mime,p_checksum,p_bytes) RETURNING document_id INTO n;
 RETURN n;
END $$;


--
-- Name: admin_dashboard(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.admin_dashboard(p_year integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 RETURN jsonb_build_object('holdings',coalesce((SELECT jsonb_agg(to_jsonb(h)||jsonb_build_object('student_name',s.full_name,'program',p.code,'institute',p.institute,'confirmed_at',f.confirmed_at) ORDER BY h.student_id)
 FROM admission.seat_holding h JOIN admission.student s USING(student_id) JOIN admission.program p USING(program_id) LEFT JOIN admission.final_admission f USING(year,student_id) WHERE year=p_year),'[]'::jsonb),
 'jobs',coalesce((SELECT jsonb_agg(to_jsonb(j) ORDER BY job_id DESC) FROM(SELECT * FROM admission.job_run WHERE year=p_year ORDER BY job_id DESC LIMIT 30) j),'[]'::jsonb),
 'freshness',(SELECT to_jsonb(p) FROM admission.prediction_state p WHERE year=p_year));
END $$;


--
-- Name: append_event(text, text, jsonb); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.append_event(p_entity text, p_op text, p_payload jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE h admission.audit_chain_head; e jsonb; v_hash text; n bigint;
BEGIN
  SELECT * INTO h FROM admission.audit_chain_head WHERE singleton FOR UPDATE;
  n := h.last_seq+1;
  e := jsonb_build_object('version',1,'seq',n,'at',clock_timestamp(),'actor_id',admission.current_app_user_id(),
                          'entity',p_entity,'op',p_op,'payload',p_payload);
  v_hash := encode(sha256(convert_to(h.last_hash || e::text,'UTF8')),'hex');
  INSERT INTO admission.audit_ledger VALUES(n,e,h.last_hash,v_hash);
  UPDATE admission.audit_chain_head SET last_seq=n,last_hash=v_hash WHERE singleton;
  RETURN n;
END $$;


--
-- Name: audit_change(); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.audit_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
BEGIN
  PERFORM admission.append_event(TG_TABLE_NAME,TG_OP,jsonb_build_object('old',to_jsonb(OLD),'new',to_jsonb(NEW)));
  RETURN NULL;
END $$;


--
-- Name: audit_events(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.audit_events(p_offset integer DEFAULT 0) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN','AUDITOR');
BEGIN
 RETURN jsonb_build_object('total',(SELECT count(*) FROM admission.audit_ledger),'events',coalesce((SELECT jsonb_agg(to_jsonb(e) ORDER BY seq DESC) FROM(
 SELECT seq,envelope->>'at' recorded_at,envelope->>'entity' entity,envelope->>'op' operation,envelope->>'actor_id' actor_id,hash
 FROM admission.audit_ledger ORDER BY seq DESC LIMIT 25 OFFSET greatest(0,p_offset)) e),'[]'::jsonb));
END $$;


--
-- Name: check_checkpoint(bigint, text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.check_checkpoint(p_seq bigint, p_hash text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN','AUDITOR'); h text;
BEGIN
 SELECT hash INTO h FROM admission.audit_ledger WHERE seq=p_seq;
 RETURN jsonb_build_object('matches',h IS NOT NULL AND h=p_hash,'checkpoint_seq',p_seq,'chain_length',(SELECT last_seq FROM admission.audit_chain_head));
END $$;


--
-- Name: close_round(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.close_round(p_round integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); r admission.counselling_round;
BEGIN
 SELECT year INTO r.year FROM admission.counselling_round WHERE round_id=p_round;
 PERFORM 1 FROM admission.admission_cycle WHERE year=r.year FOR UPDATE;
 SELECT * INTO r FROM admission.counselling_round WHERE round_id=p_round FOR UPDATE;
 IF r.status<>'PUBLISHED' OR clock_timestamp()<r.response_deadline THEN RAISE EXCEPTION 'Round must be published and its response deadline passed'; END IF;
 INSERT INTO admission.student_response(round_id,student_id,decision,is_default)
 SELECT p_round,student_id,'FREEZE',true FROM admission.allocation WHERE round_id=p_round ON CONFLICT DO NOTHING;
 UPDATE admission.application a SET status='WITHDRAWN' FROM admission.student_response s
 WHERE a.year=r.year AND a.student_id=s.student_id AND s.round_id=p_round AND s.decision='WITHDRAW';
 DELETE FROM admission.seat_holding h USING admission.student_response s WHERE h.year=r.year AND h.student_id=s.student_id AND s.round_id=p_round AND s.decision='WITHDRAW';
 UPDATE admission.counselling_round SET status='CLOSED' WHERE round_id=p_round;
 UPDATE admission.admission_cycle SET input_revision=input_revision+1 WHERE year=r.year;
END $$;


--
-- Name: close_spot(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.close_spot(p_year integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 UPDATE admission.spot_pool SET status='CLOSED' WHERE year=p_year;
 PERFORM admission.append_event('spot_pool','CLOSE',jsonb_build_object('year',p_year));
END $$;


--
-- Name: create_next_round(integer, timestamp with time zone); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.create_next_round(p_year integer, p_deadline timestamp with time zone) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); previous admission.counselling_round; n int;
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 SELECT * INTO previous FROM admission.counselling_round WHERE year=p_year ORDER BY round_no DESC LIMIT 1;
 IF previous.status IS DISTINCT FROM 'CLOSED' THEN RAISE EXCEPTION 'Close the previous round before creating the next'; END IF;
 IF EXISTS(SELECT 1 FROM admission.spot_pool WHERE year=p_year) OR EXISTS(SELECT 1 FROM admission.seat_holding WHERE year=p_year AND final) THEN RAISE EXCEPTION 'The cycle has moved beyond ordinary counselling'; END IF;
 IF p_deadline<=clock_timestamp() THEN RAISE EXCEPTION 'Response deadline must be in the future'; END IF;
 INSERT INTO admission.counselling_round(year,round_no,response_deadline,status) VALUES(p_year,previous.round_no+1,p_deadline,'LOCKED') RETURNING round_id INTO n;
 RETURN n;
END $$;


--
-- Name: create_session(bigint, text, text, timestamp with time zone); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.create_session(p_user bigint, p_token text, p_csrf text, p_expiry timestamp with time zone) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
 INSERT INTO admission.app_session(token_hash,user_id,csrf_hash,expires_at) VALUES(p_token,p_user,p_csrf,p_expiry)
$$;


--
-- Name: current_app_user_id(); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.current_app_user_id() RETURNS bigint
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
  SELECT nullif(current_setting('app.user_id',true),'')::bigint
$$;


--
-- Name: explanation_summary(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.explanation_summary(p_round integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT');
BEGIN
 RETURN(SELECT to_jsonb(o) FROM admission.sim_student_outcome o JOIN admission.counselling_round cr ON cr.published_sim_id=o.sim_id WHERE cr.round_id=p_round AND o.student_id=u.student_id);
END $$;


--
-- Name: finalize_admission(bigint, integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.finalize_admission(p_student bigint, p_year integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 IF EXISTS(SELECT 1 FROM admission.counselling_round WHERE year=p_year AND status<>'CLOSED') THEN RAISE EXCEPTION 'Close all rounds before final confirmation'; END IF;
 UPDATE admission.seat_holding SET final=true WHERE student_id=p_student AND year=p_year;
 IF NOT FOUND THEN RAISE EXCEPTION 'No holding to confirm'; END IF;
 INSERT INTO admission.final_admission(year,student_id,confirmed_by) VALUES(p_year,p_student,u.user_id) ON CONFLICT DO NOTHING;
 PERFORM admission.append_event('final_admission','CONFIRM',jsonb_build_object('year',p_year,'student_id',p_student));
END $$;


--
-- Name: get_document(bigint); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.get_document(p_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.actor(); d admission.document_submission;
BEGIN
 SELECT * INTO d FROM admission.document_submission WHERE document_id=p_id;
 IF d.document_id IS NULL OR (u.role<>'ADMIN' AND (u.role<>'STUDENT' OR u.student_id<>d.student_id)) THEN RAISE EXCEPTION 'Document not found' USING ERRCODE='P0002'; END IF;
 RETURN to_jsonb(d);
END $$;


--
-- Name: guard_choices(); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.guard_choices() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE y int:=coalesce(NEW.year,OLD.year); c admission.admission_cycle; locked timestamptz;
BEGIN
  SELECT * INTO c FROM admission.admission_cycle WHERE year=y FOR UPDATE;
  SELECT choices_locked_at INTO locked FROM admission.application
    WHERE student_id=coalesce(NEW.student_id,OLD.student_id) AND year=y;
  IF c.choices_locked OR c.choice_deadline<=clock_timestamp() OR locked IS NOT NULL THEN
    RAISE EXCEPTION 'Choices are locked for this application or cycle' USING ERRCODE='P0001';
  END IF;
  UPDATE admission.admission_cycle SET input_revision=input_revision+1 WHERE year=y;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;


--
-- Name: history_change(); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.history_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE b timestamptz:=statement_timestamp(); old_h admission.seat_matrix_history;
BEGIN
  IF TG_OP<>'INSERT' THEN
    SELECT * INTO old_h FROM admission.seat_matrix_history WHERE year=OLD.year AND program_id=OLD.program_id
      AND seat_category=OLD.seat_category AND upper_inf(valid) FOR UPDATE;
    IF old_h.history_id IS NOT NULL THEN
      IF lower(old_h.valid)=b THEN
        DELETE FROM admission.seat_matrix_history WHERE history_id=old_h.history_id;
      ELSE
        IF b<lower(old_h.valid) THEN RAISE EXCEPTION 'History timestamp moved backwards'; END IF;
        UPDATE admission.seat_matrix_history SET valid=tstzrange(lower(valid),b,'[)') WHERE history_id=old_h.history_id;
      END IF;
    END IF;
  END IF;
  IF TG_OP<>'DELETE' THEN
    INSERT INTO admission.seat_matrix_history(year,program_id,seat_category,seats,valid)
      VALUES(NEW.year,NEW.program_id,NEW.seat_category,NEW.seats,tstzrange(b,NULL,'[)'));
  END IF;
  RETURN NULL;
END $$;


--
-- Name: import_exams(integer, jsonb, boolean, bigint); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.import_exams(p_year integer, p_rows jsonb, p_commit boolean, p_revision bigint DEFAULT NULL::bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
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


--
-- Name: import_history(jsonb); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.import_history(p_rows jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
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


--
-- Name: job_finish(bigint, text, bigint, text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.job_finish(p_id bigint, p_status text, p_sim bigint, p_message text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 UPDATE admission.job_run SET status=p_status,sim_id=p_sim,message=left(p_message,500),completed_at=clock_timestamp() WHERE job_id=p_id;
 PERFORM admission.append_event('job_run',p_status,jsonb_build_object('job_id',p_id,'sim_id',p_sim,'message',left(p_message,500)));
END $$;


--
-- Name: job_start(text, integer, text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.job_start(p_name text, p_year integer, p_slot text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); n bigint;
BEGIN
 IF p_name NOT IN ('nightly_mock','maintenance') THEN RAISE EXCEPTION 'Unknown job'; END IF;
 INSERT INTO admission.job_run(job_name,year,slot,status) VALUES(p_name,p_year,p_slot,'RUNNING')
 ON CONFLICT(job_name,year,slot) DO UPDATE SET status='RUNNING',started_at=clock_timestamp(),completed_at=NULL,message=NULL
 WHERE job_run.status='FAILED' OR (job_run.status='RUNNING' AND job_run.started_at<clock_timestamp()-interval '15 minutes') RETURNING job_id INTO n;
 RETURN n;
END $$;


--
-- Name: job_targets(); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.job_targets() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('year',year,'choices_open',NOT choices_locked AND choice_deadline>clock_timestamp())) FROM admission.admission_cycle),'[]'::jsonb);
END $$;


--
-- Name: lock_round(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.lock_round(p_round integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); y int; r admission.counselling_round;
BEGIN
 SELECT year INTO y FROM admission.counselling_round WHERE round_id=p_round;
 PERFORM 1 FROM admission.admission_cycle WHERE year=y FOR UPDATE;
 SELECT * INTO r FROM admission.counselling_round WHERE round_id=p_round FOR UPDATE;
 IF r.status='LOCKED' THEN RETURN; END IF; IF r.status IS NULL OR r.status<>'CHOICES_OPEN' THEN RAISE EXCEPTION 'Round is not open for locking'; END IF;
 IF r.round_no>1 AND NOT EXISTS(SELECT 1 FROM admission.counselling_round WHERE year=y AND round_no=r.round_no-1 AND status='CLOSED') THEN RAISE EXCEPTION 'Close the previous round first'; END IF;
 UPDATE admission.admission_cycle SET choices_locked=true,input_revision=input_revision+1 WHERE year=y;
 UPDATE admission.counselling_round SET status='LOCKED' WHERE round_id=p_round;
END $$;


--
-- Name: log_operation_failure(text, text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.log_operation_failure(p_operation text, p_code text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.actor();
BEGIN
 PERFORM admission.append_event('operation','FAILED',jsonb_build_object('operation',left(p_operation,100),'code',left(p_code,10)));
END $$;


--
-- Name: login_record(text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.login_record(p_email text) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
 SELECT jsonb_build_object('user_id',user_id,'password_hash',password_hash,'enabled',enabled)
 FROM admission.app_user WHERE email=lower(trim(p_email))
$$;


--
-- Name: my_chances(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.my_chances(p_year integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT');
BEGIN
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('program_id',p.program_id,'program',p.code,'institute',p.institute,'seat_category',m.seat_category,'your_rank',CASE WHEN m.seat_category='OPEN' THEN r.crl_rank ELSE r.cat_rank END,
 'projected_close',m.projected_close,'years_of_data',m.years_of_data,'synthetic',m.synthetic,'band',
 CASE WHEN m.years_of_data<2 THEN 'INSUFFICIENT_DATA'
 WHEN (CASE WHEN m.seat_category='OPEN' THEN r.crl_rank ELSE r.cat_rank END)<=m.toughest_close*0.9 THEN 'SAFE'
 WHEN (CASE WHEN m.seat_category='OPEN' THEN r.crl_rank ELSE r.cat_rank END)<=greatest(m.projected_close,m.toughest_close*0.9) THEN 'LIKELY'
 WHEN (CASE WHEN m.seat_category='OPEN' THEN r.crl_rank ELSE r.cat_rank END)<=greatest(m.easiest_close*1.1,m.projected_close,m.toughest_close*0.9) THEN 'REACH' ELSE 'UNLIKELY' END) ORDER BY p.program_id,m.seat_category)
 FROM admission.mv_cutoff_trend m JOIN admission.program p USING(program_id) JOIN admission.exam_result r ON r.student_id=u.student_id AND r.year=p_year JOIN admission.application a ON a.student_id=r.student_id AND a.year=r.year
 WHERE m.prediction_year=p_year AND (m.seat_category='OPEN' OR m.seat_category=a.admission_category) AND (m.seat_category='OPEN' OR r.cat_rank IS NOT NULL)),'[]'::jsonb);
END $$;


--
-- Name: open_spot(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.open_spot(p_year integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 IF NOT EXISTS(SELECT 1 FROM admission.counselling_round WHERE year=p_year AND status='CLOSED') OR EXISTS(SELECT 1 FROM admission.counselling_round WHERE year=p_year AND status<>'CLOSED') THEN RAISE EXCEPTION 'All counselling rounds must be closed before spot allocation'; END IF;
 IF EXISTS(SELECT 1 FROM admission.spot_pool WHERE year=p_year) THEN RAISE EXCEPTION 'Spot allocation is already initialized'; END IF;
 INSERT INTO admission.spot_pool(year,program_id,seat_category,initial_capacity,seats_left)
 SELECT p_year,m.program_id,m.seat_category,m.seats-count(h.student_id)::int,m.seats-count(h.student_id)::int FROM admission.seat_matrix m LEFT JOIN admission.seat_holding h USING(year,program_id,seat_category) WHERE m.year=p_year GROUP BY m.program_id,m.seat_category,m.seats;
 PERFORM admission.append_event('spot_pool','OPEN',jsonb_build_object('year',p_year));
END $$;


--
-- Name: own_holding(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.own_holding(p_year integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT');
BEGIN
 RETURN(SELECT to_jsonb(h)||jsonb_build_object('program',p.code,'institute',p.institute,'confirmed_at',f.confirmed_at) FROM admission.seat_holding h JOIN admission.program p USING(program_id) LEFT JOIN admission.final_admission f USING(year,student_id) WHERE year=p_year AND student_id=u.student_id);
END $$;


--
-- Name: pin_simulation(bigint, boolean); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.pin_simulation(p_sim bigint, p_pin boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN','ANALYST');
BEGIN
 UPDATE admission.sim_run SET pinned=p_pin WHERE sim_id=p_sim;
 IF NOT FOUND THEN RAISE EXCEPTION 'Simulation not found'; END IF;
 PERFORM admission.append_event('sim_run','PIN',jsonb_build_object('sim_id',p_sim,'pinned',p_pin));
END $$;


--
-- Name: predictor_dashboard(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.predictor_dashboard(p_year integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT'); latest admission.sim_run; revision bigint; bands jsonb;
BEGIN
 SELECT sr.* INTO latest FROM admission.sim_run sr JOIN admission.counselling_round cr USING(round_id) WHERE cr.year=p_year AND sr.is_mock ORDER BY sr.sim_id DESC LIMIT 1;
 SELECT input_revision INTO revision FROM admission.admission_cycle WHERE year=p_year;
 bands:=admission.my_chances(p_year);
 RETURN jsonb_build_object('bands',bands,'freshness',(SELECT to_jsonb(p) FROM admission.prediction_state p WHERE year=p_year),
  'round_drift',coalesce((SELECT jsonb_agg(jsonb_build_object('program_id',program_id,'seat_category',seat_category,'drift_percent',drift_percent)) FROM admission.mv_cutoff_trend WHERE prediction_year=p_year),'[]'::jsonb),
  'choice_count',(SELECT count(*) FROM admission.choice WHERE year=p_year AND student_id=u.student_id),
  'has_safe_choice',EXISTS(SELECT 1 FROM jsonb_array_elements(bands) b JOIN admission.choice c ON c.program_id=(b->>'program_id')::int WHERE c.year=p_year AND c.student_id=u.student_id AND b->>'band'='SAFE'),
  'mock',CASE WHEN latest.sim_id IS NULL THEN NULL ELSE jsonb_build_object('sim_id',latest.sim_id,'captured_at',(SELECT captured_at FROM admission.sim_input_snapshot WHERE snapshot_id=latest.snapshot_id),
   'stale',(SELECT source_revision<>revision FROM admission.sim_input_snapshot WHERE snapshot_id=latest.snapshot_id),
   'allocation',(SELECT to_jsonb(r)||jsonb_build_object('program',p.code,'institute',p.institute) FROM admission.sim_result r JOIN admission.program p USING(program_id) WHERE sim_id=latest.sim_id AND student_id=u.student_id),
   'outcome',(SELECT outcome FROM admission.sim_student_outcome WHERE sim_id=latest.sim_id AND student_id=u.student_id)) END);
END $$;


--
-- Name: prune_simulations(); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.prune_simulations() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); n int;
BEGIN
 DELETE FROM admission.sim_run s WHERE started_at<clock_timestamp()-interval '7 days' AND NOT pinned AND NOT is_published
 AND NOT EXISTS(SELECT 1 FROM admission.sim_run child WHERE child.base_sim_id=s.sim_id)
 AND (NOT is_mock OR s.sim_id<>(SELECT max(m.sim_id) FROM admission.sim_run m JOIN admission.counselling_round mr USING(round_id)
 WHERE m.is_mock AND mr.year=(SELECT year FROM admission.counselling_round WHERE round_id=s.round_id)));
 GET DIAGNOSTICS n=ROW_COUNT;
 DELETE FROM admission.sim_input_snapshot snap WHERE NOT EXISTS(SELECT 1 FROM admission.sim_run s WHERE s.snapshot_id=snap.snapshot_id);
 DELETE FROM admission.app_session WHERE expires_at<clock_timestamp();
 PERFORM admission.append_event('sim_run','RETENTION',jsonb_build_object('deleted',n));RETURN n;
END $$;


--
-- Name: record_exam(bigint, integer, admission.seat_cat, numeric, integer, integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.record_exam(p_student bigint, p_year integer, p_category admission.seat_cat, p_marks numeric, p_crl integer, p_cat integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year AND NOT choices_locked FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Exam results are locked'; END IF;
 IF p_category<>'OPEN' AND (p_cat IS NULL OR p_cat<1) THEN RAISE EXCEPTION 'A reserved-category result requires a positive category rank'; END IF;
 UPDATE admission.application SET admission_category=p_category WHERE student_id=p_student AND year=p_year;
 INSERT INTO admission.exam_result VALUES(p_student,p_year,p_marks,p_crl,p_cat) ON CONFLICT(student_id,year) DO UPDATE SET total_marks=excluded.total_marks,crl_rank=excluded.crl_rank,cat_rank=excluded.cat_rank,maths=NULL,physics=NULL,chemistry=NULL;
 UPDATE admission.admission_cycle SET input_revision=input_revision+1 WHERE year=p_year;
END $$;


--
-- Name: record_login_attempt(text, text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.record_login_attempt(p_ip text, p_email text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('login:'||p_ip,0));
 DELETE FROM admission.login_attempt WHERE at<clock_timestamp()-interval '10 minutes';
 IF (SELECT count(*) FROM admission.login_attempt WHERE ip_hash=p_ip AND at>clock_timestamp()-interval '1 minute')>=30
 OR (SELECT count(*) FROM admission.login_attempt WHERE email_hash=p_email AND at>clock_timestamp()-interval '1 minute')>=10 THEN RETURN false; END IF;
 INSERT INTO admission.login_attempt(ip_hash,email_hash) VALUES(p_ip,p_email);RETURN true;
END $$;


--
-- Name: refresh_predictions(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.refresh_predictions(p_year integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
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


--
-- Name: register_student(text, text, text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.register_student(p_email text, p_name text, p_hash text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE sid bigint; uid bigint; y int;
BEGIN
 INSERT INTO admission.student(full_name) VALUES(trim(p_name)) RETURNING student_id INTO sid;
 INSERT INTO admission.app_user(email,full_name,password_hash,role,student_id) VALUES(lower(trim(p_email)),trim(p_name),p_hash,'STUDENT',sid) RETURNING user_id INTO uid;
 SELECT max(year) INTO y FROM admission.admission_cycle WHERE NOT choices_locked AND choice_deadline>clock_timestamp();
 IF y IS NOT NULL THEN INSERT INTO admission.application(student_id,year) VALUES(sid,y); END IF;
 RETURN uid;
END $$;


--
-- Name: remove_session(text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.remove_session(p_token text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$ DELETE FROM admission.app_session WHERE token_hash=p_token $$;


--
-- Name: require_role(text[]); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.require_role(VARIADIC allowed text[]) RETURNS admission.app_user
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user := admission.actor();
BEGIN
  IF NOT u.role=ANY(allowed) THEN RAISE EXCEPTION 'This action is not permitted for your role' USING ERRCODE='42501'; END IF;
  RETURN u;
END $$;


--
-- Name: respond(integer, text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.respond(p_round integer, p_decision text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT'); r admission.counselling_round;
BEGIN
 SELECT year INTO r.year FROM admission.counselling_round WHERE round_id=p_round;
 PERFORM 1 FROM admission.admission_cycle WHERE year=r.year FOR UPDATE;
 SELECT * INTO r FROM admission.counselling_round WHERE round_id=p_round FOR UPDATE;
 IF r.status<>'PUBLISHED' OR clock_timestamp()>=r.response_deadline THEN RAISE EXCEPTION 'Response window is closed'; END IF;
 IF NOT EXISTS(SELECT 1 FROM admission.allocation WHERE round_id=p_round AND student_id=u.student_id) THEN RAISE EXCEPTION 'No allocation to respond to'; END IF;
 IF EXISTS(SELECT 1 FROM admission.student_response WHERE round_id=p_round AND student_id=u.student_id AND decision='WITHDRAW') THEN RAISE EXCEPTION 'Withdrawal cannot be reversed'; END IF;
 INSERT INTO admission.student_response(round_id,student_id,decision) VALUES(p_round,u.student_id,p_decision)
 ON CONFLICT(round_id,student_id) DO UPDATE SET decision=excluded.decision,responded_at=clock_timestamp(),is_default=false;
 UPDATE admission.admission_cycle SET input_revision=input_revision+1 WHERE year=r.year;
END $$;


--
-- Name: review_application(bigint, integer, boolean, text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.review_application(p_student bigint, p_year integer, p_approve boolean, p_reason text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); cycle admission.admission_cycle; previous admission.application;
BEGIN
 SELECT * INTO cycle FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 SELECT * INTO previous FROM admission.application WHERE student_id=p_student AND year=p_year;
 IF previous.student_id IS NULL THEN RAISE EXCEPTION 'Application not found'; END IF;
 IF cycle.choices_locked THEN RAISE EXCEPTION 'Eligibility is locked for this cycle'; END IF;
 IF p_approve AND NOT EXISTS(SELECT 1 FROM admission.exam_result WHERE student_id=p_student AND year=p_year) THEN RAISE EXCEPTION 'An annual exam result is required before verification'; END IF;
 IF p_approve AND previous.status<>'VERIFIED' AND NOT EXISTS(SELECT 1 FROM admission.document_submission WHERE student_id=p_student AND year=p_year AND status='VERIFIED') THEN RAISE EXCEPTION 'Verify an exam document before approving the application'; END IF;
 IF NOT p_approve AND length(trim(coalesce(p_reason,'')))<3 THEN RAISE EXCEPTION 'Provide a rejection reason'; END IF;
 UPDATE admission.application SET status=CASE WHEN p_approve THEN 'VERIFIED' ELSE 'REJECTED' END,review_reason=p_reason WHERE student_id=p_student AND year=p_year;
 UPDATE admission.admission_cycle SET input_revision=input_revision+1 WHERE year=p_year;
END $$;


--
-- Name: review_document(bigint, boolean, text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.review_document(p_id bigint, p_approve boolean, p_reason text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); d admission.document_submission;
BEGIN
 SELECT * INTO d FROM admission.document_submission WHERE document_id=p_id;
 PERFORM 1 FROM admission.admission_cycle WHERE year=d.year AND NOT choices_locked FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Document is missing or the cycle is locked'; END IF;
 IF NOT p_approve AND length(trim(coalesce(p_reason,'')))<3 THEN RAISE EXCEPTION 'Provide a rejection reason'; END IF;
 UPDATE admission.document_submission SET status=CASE WHEN p_approve THEN 'VERIFIED' ELSE 'REJECTED' END,reason=p_reason WHERE document_id=p_id;
END $$;


--
-- Name: run_allocation(integer, jsonb, bigint, boolean, text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.run_allocation(p_round integer, p_scenario jsonb DEFAULT '{}'::jsonb, p_base bigint DEFAULT NULL::bigint, p_publish boolean DEFAULT false, p_key text DEFAULT NULL::text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $_$
DECLARE
 u admission.app_user:=admission.require_role('ADMIN','ANALYST');
 v_round admission.counselling_round; cycle admission.admission_cycle; base admission.sim_run;
 snapshot admission.sim_input_snapshot; payload jsonb; sid bigint; v_sim bigint;
 t0 timestamptz:=clock_timestamp(); changed int; iterations int:=0; bound int;
 violations int; stable_count int; mono text:='NOT_APPLICABLE'; item jsonb; copy_done timestamptz; solve_done timestamptz;
BEGIN
 PERFORM set_config('work_mem','32MB',true);
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
 copy_done:=clock_timestamp();
 SELECT count(*)+1 INTO bound FROM w_choice;
 CREATE TEMP TABLE w_ranked ON COMMIT DROP AS SELECT h.*,0::bigint rn,0::int seats FROM w_hold h WHERE false;
 LOOP
  iterations:=iterations+1;
  IF iterations>bound THEN RAISE EXCEPTION 'Solver exceeded its proposal bound'; END IF;
  TRUNCATE w_ranked;
  INSERT INTO w_ranked
  SELECT candidates.*,row_number() OVER(PARTITION BY candidates.program_id,candidates.seat_category ORDER BY candidates.rank_used,candidates.student_id),coalesce(seats.seats,0)
  FROM(SELECT * FROM w_hold UNION ALL
    SELECT c.student_id,c.program_id,c.seat_category,c.pref_order,c.k,c.rank_used FROM w_state free
    JOIN w_choice c ON c.student_id=free.student_id AND c.k=free.next_k WHERE free.status='FREE') candidates
  LEFT JOIN w_seats seats ON seats.program_id=candidates.program_id AND seats.seat_category=candidates.seat_category;
  TRUNCATE w_hold;
  INSERT INTO w_hold SELECT student_id,program_id,seat_category,pref_order,k,rank_used FROM w_ranked WHERE rn<=seats;
  TRUNCATE w_state;
  INSERT INTO w_state
  SELECT rejected.student_id,next.k,'FREE' FROM w_ranked rejected
  CROSS JOIN LATERAL(SELECT min(c.k) k FROM w_choice c WHERE c.student_id=rejected.student_id AND c.k>rejected.k) next
  WHERE rejected.rn>rejected.seats AND next.k IS NOT NULL;
  GET DIAGNOSTICS changed=ROW_COUNT;
  EXIT WHEN changed=0;
 END LOOP;

 solve_done:=clock_timestamp();
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
 UPDATE admission.sim_student_outcome outcome SET reason_code=CASE
 WHEN outcome.outcome='ALLOTTED' THEN 'ALLOTTED'
 WHEN outcome.outcome='EXCLUDED' THEN 'APPLICATION_NOT_VERIFIED'
 WHEN outcome.outcome='WITHDRAWN' THEN 'WITHDRAWN'
 WHEN NOT EXISTS(SELECT 1 FROM w_choice c WHERE c.student_id=outcome.student_id) THEN 'NO_ELIGIBLE_CHOICES'
 ELSE 'ALL_ELIGIBLE_CHOICES_FULL' END WHERE sim_id=v_sim;
 INSERT INTO admission.sim_trace
 SELECT v_sim,c.student_id,c.program_id,c.seat_category,c.pref_order,c.k,c.rank_used,cutoff.closing_rank,
   CASE WHEN h.k=c.k THEN 'ALLOTTED' WHEN h.k<c.k THEN 'NOT_REACHED' ELSE 'REJECTED_FULL' END
 FROM w_choice c LEFT JOIN w_hold h USING(student_id)
 LEFT JOIN(SELECT program_id,seat_category,max(rank_used) closing_rank FROM admission.sim_result WHERE sim_id=v_sim GROUP BY 1,2) cutoff ON cutoff.program_id=c.program_id AND cutoff.seat_category=c.seat_category;
 INSERT INTO admission.sim_trace SELECT v_sim,f.student_id,f.program_id,f.seat_category,f.pref_order,f.k,f.rank_used,
 (SELECT max(r.rank_used) FROM admission.sim_result r WHERE r.sim_id=v_sim AND r.program_id=f.program_id AND r.seat_category=f.seat_category),'RETAINED' FROM w_fixed f;
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
   checks=jsonb_build_object('stability','PASS','blocking_pairs',stable_count,'capacity','PASS','monotonicity',mono,'iterations',iterations,'phase_ms',jsonb_build_object('snapshot_and_scenario',round(extract(epoch FROM copy_done-t0)*1000),'solve',round(extract(epoch FROM solve_done-copy_done)*1000),'verify_and_persist',round(extract(epoch FROM clock_timestamp()-solve_done)*1000))),
   summary=jsonb_build_object('assigned',(SELECT count(*) FROM admission.sim_result WHERE sim_id=v_sim),'applicants',(SELECT count(*) FROM w_people),'changes',coalesce((SELECT jsonb_object_agg(change_type,n) FROM(SELECT change_type,count(*) n FROM admission.sim_diff WHERE sim_id=v_sim GROUP BY change_type) d),'{}'::jsonb))
 WHERE sim_id=v_sim;
 PERFORM admission.append_event('sim_run','SIMULATE',(SELECT jsonb_build_object('sim_id',v_sim,'snapshot_id',sid,'scenario',p_scenario,'summary',summary,'checks',checks,'input_hash',snap.payload_hash)
 FROM admission.sim_run result JOIN admission.sim_input_snapshot snap USING(snapshot_id) WHERE result.sim_id=v_sim));
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
END $_$;


--
-- Name: run_details(bigint); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.run_details(p_sim bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN','ANALYST'); s admission.sim_run;
BEGIN
 SELECT * INTO s FROM admission.sim_run WHERE sim_id=p_sim;
 IF s.sim_id IS NULL THEN RAISE EXCEPTION 'Simulation not found' USING ERRCODE='P0002'; END IF;
 RETURN to_jsonb(s)||jsonb_build_object(
 'results',coalesce((SELECT jsonb_agg(to_jsonb(r)||jsonb_build_object('student_name',CASE WHEN u.role='ADMIN' THEN st.full_name ELSE 'Student #'||r.student_id END,'program',p.code,'institute',p.institute) ORDER BY rank_used) FROM admission.sim_result r JOIN admission.program p USING(program_id) JOIN admission.student st USING(student_id) WHERE sim_id=p_sim),'[]'::jsonb),
 'diff',coalesce((SELECT jsonb_agg(to_jsonb(d)||jsonb_build_object('student_name',CASE WHEN u.role='ADMIN' THEN st.full_name ELSE 'Student #'||d.student_id END,'base_code',b.code,'sim_code',n.code) ORDER BY d.student_id) FROM admission.sim_diff d JOIN admission.student st USING(student_id) LEFT JOIN admission.program b ON b.program_id=d.base_program LEFT JOIN admission.program n ON n.program_id=d.sim_program WHERE d.sim_id=p_sim),'[]'::jsonb));
END $$;


--
-- Name: run_mock(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.run_mock(p_year integer) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); n int; sid bigint;
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year AND NOT choices_locked AND choice_deadline>clock_timestamp();
 IF NOT FOUND THEN RAISE EXCEPTION 'Mock allotment requires an open choice window'; END IF;
 SELECT round_id INTO n FROM admission.counselling_round WHERE year=p_year AND status='CHOICES_OPEN' ORDER BY round_no LIMIT 1;
 IF n IS NULL THEN RAISE EXCEPTION 'No open round for mock allotment'; END IF;
 sid:=admission.run_allocation(n,'{"label":"Mock allotment"}',NULL,false,NULL);
 UPDATE admission.sim_run SET is_mock=true WHERE sim_id=sid;RETURN sid;
END $$;


--
-- Name: save_choices(integer, integer[], boolean); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.save_choices(p_year integer, p_programs integer[], p_lock boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT'); a admission.application; c admission.admission_cycle;
BEGIN
 SELECT * INTO c FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 SELECT * INTO a FROM admission.application WHERE student_id=u.student_id AND year=p_year FOR UPDATE;
 IF a.status<>'VERIFIED' OR a.status IS NULL THEN RAISE EXCEPTION 'Your application must be verified before choosing programs'; END IF;
 IF c.choices_locked OR c.choice_deadline<=clock_timestamp() OR a.choices_locked_at IS NOT NULL THEN RAISE EXCEPTION 'Your choices are locked'; END IF;
 IF coalesce(cardinality(p_programs),0)>30 OR EXISTS(SELECT 1 FROM unnest(p_programs) x GROUP BY x HAVING count(*)>1) THEN RAISE EXCEPTION 'Choose up to 30 distinct programs'; END IF;
 IF p_lock AND coalesce(cardinality(p_programs),0)=0 THEN RAISE EXCEPTION 'Add at least one choice before locking'; END IF;
 IF EXISTS(SELECT 1 FROM unnest(p_programs) x LEFT JOIN admission.program_eligibility e ON e.year=p_year AND e.program_id=x
   WHERE e.program_id IS NULL OR e.min_marks>(SELECT total_marks FROM admission.exam_result WHERE student_id=u.student_id AND year=p_year)) THEN RAISE EXCEPTION 'One or more programs are not eligible for this application'; END IF;
 DELETE FROM admission.choice WHERE student_id=u.student_id AND year=p_year;
 INSERT INTO admission.choice SELECT u.student_id,p_year,ord::smallint,pid FROM unnest(p_programs) WITH ORDINALITY q(pid,ord);
 IF p_lock THEN UPDATE admission.application SET choices_locked_at=clock_timestamp() WHERE student_id=u.student_id AND year=p_year; END IF;
END $$;


--
-- Name: seat_history(integer, timestamp with time zone); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.seat_history(p_year integer, p_at timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN','AUDITOR');
BEGIN
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(h)||jsonb_build_object('program',p.code) ORDER BY h.program_id,h.seat_category) FROM admission.seat_matrix_history h JOIN admission.program p USING(program_id) WHERE year=p_year AND valid @> p_at),'[]'::jsonb);
END $$;


--
-- Name: session_identity(text); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.session_identity(p_token text) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
 SELECT jsonb_build_object('user_id',u.user_id,'email',u.email,'full_name',u.full_name,'role',u.role,'student_id',u.student_id,'csrf_hash',s.csrf_hash)
 FROM admission.app_session s JOIN admission.app_user u USING(user_id)
 WHERE s.token_hash=p_token AND s.expires_at>clock_timestamp() AND u.enabled
$$;


--
-- Name: set_response_deadline(integer, timestamp with time zone); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.set_response_deadline(p_round integer, p_deadline timestamp with time zone) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); y int;
BEGIN
 SELECT year INTO y FROM admission.counselling_round WHERE round_id=p_round;
 PERFORM 1 FROM admission.admission_cycle WHERE year=y FOR UPDATE;
 IF p_deadline<=clock_timestamp() THEN RAISE EXCEPTION 'Response deadline must be in the future'; END IF;
 UPDATE admission.counselling_round SET response_deadline=p_deadline WHERE round_id=p_round AND status IN ('CHOICES_OPEN','LOCKED');
 IF NOT FOUND THEN RAISE EXCEPTION 'Only unpublished rounds can change their deadline'; END IF;
END $$;


--
-- Name: set_seats(integer, integer, admission.seat_cat, integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.set_seats(p_year integer, p_program integer, p_category admission.seat_cat, p_seats integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); c admission.admission_cycle;
BEGIN
 SELECT * INTO c FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 IF c.choices_locked THEN RAISE EXCEPTION 'Seat matrix is locked for this cycle'; END IF;
 UPDATE admission.seat_matrix SET seats=p_seats WHERE year=p_year AND program_id=p_program AND seat_category=p_category;
 IF NOT FOUND THEN RAISE EXCEPTION 'Seat pool not found'; END IF;
 UPDATE admission.admission_cycle SET input_revision=input_revision+1 WHERE year=p_year;
END $$;


--
-- Name: simulation_analysis(bigint); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.simulation_analysis(p_sim bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN','ANALYST'); result jsonb; base bigint; cutoffs jsonb; nodes jsonb; edges jsonb;
BEGIN
 result:=admission.run_details(p_sim);SELECT base_sim_id INTO base FROM admission.sim_run WHERE sim_id=p_sim;
 WITH closing AS(SELECT sim_id,program_id,seat_category,min(rank_used) opening_rank,max(rank_used) closing_rank,count(*) filled FROM admission.sim_result WHERE sim_id IN(p_sim,base) GROUP BY 1,2,3)
 SELECT coalesce(jsonb_agg(jsonb_build_object('program_id',coalesce(b.program_id,s.program_id),'program',p.code,'institute',p.institute,'seat_category',coalesce(b.seat_category,s.seat_category),
 'before',b.closing_rank,'after',s.closing_rank,'shift',s.closing_rank-b.closing_rank,'filled',s.filled) ORDER BY p.program_id,coalesce(b.seat_category,s.seat_category)),'[]'::jsonb) INTO cutoffs
 FROM(SELECT * FROM closing WHERE sim_id=base) b FULL JOIN(SELECT * FROM closing WHERE sim_id=p_sim) s USING(program_id,seat_category)
 JOIN admission.program p ON p.program_id=coalesce(b.program_id,s.program_id);
 WITH RECURSIVE moves AS(
 SELECT sim_program::text||'/'||sim_category::text source,base_program::text||'/'||base_category::text target,count(*) students
 FROM admission.sim_diff WHERE sim_id=p_sim AND change_type IN('UPGRADED','POOL_SHIFT') AND base_program IS NOT NULL GROUP BY 1,2),
 roots AS(SELECT DISTINCT (x->>'program_id')||'/'||(x->>'seat_category') pool FROM admission.sim_run,
 jsonb_array_elements(coalesce(scenario->'seat_changes','[]')) x WHERE sim_id=p_sim AND (x->>'delta')::int>0),
 walk(pool,depth) AS(SELECT pool,0 FROM roots UNION SELECT m.target,w.depth+1 FROM walk w JOIN moves m ON m.source=w.pool WHERE w.depth<12),
 levels AS(SELECT pool,min(depth) depth FROM walk GROUP BY pool)
 SELECT coalesce(jsonb_agg(jsonb_build_object('pool',pool,'depth',depth,'program',p.code,'institute',p.institute,'category',split_part(pool,'/',2)) ORDER BY depth,pool),'[]'::jsonb) INTO nodes
 FROM levels JOIN admission.program p ON p.program_id=split_part(pool,'/',1)::int;
 SELECT coalesce(jsonb_agg(to_jsonb(e)),'[]'::jsonb) INTO edges FROM(
 SELECT sim_program::text||'/'||sim_category::text source,base_program::text||'/'||base_category::text target,count(*) students
 FROM admission.sim_diff WHERE sim_id=p_sim AND change_type IN('UPGRADED','POOL_SHIFT') AND base_program IS NOT NULL GROUP BY 1,2) e;
 RETURN result||jsonb_build_object('cutoffs',cutoffs,'ripple',jsonb_build_object('nodes',nodes,'edges',edges,'method','Observed pool moves and possible vacancy links, not unique causal attribution','depth_cap',12),
 'outcomes',coalesce((SELECT jsonb_object_agg(outcome,n) FROM(SELECT outcome,count(*) n FROM admission.sim_student_outcome WHERE sim_id=p_sim GROUP BY outcome) o),'{}'::jsonb));
END $$;


--
-- Name: spot_availability(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.spot_availability(p_year integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.actor();
BEGIN
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(s)||jsonb_build_object('program',p.code,'institute',p.institute) ORDER BY pool_id) FROM admission.spot_pool s JOIN admission.program p USING(program_id) WHERE year=p_year),'[]'::jsonb);
END $$;


--
-- Name: submit_application(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.submit_application(p_year integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT');
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year AND NOT choices_locked AND choice_deadline>clock_timestamp() FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Application window is closed'; END IF;
 IF NOT EXISTS(SELECT 1 FROM admission.document_submission WHERE student_id=u.student_id AND year=p_year) THEN RAISE EXCEPTION 'Upload an exam document before submitting'; END IF;
 UPDATE admission.application SET status='SUBMITTED' WHERE student_id=u.student_id AND year=p_year AND status IN ('DRAFT','REJECTED');
 IF NOT FOUND THEN RAISE EXCEPTION 'Application cannot be submitted in its current state'; END IF;
END $$;


--
-- Name: verify_ledger(); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.verify_ledger() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN','AUDITOR'); e record; previous text:=repeat('0',64); n bigint:=0; h admission.audit_chain_head;
BEGIN
  FOR e IN SELECT * FROM admission.audit_ledger ORDER BY seq LOOP
    n:=n+1;
    IF e.seq<>n OR e.prev_hash<>previous OR (e.envelope->>'seq')::bigint<>e.seq OR
       e.hash<>encode(sha256(convert_to(previous||e.envelope::text,'UTF8')),'hex') THEN
      RETURN jsonb_build_object('valid',false,'first_invalid_seq',e.seq,'checked',n,'reason','Sequence, link or event hash mismatch');
    END IF;
    previous:=e.hash;
  END LOOP;
  SELECT * INTO h FROM admission.audit_chain_head WHERE singleton;
  RETURN jsonb_build_object('valid',h.last_seq=n AND h.last_hash=previous,'checked',n,'head_hash',previous,
    'checkpoint_note','Compare this head with a separately saved checkpoint to detect a privileged rewrite or truncated tail.');
END $$;


--
-- Name: why_not(integer); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.why_not(p_round integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT'); sid bigint;
BEGIN
 SELECT published_sim_id INTO sid FROM admission.counselling_round WHERE round_id=p_round;
 IF sid IS NULL THEN RAISE EXCEPTION 'Round is not published'; END IF;
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(t)||jsonb_build_object('program',p.code,'institute',p.institute) ORDER BY k) FROM admission.sim_trace t JOIN admission.program p USING(program_id) WHERE t.sim_id=sid AND t.student_id=u.student_id),'[]'::jsonb);
END $$;


--
-- Name: workspace(); Type: FUNCTION; Schema: admission; Owner: -
--

CREATE FUNCTION admission.workspace() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'admission', 'pg_temp'
    AS $$
DECLARE u admission.app_user:=admission.actor(); y int; result jsonb;
BEGIN
 SELECT max(year) INTO y FROM admission.admission_cycle;
 result:=jsonb_build_object(
  'user',jsonb_build_object('user_id',u.user_id,'full_name',u.full_name,'email',u.email,'role',u.role,'student_id',u.student_id),
  'year',y,'synthetic',true,
  'cycle',(SELECT to_jsonb(c) FROM admission.admission_cycle c WHERE year=y),
  'programs',coalesce((SELECT jsonb_agg(to_jsonb(p)||jsonb_build_object('seats',coalesce((SELECT jsonb_agg(to_jsonb(m) ORDER BY seat_category) FROM admission.seat_matrix m WHERE m.program_id=p.program_id AND m.year=y),'[]'::jsonb)) ORDER BY p.program_id) FROM admission.program p),'[]'::jsonb),
  'rounds',coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY round_no) FROM admission.counselling_round r WHERE year=y),'[]'::jsonb));
 IF u.role='STUDENT' THEN
  result:=result||jsonb_build_object(
   'application',(SELECT to_jsonb(a)||jsonb_build_object('crl_rank',e.crl_rank,'cat_rank',e.cat_rank,'total_marks',e.total_marks) FROM admission.application a LEFT JOIN admission.exam_result e USING(student_id,year) WHERE a.student_id=u.student_id AND a.year=y),
   'choices',coalesce((SELECT jsonb_agg(program_id ORDER BY pref_order) FROM admission.choice WHERE student_id=u.student_id AND year=y),'[]'::jsonb),
   'documents',coalesce((SELECT jsonb_agg(to_jsonb(d)-'storage_key' ORDER BY document_id) FROM admission.document_submission d WHERE student_id=u.student_id AND year=y),'[]'::jsonb),
   'allocations',coalesce((SELECT jsonb_agg(to_jsonb(a)||jsonb_build_object('decision',s.decision) ORDER BY a.round_id) FROM admission.allocation a LEFT JOIN admission.student_response s USING(round_id,student_id) WHERE a.student_id=u.student_id),'[]'::jsonb));
 ELSIF u.role='ADMIN' THEN
  result:=result||jsonb_build_object('applications',coalesce((SELECT jsonb_agg(to_jsonb(a)||jsonb_build_object('full_name',s.full_name,'crl_rank',e.crl_rank,'documents',coalesce((SELECT jsonb_agg(to_jsonb(d)-'storage_key') FROM admission.document_submission d WHERE d.student_id=a.student_id AND d.year=a.year),'[]'::jsonb)) ORDER BY e.crl_rank NULLS LAST) FROM admission.application a JOIN admission.student s USING(student_id) LEFT JOIN admission.exam_result e USING(student_id,year) WHERE a.year=y),'[]'::jsonb));
 END IF;
 IF u.role IN ('ADMIN','ANALYST') THEN
  result:=result||jsonb_build_object('simulations',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY sim_id DESC) FROM (SELECT * FROM admission.sim_run ORDER BY sim_id DESC LIMIT 30) s),'[]'::jsonb));
 END IF;
 RETURN result;
END $$;


--
-- Name: admission_cycle; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.admission_cycle (
    year integer NOT NULL,
    input_revision bigint DEFAULT 0 NOT NULL,
    choices_locked boolean DEFAULT false NOT NULL,
    choice_deadline timestamp with time zone NOT NULL,
    policy_version text DEFAULT 'academic-fixed-pools-v1'::text NOT NULL,
    CONSTRAINT admission_cycle_year_check CHECK (((year >= 2020) AND (year <= 2100)))
);


--
-- Name: allocation; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.allocation (
    round_id integer NOT NULL,
    student_id bigint NOT NULL,
    program_id integer NOT NULL,
    seat_category admission.seat_cat NOT NULL,
    pref_order integer NOT NULL,
    k integer NOT NULL,
    rank_used integer NOT NULL,
    CONSTRAINT allocation_k_check CHECK ((k > 0)),
    CONSTRAINT allocation_pref_order_check CHECK ((pref_order > 0)),
    CONSTRAINT allocation_rank_used_check CHECK ((rank_used > 0))
);


--
-- Name: counselling_round; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.counselling_round (
    round_id integer NOT NULL,
    year integer NOT NULL,
    round_no integer NOT NULL,
    status text DEFAULT 'CHOICES_OPEN'::text NOT NULL,
    response_deadline timestamp with time zone NOT NULL,
    published_at timestamp with time zone,
    published_sim_id bigint,
    publish_key text,
    CONSTRAINT counselling_round_round_no_check CHECK ((round_no > 0)),
    CONSTRAINT counselling_round_status_check CHECK ((status = ANY (ARRAY['CHOICES_OPEN'::text, 'LOCKED'::text, 'PUBLISHED'::text, 'CLOSED'::text])))
);


--
-- Name: sim_trace; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.sim_trace (
    sim_id bigint NOT NULL,
    student_id bigint NOT NULL,
    program_id integer,
    seat_category admission.seat_cat,
    pref_order integer NOT NULL,
    k integer NOT NULL,
    rank_used integer NOT NULL,
    closing_rank integer,
    outcome text NOT NULL,
    CONSTRAINT sim_trace_outcome_check CHECK ((outcome = ANY (ARRAY['ALLOTTED'::text, 'REJECTED_FULL'::text, 'NOT_REACHED'::text, 'RETAINED'::text])))
);


--
-- Name: allocation_trace; Type: VIEW; Schema: admission; Owner: -
--

CREATE VIEW admission.allocation_trace AS
 SELECT cr.round_id,
    t.sim_id,
    t.student_id,
    t.program_id,
    t.seat_category,
    t.pref_order,
    t.k,
    t.rank_used,
    t.closing_rank,
    t.outcome
   FROM (admission.sim_trace t
     JOIN admission.counselling_round cr ON ((cr.published_sim_id = t.sim_id)));


--
-- Name: app_session; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.app_session (
    token_hash text NOT NULL,
    user_id bigint NOT NULL,
    csrf_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


--
-- Name: app_user_user_id_seq; Type: SEQUENCE; Schema: admission; Owner: -
--

ALTER TABLE admission.app_user ALTER COLUMN user_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME admission.app_user_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: application; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.application (
    student_id bigint NOT NULL,
    year integer NOT NULL,
    admission_category admission.seat_cat DEFAULT 'OPEN'::admission.seat_cat NOT NULL,
    status text DEFAULT 'DRAFT'::text NOT NULL,
    choices_locked_at timestamp with time zone,
    review_reason text,
    CONSTRAINT application_status_check CHECK ((status = ANY (ARRAY['DRAFT'::text, 'SUBMITTED'::text, 'VERIFIED'::text, 'REJECTED'::text, 'WITHDRAWN'::text])))
);


--
-- Name: audit_chain_head; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.audit_chain_head (
    singleton boolean DEFAULT true NOT NULL,
    last_seq bigint DEFAULT 0 NOT NULL,
    last_hash text DEFAULT repeat('0'::text, 64) NOT NULL,
    CONSTRAINT audit_chain_head_singleton_check CHECK (singleton)
);


--
-- Name: audit_ledger; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.audit_ledger (
    seq bigint NOT NULL,
    envelope jsonb NOT NULL,
    prev_hash text NOT NULL,
    hash text NOT NULL
);


--
-- Name: choice; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.choice (
    student_id bigint NOT NULL,
    year integer NOT NULL,
    pref_order smallint NOT NULL,
    program_id integer NOT NULL,
    CONSTRAINT choice_pref_order_check CHECK (((pref_order >= 1) AND (pref_order <= 30)))
);


--
-- Name: counselling_round_round_id_seq; Type: SEQUENCE; Schema: admission; Owner: -
--

ALTER TABLE admission.counselling_round ALTER COLUMN round_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME admission.counselling_round_round_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: document_submission; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.document_submission (
    document_id bigint NOT NULL,
    student_id bigint,
    year integer,
    original_name text NOT NULL,
    storage_key text NOT NULL,
    mime_type text NOT NULL,
    checksum text NOT NULL,
    byte_count integer NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    reason text,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT document_submission_byte_count_check CHECK (((byte_count >= 1) AND (byte_count <= 5242880))),
    CONSTRAINT document_submission_status_check CHECK ((status = ANY (ARRAY['PENDING'::text, 'VERIFIED'::text, 'REJECTED'::text])))
);


--
-- Name: document_submission_document_id_seq; Type: SEQUENCE; Schema: admission; Owner: -
--

ALTER TABLE admission.document_submission ALTER COLUMN document_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME admission.document_submission_document_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: exam_result; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.exam_result (
    student_id bigint NOT NULL,
    year integer NOT NULL,
    total_marks numeric NOT NULL,
    crl_rank integer NOT NULL,
    cat_rank integer,
    maths numeric,
    physics numeric,
    chemistry numeric,
    CONSTRAINT exam_result_cat_rank_check CHECK ((cat_rank > 0)),
    CONSTRAINT exam_result_chemistry_check CHECK (((chemistry >= (0)::numeric) AND (chemistry <= (100)::numeric))),
    CONSTRAINT exam_result_crl_rank_check CHECK ((crl_rank > 0)),
    CONSTRAINT exam_result_maths_check CHECK (((maths >= (0)::numeric) AND (maths <= (100)::numeric))),
    CONSTRAINT exam_result_physics_check CHECK (((physics >= (0)::numeric) AND (physics <= (100)::numeric))),
    CONSTRAINT exam_result_total_marks_check CHECK (((total_marks >= (0)::numeric) AND (total_marks <= (300)::numeric))),
    CONSTRAINT subject_marks_total CHECK (((maths IS NULL) OR (physics IS NULL) OR (chemistry IS NULL) OR (total_marks = ((maths + physics) + chemistry))))
);


--
-- Name: final_admission; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.final_admission (
    year integer NOT NULL,
    student_id bigint NOT NULL,
    confirmed_by bigint NOT NULL,
    confirmed_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL
);


--
-- Name: hist_closing; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.hist_closing (
    year integer NOT NULL,
    program_id integer NOT NULL,
    seat_category admission.seat_cat NOT NULL,
    closing_rank integer NOT NULL,
    source text DEFAULT 'synthetic'::text NOT NULL,
    round_no integer DEFAULT 1 NOT NULL,
    opening_rank integer DEFAULT 1 NOT NULL,
    CONSTRAINT hist_closing_check CHECK (((opening_rank > 0) AND (opening_rank <= closing_rank))),
    CONSTRAINT hist_closing_closing_rank_check CHECK ((closing_rank > 0)),
    CONSTRAINT hist_closing_round_no_check CHECK ((round_no > 0))
);


--
-- Name: job_run; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.job_run (
    job_id bigint NOT NULL,
    job_name text NOT NULL,
    year integer NOT NULL,
    slot text NOT NULL,
    status text NOT NULL,
    started_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    completed_at timestamp with time zone,
    sim_id bigint,
    message text,
    CONSTRAINT job_run_status_check CHECK ((status = ANY (ARRAY['RUNNING'::text, 'SUCCEEDED'::text, 'FAILED'::text, 'SKIPPED'::text])))
);


--
-- Name: job_run_job_id_seq; Type: SEQUENCE; Schema: admission; Owner: -
--

ALTER TABLE admission.job_run ALTER COLUMN job_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME admission.job_run_job_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: login_attempt; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.login_attempt (
    ip_hash text NOT NULL,
    email_hash text NOT NULL,
    at timestamp with time zone DEFAULT clock_timestamp() NOT NULL
);


--
-- Name: mv_cutoff_trend; Type: MATERIALIZED VIEW; Schema: admission; Owner: -
--

CREATE MATERIALIZED VIEW admission.mv_cutoff_trend AS
 WITH final AS (
         SELECT DISTINCT ON (hist_closing.year, hist_closing.program_id, hist_closing.seat_category) hist_closing.year,
            hist_closing.program_id,
            hist_closing.seat_category,
            hist_closing.closing_rank,
            hist_closing.source,
            hist_closing.round_no,
            hist_closing.opening_rank
           FROM admission.hist_closing
          ORDER BY hist_closing.year, hist_closing.program_id, hist_closing.seat_category, hist_closing.round_no DESC
        ), drift AS (
         SELECT hist_closing.year,
            hist_closing.program_id,
            hist_closing.seat_category,
            hist_closing.closing_rank,
            first_value(hist_closing.closing_rank) OVER (PARTITION BY hist_closing.year, hist_closing.program_id, hist_closing.seat_category ORDER BY hist_closing.round_no) AS first_close,
            row_number() OVER (PARTITION BY hist_closing.year, hist_closing.program_id, hist_closing.seat_category ORDER BY hist_closing.round_no DESC) AS n
           FROM admission.hist_closing
        )
 SELECT cycle.year AS prediction_year,
    f.program_id,
    f.seat_category,
    count(*) AS years_of_data,
    min(f.closing_rank) AS toughest_close,
    max(f.closing_rank) AS easiest_close,
    (GREATEST((1)::double precision, LEAST((2147483647)::double precision, round(COALESCE((regr_intercept((f.closing_rank)::double precision, (f.year)::double precision) + (regr_slope((f.closing_rank)::double precision, (f.year)::double precision) * (cycle.year)::double precision)), (avg(f.closing_rank))::double precision)))))::integer AS projected_close,
    bool_and((f.source = 'synthetic'::text)) AS synthetic,
    ( SELECT round(avg(((100.0 * ((d.closing_rank - d.first_close))::numeric) / (NULLIF(d.first_close, 0))::numeric)), 2) AS round
           FROM drift d
          WHERE ((d.n = 1) AND (d.year < cycle.year) AND (d.program_id = f.program_id) AND (d.seat_category = f.seat_category))) AS drift_percent
   FROM (admission.admission_cycle cycle
     JOIN final f ON ((f.year < cycle.year)))
  GROUP BY cycle.year, f.program_id, f.seat_category
  WITH NO DATA;


--
-- Name: prediction_state; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.prediction_state (
    year integer NOT NULL,
    refreshed_at timestamp with time zone,
    stale boolean DEFAULT true NOT NULL,
    error text,
    rules_version text DEFAULT 'historic-bands-v1'::text NOT NULL
);


--
-- Name: program; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.program (
    program_id integer NOT NULL,
    institute text NOT NULL,
    code text NOT NULL,
    name text NOT NULL
);


--
-- Name: program_eligibility; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.program_eligibility (
    year integer NOT NULL,
    program_id integer NOT NULL,
    min_marks numeric DEFAULT 0 NOT NULL,
    CONSTRAINT program_eligibility_min_marks_check CHECK (((min_marks >= (0)::numeric) AND (min_marks <= (300)::numeric)))
);


--
-- Name: program_program_id_seq; Type: SEQUENCE; Schema: admission; Owner: -
--

ALTER TABLE admission.program ALTER COLUMN program_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME admission.program_program_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: seat_holding; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.seat_holding (
    year integer NOT NULL,
    student_id bigint NOT NULL,
    program_id integer NOT NULL,
    seat_category admission.seat_cat NOT NULL,
    source text NOT NULL,
    final boolean DEFAULT false NOT NULL,
    CONSTRAINT seat_holding_source_check CHECK ((source = ANY (ARRAY['ROUND'::text, 'SPOT'::text])))
);


--
-- Name: seat_matrix; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.seat_matrix (
    year integer NOT NULL,
    program_id integer NOT NULL,
    seat_category admission.seat_cat NOT NULL,
    seats integer NOT NULL,
    CONSTRAINT seat_matrix_seats_check CHECK (((seats >= 0) AND (seats <= 10000)))
);


--
-- Name: seat_matrix_history; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.seat_matrix_history (
    history_id bigint NOT NULL,
    year integer NOT NULL,
    program_id integer NOT NULL,
    seat_category admission.seat_cat NOT NULL,
    seats integer NOT NULL,
    valid tstzrange NOT NULL,
    CONSTRAINT seat_matrix_history_valid_check CHECK ((NOT isempty(valid)))
);


--
-- Name: seat_matrix_history_history_id_seq; Type: SEQUENCE; Schema: admission; Owner: -
--

ALTER TABLE admission.seat_matrix_history ALTER COLUMN history_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME admission.seat_matrix_history_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sim_diff; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.sim_diff (
    sim_id bigint NOT NULL,
    student_id bigint NOT NULL,
    base_program integer,
    sim_program integer,
    base_category admission.seat_cat,
    sim_category admission.seat_cat,
    base_k integer,
    sim_k integer,
    change_type text NOT NULL,
    CONSTRAINT sim_diff_change_type_check CHECK ((change_type = ANY (ARRAY['UNCHANGED'::text, 'NEW_SEAT'::text, 'LOST_SEAT'::text, 'POOL_SHIFT'::text, 'UPGRADED'::text, 'DOWNGRADED'::text])))
);


--
-- Name: sim_input_snapshot; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.sim_input_snapshot (
    snapshot_id bigint NOT NULL,
    year integer NOT NULL,
    round_id integer NOT NULL,
    source_revision bigint NOT NULL,
    captured_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    policy_version text NOT NULL,
    engine_version text DEFAULT 'da-sql-v1'::text NOT NULL,
    payload jsonb NOT NULL,
    payload_hash text NOT NULL
);


--
-- Name: sim_input_snapshot_snapshot_id_seq; Type: SEQUENCE; Schema: admission; Owner: -
--

ALTER TABLE admission.sim_input_snapshot ALTER COLUMN snapshot_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME admission.sim_input_snapshot_snapshot_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sim_result; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.sim_result (
    sim_id bigint NOT NULL,
    student_id bigint NOT NULL,
    program_id integer NOT NULL,
    seat_category admission.seat_cat NOT NULL,
    pref_order integer NOT NULL,
    k integer NOT NULL,
    rank_used integer NOT NULL
);


--
-- Name: sim_run; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.sim_run (
    sim_id bigint NOT NULL,
    round_id integer NOT NULL,
    snapshot_id bigint NOT NULL,
    base_sim_id bigint,
    run_by bigint NOT NULL,
    scenario jsonb NOT NULL,
    label text NOT NULL,
    started_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    duration_ms integer DEFAULT 0 NOT NULL,
    is_published boolean DEFAULT false NOT NULL,
    checks jsonb DEFAULT '{}'::jsonb NOT NULL,
    summary jsonb DEFAULT '{}'::jsonb NOT NULL,
    is_mock boolean DEFAULT false NOT NULL,
    pinned boolean DEFAULT false NOT NULL
);


--
-- Name: sim_run_sim_id_seq; Type: SEQUENCE; Schema: admission; Owner: -
--

ALTER TABLE admission.sim_run ALTER COLUMN sim_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME admission.sim_run_sim_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sim_student_outcome; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.sim_student_outcome (
    sim_id bigint NOT NULL,
    student_id bigint NOT NULL,
    outcome text NOT NULL,
    reason_code text,
    CONSTRAINT sim_student_outcome_outcome_check CHECK ((outcome = ANY (ARRAY['ALLOTTED'::text, 'UNASSIGNED'::text, 'WITHDRAWN'::text, 'EXCLUDED'::text])))
);


--
-- Name: spot_acceptance; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.spot_acceptance (
    acceptance_id bigint NOT NULL,
    pool_id bigint NOT NULL,
    student_id bigint NOT NULL,
    year integer NOT NULL,
    idempotency_key text NOT NULL,
    accepted_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL
);


--
-- Name: spot_acceptance_acceptance_id_seq; Type: SEQUENCE; Schema: admission; Owner: -
--

ALTER TABLE admission.spot_acceptance ALTER COLUMN acceptance_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME admission.spot_acceptance_acceptance_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: spot_pool; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.spot_pool (
    pool_id bigint NOT NULL,
    year integer,
    program_id integer,
    seat_category admission.seat_cat,
    initial_capacity integer NOT NULL,
    seats_left integer NOT NULL,
    status text DEFAULT 'OPEN'::text NOT NULL,
    CONSTRAINT spot_pool_check CHECK (((seats_left >= 0) AND (seats_left <= initial_capacity))),
    CONSTRAINT spot_pool_initial_capacity_check CHECK ((initial_capacity >= 0)),
    CONSTRAINT spot_pool_status_check CHECK ((status = ANY (ARRAY['OPEN'::text, 'CLOSED'::text])))
);


--
-- Name: spot_pool_pool_id_seq; Type: SEQUENCE; Schema: admission; Owner: -
--

ALTER TABLE admission.spot_pool ALTER COLUMN pool_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME admission.spot_pool_pool_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: student; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.student (
    student_id bigint NOT NULL,
    full_name text NOT NULL,
    dob date,
    CONSTRAINT student_full_name_check CHECK (((length(full_name) >= 2) AND (length(full_name) <= 100)))
);


--
-- Name: student_response; Type: TABLE; Schema: admission; Owner: -
--

CREATE TABLE admission.student_response (
    round_id integer NOT NULL,
    student_id bigint NOT NULL,
    decision text NOT NULL,
    responded_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    CONSTRAINT student_response_decision_check CHECK ((decision = ANY (ARRAY['FREEZE'::text, 'FLOAT'::text, 'SLIDE'::text, 'WITHDRAW'::text])))
);


--
-- Name: student_student_id_seq; Type: SEQUENCE; Schema: admission; Owner: -
--

ALTER TABLE admission.student ALTER COLUMN student_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME admission.student_student_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: schema_migration; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migration (
    name text NOT NULL,
    checksum text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: admission_cycle admission_cycle_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.admission_cycle
    ADD CONSTRAINT admission_cycle_pkey PRIMARY KEY (year);


--
-- Name: allocation allocation_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.allocation
    ADD CONSTRAINT allocation_pkey PRIMARY KEY (round_id, student_id);


--
-- Name: app_session app_session_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.app_session
    ADD CONSTRAINT app_session_pkey PRIMARY KEY (token_hash);


--
-- Name: app_user app_user_email_key; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.app_user
    ADD CONSTRAINT app_user_email_key UNIQUE (email);


--
-- Name: app_user app_user_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.app_user
    ADD CONSTRAINT app_user_pkey PRIMARY KEY (user_id);


--
-- Name: app_user app_user_student_id_key; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.app_user
    ADD CONSTRAINT app_user_student_id_key UNIQUE (student_id);


--
-- Name: application application_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.application
    ADD CONSTRAINT application_pkey PRIMARY KEY (student_id, year);


--
-- Name: audit_chain_head audit_chain_head_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.audit_chain_head
    ADD CONSTRAINT audit_chain_head_pkey PRIMARY KEY (singleton);


--
-- Name: audit_ledger audit_ledger_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.audit_ledger
    ADD CONSTRAINT audit_ledger_pkey PRIMARY KEY (seq);


--
-- Name: choice choice_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.choice
    ADD CONSTRAINT choice_pkey PRIMARY KEY (student_id, year, pref_order);


--
-- Name: choice choice_student_id_year_program_id_key; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.choice
    ADD CONSTRAINT choice_student_id_year_program_id_key UNIQUE (student_id, year, program_id);


--
-- Name: counselling_round counselling_round_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.counselling_round
    ADD CONSTRAINT counselling_round_pkey PRIMARY KEY (round_id);


--
-- Name: counselling_round counselling_round_published_sim_id_key; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.counselling_round
    ADD CONSTRAINT counselling_round_published_sim_id_key UNIQUE (published_sim_id);


--
-- Name: counselling_round counselling_round_year_round_no_key; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.counselling_round
    ADD CONSTRAINT counselling_round_year_round_no_key UNIQUE (year, round_no);


--
-- Name: document_submission document_submission_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.document_submission
    ADD CONSTRAINT document_submission_pkey PRIMARY KEY (document_id);


--
-- Name: document_submission document_submission_storage_key_key; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.document_submission
    ADD CONSTRAINT document_submission_storage_key_key UNIQUE (storage_key);


--
-- Name: exam_result exam_result_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.exam_result
    ADD CONSTRAINT exam_result_pkey PRIMARY KEY (student_id, year);


--
-- Name: exam_result exam_result_year_crl_rank_key; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.exam_result
    ADD CONSTRAINT exam_result_year_crl_rank_key UNIQUE (year, crl_rank) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: final_admission final_admission_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.final_admission
    ADD CONSTRAINT final_admission_pkey PRIMARY KEY (year, student_id);


--
-- Name: hist_closing hist_closing_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.hist_closing
    ADD CONSTRAINT hist_closing_pkey PRIMARY KEY (year, round_no, program_id, seat_category);


--
-- Name: job_run job_run_job_name_year_slot_key; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.job_run
    ADD CONSTRAINT job_run_job_name_year_slot_key UNIQUE (job_name, year, slot);


--
-- Name: job_run job_run_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.job_run
    ADD CONSTRAINT job_run_pkey PRIMARY KEY (job_id);


--
-- Name: prediction_state prediction_state_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.prediction_state
    ADD CONSTRAINT prediction_state_pkey PRIMARY KEY (year);


--
-- Name: program_eligibility program_eligibility_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.program_eligibility
    ADD CONSTRAINT program_eligibility_pkey PRIMARY KEY (year, program_id);


--
-- Name: program program_institute_code_key; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.program
    ADD CONSTRAINT program_institute_code_key UNIQUE (institute, code);


--
-- Name: program program_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.program
    ADD CONSTRAINT program_pkey PRIMARY KEY (program_id);


--
-- Name: seat_holding seat_holding_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.seat_holding
    ADD CONSTRAINT seat_holding_pkey PRIMARY KEY (year, student_id);


--
-- Name: seat_matrix_history seat_matrix_history_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.seat_matrix_history
    ADD CONSTRAINT seat_matrix_history_pkey PRIMARY KEY (history_id);


--
-- Name: seat_matrix_history seat_matrix_history_year_program_id_seat_category_valid_excl; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.seat_matrix_history
    ADD CONSTRAINT seat_matrix_history_year_program_id_seat_category_valid_excl EXCLUDE USING gist (year WITH =, program_id WITH =, seat_category WITH =, valid WITH &&);


--
-- Name: seat_matrix seat_matrix_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.seat_matrix
    ADD CONSTRAINT seat_matrix_pkey PRIMARY KEY (year, program_id, seat_category);


--
-- Name: sim_diff sim_diff_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_diff
    ADD CONSTRAINT sim_diff_pkey PRIMARY KEY (sim_id, student_id);


--
-- Name: sim_input_snapshot sim_input_snapshot_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_input_snapshot
    ADD CONSTRAINT sim_input_snapshot_pkey PRIMARY KEY (snapshot_id);


--
-- Name: sim_result sim_result_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_result
    ADD CONSTRAINT sim_result_pkey PRIMARY KEY (sim_id, student_id);


--
-- Name: sim_run sim_run_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_run
    ADD CONSTRAINT sim_run_pkey PRIMARY KEY (sim_id);


--
-- Name: sim_student_outcome sim_student_outcome_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_student_outcome
    ADD CONSTRAINT sim_student_outcome_pkey PRIMARY KEY (sim_id, student_id);


--
-- Name: sim_trace sim_trace_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_trace
    ADD CONSTRAINT sim_trace_pkey PRIMARY KEY (sim_id, student_id, k);


--
-- Name: spot_acceptance spot_acceptance_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.spot_acceptance
    ADD CONSTRAINT spot_acceptance_pkey PRIMARY KEY (acceptance_id);


--
-- Name: spot_acceptance spot_acceptance_student_id_idempotency_key_key; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.spot_acceptance
    ADD CONSTRAINT spot_acceptance_student_id_idempotency_key_key UNIQUE (student_id, idempotency_key);


--
-- Name: spot_acceptance spot_acceptance_year_student_id_key; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.spot_acceptance
    ADD CONSTRAINT spot_acceptance_year_student_id_key UNIQUE (year, student_id);


--
-- Name: spot_pool spot_pool_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.spot_pool
    ADD CONSTRAINT spot_pool_pkey PRIMARY KEY (pool_id);


--
-- Name: spot_pool spot_pool_year_program_id_seat_category_key; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.spot_pool
    ADD CONSTRAINT spot_pool_year_program_id_seat_category_key UNIQUE (year, program_id, seat_category);


--
-- Name: student student_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.student
    ADD CONSTRAINT student_pkey PRIMARY KEY (student_id);


--
-- Name: student_response student_response_pkey; Type: CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.student_response
    ADD CONSTRAINT student_response_pkey PRIMARY KEY (round_id, student_id);


--
-- Name: schema_migration schema_migration_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migration
    ADD CONSTRAINT schema_migration_pkey PRIMARY KEY (name);


--
-- Name: allocation_round_id_program_id_seat_category_rank_used_idx; Type: INDEX; Schema: admission; Owner: -
--

CREATE INDEX allocation_round_id_program_id_seat_category_rank_used_idx ON admission.allocation USING btree (round_id, program_id, seat_category, rank_used);


--
-- Name: app_session_expires_at_idx; Type: INDEX; Schema: admission; Owner: -
--

CREATE INDEX app_session_expires_at_idx ON admission.app_session USING btree (expires_at);


--
-- Name: application_year_status_idx; Type: INDEX; Schema: admission; Owner: -
--

CREATE INDEX application_year_status_idx ON admission.application USING btree (year, status);


--
-- Name: audit_ledger_expr_idx; Type: INDEX; Schema: admission; Owner: -
--

CREATE INDEX audit_ledger_expr_idx ON admission.audit_ledger USING btree (((envelope ->> 'entity'::text)));


--
-- Name: document_submission_student_id_year_status_idx; Type: INDEX; Schema: admission; Owner: -
--

CREATE INDEX document_submission_student_id_year_status_idx ON admission.document_submission USING btree (student_id, year, status);


--
-- Name: login_attempt_email_hash_at_idx; Type: INDEX; Schema: admission; Owner: -
--

CREATE INDEX login_attempt_email_hash_at_idx ON admission.login_attempt USING btree (email_hash, at);


--
-- Name: login_attempt_ip_hash_at_idx; Type: INDEX; Schema: admission; Owner: -
--

CREATE INDEX login_attempt_ip_hash_at_idx ON admission.login_attempt USING btree (ip_hash, at);


--
-- Name: mv_cutoff_trend_prediction_year_program_id_seat_category_idx; Type: INDEX; Schema: admission; Owner: -
--

CREATE UNIQUE INDEX mv_cutoff_trend_prediction_year_program_id_seat_category_idx ON admission.mv_cutoff_trend USING btree (prediction_year, program_id, seat_category);


--
-- Name: sim_diff_sim_id_change_type_idx; Type: INDEX; Schema: admission; Owner: -
--

CREATE INDEX sim_diff_sim_id_change_type_idx ON admission.sim_diff USING btree (sim_id, change_type);


--
-- Name: sim_result_sim_id_program_id_seat_category_rank_used_idx; Type: INDEX; Schema: admission; Owner: -
--

CREATE INDEX sim_result_sim_id_program_id_seat_category_rank_used_idx ON admission.sim_result USING btree (sim_id, program_id, seat_category, rank_used);


--
-- Name: sim_run_started_at_idx; Type: INDEX; Schema: admission; Owner: -
--

CREATE INDEX sim_run_started_at_idx ON admission.sim_run USING btree (started_at);


--
-- Name: allocation audit_row; Type: TRIGGER; Schema: admission; Owner: -
--

CREATE TRIGGER audit_row AFTER INSERT OR DELETE OR UPDATE ON admission.allocation FOR EACH ROW EXECUTE FUNCTION admission.audit_change();


--
-- Name: application audit_row; Type: TRIGGER; Schema: admission; Owner: -
--

CREATE TRIGGER audit_row AFTER INSERT OR DELETE OR UPDATE ON admission.application FOR EACH ROW EXECUTE FUNCTION admission.audit_change();


--
-- Name: choice audit_row; Type: TRIGGER; Schema: admission; Owner: -
--

CREATE TRIGGER audit_row AFTER INSERT OR DELETE OR UPDATE ON admission.choice FOR EACH ROW EXECUTE FUNCTION admission.audit_change();


--
-- Name: counselling_round audit_row; Type: TRIGGER; Schema: admission; Owner: -
--

CREATE TRIGGER audit_row AFTER INSERT OR DELETE OR UPDATE ON admission.counselling_round FOR EACH ROW EXECUTE FUNCTION admission.audit_change();


--
-- Name: document_submission audit_row; Type: TRIGGER; Schema: admission; Owner: -
--

CREATE TRIGGER audit_row AFTER INSERT OR DELETE OR UPDATE ON admission.document_submission FOR EACH ROW EXECUTE FUNCTION admission.audit_change();


--
-- Name: exam_result audit_row; Type: TRIGGER; Schema: admission; Owner: -
--

CREATE TRIGGER audit_row AFTER INSERT OR DELETE OR UPDATE ON admission.exam_result FOR EACH ROW EXECUTE FUNCTION admission.audit_change();


--
-- Name: seat_holding audit_row; Type: TRIGGER; Schema: admission; Owner: -
--

CREATE TRIGGER audit_row AFTER INSERT OR DELETE OR UPDATE ON admission.seat_holding FOR EACH ROW EXECUTE FUNCTION admission.audit_change();


--
-- Name: seat_matrix audit_row; Type: TRIGGER; Schema: admission; Owner: -
--

CREATE TRIGGER audit_row AFTER INSERT OR DELETE OR UPDATE ON admission.seat_matrix FOR EACH ROW EXECUTE FUNCTION admission.audit_change();


--
-- Name: spot_acceptance audit_row; Type: TRIGGER; Schema: admission; Owner: -
--

CREATE TRIGGER audit_row AFTER INSERT OR DELETE OR UPDATE ON admission.spot_acceptance FOR EACH ROW EXECUTE FUNCTION admission.audit_change();


--
-- Name: student_response audit_row; Type: TRIGGER; Schema: admission; Owner: -
--

CREATE TRIGGER audit_row AFTER INSERT OR DELETE OR UPDATE ON admission.student_response FOR EACH ROW EXECUTE FUNCTION admission.audit_change();


--
-- Name: choice choices_guard; Type: TRIGGER; Schema: admission; Owner: -
--

CREATE TRIGGER choices_guard BEFORE INSERT OR DELETE OR UPDATE ON admission.choice FOR EACH ROW EXECUTE FUNCTION admission.guard_choices();


--
-- Name: seat_matrix matrix_history; Type: TRIGGER; Schema: admission; Owner: -
--

CREATE TRIGGER matrix_history AFTER INSERT OR DELETE OR UPDATE ON admission.seat_matrix FOR EACH ROW EXECUTE FUNCTION admission.history_change();


--
-- Name: allocation allocation_program_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.allocation
    ADD CONSTRAINT allocation_program_id_fkey FOREIGN KEY (program_id) REFERENCES admission.program(program_id);


--
-- Name: allocation allocation_round_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.allocation
    ADD CONSTRAINT allocation_round_id_fkey FOREIGN KEY (round_id) REFERENCES admission.counselling_round(round_id);


--
-- Name: allocation allocation_student_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.allocation
    ADD CONSTRAINT allocation_student_id_fkey FOREIGN KEY (student_id) REFERENCES admission.student(student_id);


--
-- Name: app_session app_session_user_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.app_session
    ADD CONSTRAINT app_session_user_id_fkey FOREIGN KEY (user_id) REFERENCES admission.app_user(user_id);


--
-- Name: app_user app_user_student_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.app_user
    ADD CONSTRAINT app_user_student_id_fkey FOREIGN KEY (student_id) REFERENCES admission.student(student_id);


--
-- Name: application application_student_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.application
    ADD CONSTRAINT application_student_id_fkey FOREIGN KEY (student_id) REFERENCES admission.student(student_id);


--
-- Name: application application_year_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.application
    ADD CONSTRAINT application_year_fkey FOREIGN KEY (year) REFERENCES admission.admission_cycle(year);


--
-- Name: choice choice_program_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.choice
    ADD CONSTRAINT choice_program_id_fkey FOREIGN KEY (program_id) REFERENCES admission.program(program_id);


--
-- Name: choice choice_student_id_year_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.choice
    ADD CONSTRAINT choice_student_id_year_fkey FOREIGN KEY (student_id, year) REFERENCES admission.exam_result(student_id, year);


--
-- Name: counselling_round counselling_round_published_sim_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.counselling_round
    ADD CONSTRAINT counselling_round_published_sim_id_fkey FOREIGN KEY (published_sim_id) REFERENCES admission.sim_run(sim_id);


--
-- Name: counselling_round counselling_round_year_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.counselling_round
    ADD CONSTRAINT counselling_round_year_fkey FOREIGN KEY (year) REFERENCES admission.admission_cycle(year);


--
-- Name: document_submission document_submission_student_id_year_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.document_submission
    ADD CONSTRAINT document_submission_student_id_year_fkey FOREIGN KEY (student_id, year) REFERENCES admission.application(student_id, year);


--
-- Name: exam_result exam_result_student_id_year_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.exam_result
    ADD CONSTRAINT exam_result_student_id_year_fkey FOREIGN KEY (student_id, year) REFERENCES admission.application(student_id, year);


--
-- Name: final_admission final_admission_confirmed_by_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.final_admission
    ADD CONSTRAINT final_admission_confirmed_by_fkey FOREIGN KEY (confirmed_by) REFERENCES admission.app_user(user_id);


--
-- Name: final_admission final_admission_year_student_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.final_admission
    ADD CONSTRAINT final_admission_year_student_id_fkey FOREIGN KEY (year, student_id) REFERENCES admission.seat_holding(year, student_id);


--
-- Name: hist_closing hist_closing_program_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.hist_closing
    ADD CONSTRAINT hist_closing_program_id_fkey FOREIGN KEY (program_id) REFERENCES admission.program(program_id);


--
-- Name: job_run job_run_sim_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.job_run
    ADD CONSTRAINT job_run_sim_id_fkey FOREIGN KEY (sim_id) REFERENCES admission.sim_run(sim_id) ON DELETE SET NULL;


--
-- Name: job_run job_run_year_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.job_run
    ADD CONSTRAINT job_run_year_fkey FOREIGN KEY (year) REFERENCES admission.admission_cycle(year);


--
-- Name: prediction_state prediction_state_year_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.prediction_state
    ADD CONSTRAINT prediction_state_year_fkey FOREIGN KEY (year) REFERENCES admission.admission_cycle(year);


--
-- Name: program_eligibility program_eligibility_program_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.program_eligibility
    ADD CONSTRAINT program_eligibility_program_id_fkey FOREIGN KEY (program_id) REFERENCES admission.program(program_id);


--
-- Name: program_eligibility program_eligibility_year_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.program_eligibility
    ADD CONSTRAINT program_eligibility_year_fkey FOREIGN KEY (year) REFERENCES admission.admission_cycle(year);


--
-- Name: seat_holding seat_holding_program_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.seat_holding
    ADD CONSTRAINT seat_holding_program_id_fkey FOREIGN KEY (program_id) REFERENCES admission.program(program_id);


--
-- Name: seat_holding seat_holding_student_id_year_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.seat_holding
    ADD CONSTRAINT seat_holding_student_id_year_fkey FOREIGN KEY (student_id, year) REFERENCES admission.application(student_id, year);


--
-- Name: seat_matrix seat_matrix_program_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.seat_matrix
    ADD CONSTRAINT seat_matrix_program_id_fkey FOREIGN KEY (program_id) REFERENCES admission.program(program_id);


--
-- Name: seat_matrix seat_matrix_year_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.seat_matrix
    ADD CONSTRAINT seat_matrix_year_fkey FOREIGN KEY (year) REFERENCES admission.admission_cycle(year);


--
-- Name: sim_diff sim_diff_base_program_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_diff
    ADD CONSTRAINT sim_diff_base_program_fkey FOREIGN KEY (base_program) REFERENCES admission.program(program_id);


--
-- Name: sim_diff sim_diff_sim_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_diff
    ADD CONSTRAINT sim_diff_sim_id_fkey FOREIGN KEY (sim_id) REFERENCES admission.sim_run(sim_id) ON DELETE CASCADE;


--
-- Name: sim_diff sim_diff_sim_program_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_diff
    ADD CONSTRAINT sim_diff_sim_program_fkey FOREIGN KEY (sim_program) REFERENCES admission.program(program_id);


--
-- Name: sim_diff sim_diff_student_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_diff
    ADD CONSTRAINT sim_diff_student_id_fkey FOREIGN KEY (student_id) REFERENCES admission.student(student_id);


--
-- Name: sim_input_snapshot sim_input_snapshot_round_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_input_snapshot
    ADD CONSTRAINT sim_input_snapshot_round_id_fkey FOREIGN KEY (round_id) REFERENCES admission.counselling_round(round_id);


--
-- Name: sim_input_snapshot sim_input_snapshot_year_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_input_snapshot
    ADD CONSTRAINT sim_input_snapshot_year_fkey FOREIGN KEY (year) REFERENCES admission.admission_cycle(year);


--
-- Name: sim_result sim_result_program_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_result
    ADD CONSTRAINT sim_result_program_id_fkey FOREIGN KEY (program_id) REFERENCES admission.program(program_id);


--
-- Name: sim_result sim_result_sim_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_result
    ADD CONSTRAINT sim_result_sim_id_fkey FOREIGN KEY (sim_id) REFERENCES admission.sim_run(sim_id) ON DELETE CASCADE;


--
-- Name: sim_result sim_result_student_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_result
    ADD CONSTRAINT sim_result_student_id_fkey FOREIGN KEY (student_id) REFERENCES admission.student(student_id);


--
-- Name: sim_run sim_run_base_sim_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_run
    ADD CONSTRAINT sim_run_base_sim_id_fkey FOREIGN KEY (base_sim_id) REFERENCES admission.sim_run(sim_id);


--
-- Name: sim_run sim_run_round_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_run
    ADD CONSTRAINT sim_run_round_id_fkey FOREIGN KEY (round_id) REFERENCES admission.counselling_round(round_id);


--
-- Name: sim_run sim_run_run_by_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_run
    ADD CONSTRAINT sim_run_run_by_fkey FOREIGN KEY (run_by) REFERENCES admission.app_user(user_id);


--
-- Name: sim_run sim_run_snapshot_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_run
    ADD CONSTRAINT sim_run_snapshot_id_fkey FOREIGN KEY (snapshot_id) REFERENCES admission.sim_input_snapshot(snapshot_id);


--
-- Name: sim_student_outcome sim_student_outcome_sim_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_student_outcome
    ADD CONSTRAINT sim_student_outcome_sim_id_fkey FOREIGN KEY (sim_id) REFERENCES admission.sim_run(sim_id) ON DELETE CASCADE;


--
-- Name: sim_student_outcome sim_student_outcome_student_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_student_outcome
    ADD CONSTRAINT sim_student_outcome_student_id_fkey FOREIGN KEY (student_id) REFERENCES admission.student(student_id);


--
-- Name: sim_trace sim_trace_program_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_trace
    ADD CONSTRAINT sim_trace_program_id_fkey FOREIGN KEY (program_id) REFERENCES admission.program(program_id);


--
-- Name: sim_trace sim_trace_sim_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_trace
    ADD CONSTRAINT sim_trace_sim_id_fkey FOREIGN KEY (sim_id) REFERENCES admission.sim_run(sim_id) ON DELETE CASCADE;


--
-- Name: sim_trace sim_trace_student_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.sim_trace
    ADD CONSTRAINT sim_trace_student_id_fkey FOREIGN KEY (student_id) REFERENCES admission.student(student_id);


--
-- Name: spot_acceptance spot_acceptance_pool_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.spot_acceptance
    ADD CONSTRAINT spot_acceptance_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES admission.spot_pool(pool_id);


--
-- Name: spot_acceptance spot_acceptance_student_id_year_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.spot_acceptance
    ADD CONSTRAINT spot_acceptance_student_id_year_fkey FOREIGN KEY (student_id, year) REFERENCES admission.application(student_id, year);


--
-- Name: spot_pool spot_pool_year_program_id_seat_category_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.spot_pool
    ADD CONSTRAINT spot_pool_year_program_id_seat_category_fkey FOREIGN KEY (year, program_id, seat_category) REFERENCES admission.seat_matrix(year, program_id, seat_category);


--
-- Name: student_response student_response_round_id_student_id_fkey; Type: FK CONSTRAINT; Schema: admission; Owner: -
--

ALTER TABLE ONLY admission.student_response
    ADD CONSTRAINT student_response_round_id_student_id_fkey FOREIGN KEY (round_id, student_id) REFERENCES admission.allocation(round_id, student_id);


--
-- Name: allocation; Type: ROW SECURITY; Schema: admission; Owner: -
--

ALTER TABLE admission.allocation ENABLE ROW LEVEL SECURITY;

--
-- Name: application; Type: ROW SECURITY; Schema: admission; Owner: -
--

ALTER TABLE admission.application ENABLE ROW LEVEL SECURITY;

--
-- Name: choice; Type: ROW SECURITY; Schema: admission; Owner: -
--

ALTER TABLE admission.choice ENABLE ROW LEVEL SECURITY;

--
-- Name: document_submission; Type: ROW SECURITY; Schema: admission; Owner: -
--

ALTER TABLE admission.document_submission ENABLE ROW LEVEL SECURITY;

--
-- Name: exam_result; Type: ROW SECURITY; Schema: admission; Owner: -
--

ALTER TABLE admission.exam_result ENABLE ROW LEVEL SECURITY;

--
-- Name: allocation own_student_rows; Type: POLICY; Schema: admission; Owner: -
--

CREATE POLICY own_student_rows ON admission.allocation USING ((student_id = ( SELECT app_user.student_id
   FROM admission.app_user
  WHERE (app_user.user_id = admission.current_app_user_id()))));


--
-- Name: application own_student_rows; Type: POLICY; Schema: admission; Owner: -
--

CREATE POLICY own_student_rows ON admission.application USING ((student_id = ( SELECT app_user.student_id
   FROM admission.app_user
  WHERE (app_user.user_id = admission.current_app_user_id()))));


--
-- Name: choice own_student_rows; Type: POLICY; Schema: admission; Owner: -
--

CREATE POLICY own_student_rows ON admission.choice USING ((student_id = ( SELECT app_user.student_id
   FROM admission.app_user
  WHERE (app_user.user_id = admission.current_app_user_id()))));


--
-- Name: document_submission own_student_rows; Type: POLICY; Schema: admission; Owner: -
--

CREATE POLICY own_student_rows ON admission.document_submission USING ((student_id = ( SELECT app_user.student_id
   FROM admission.app_user
  WHERE (app_user.user_id = admission.current_app_user_id()))));


--
-- Name: exam_result own_student_rows; Type: POLICY; Schema: admission; Owner: -
--

CREATE POLICY own_student_rows ON admission.exam_result USING ((student_id = ( SELECT app_user.student_id
   FROM admission.app_user
  WHERE (app_user.user_id = admission.current_app_user_id()))));


--
-- Name: seat_holding own_student_rows; Type: POLICY; Schema: admission; Owner: -
--

CREATE POLICY own_student_rows ON admission.seat_holding USING ((student_id = ( SELECT app_user.student_id
   FROM admission.app_user
  WHERE (app_user.user_id = admission.current_app_user_id()))));


--
-- Name: sim_student_outcome own_student_rows; Type: POLICY; Schema: admission; Owner: -
--

CREATE POLICY own_student_rows ON admission.sim_student_outcome USING ((student_id = ( SELECT app_user.student_id
   FROM admission.app_user
  WHERE (app_user.user_id = admission.current_app_user_id()))));


--
-- Name: sim_trace own_student_rows; Type: POLICY; Schema: admission; Owner: -
--

CREATE POLICY own_student_rows ON admission.sim_trace USING ((student_id = ( SELECT app_user.student_id
   FROM admission.app_user
  WHERE (app_user.user_id = admission.current_app_user_id()))));


--
-- Name: student_response own_student_rows; Type: POLICY; Schema: admission; Owner: -
--

CREATE POLICY own_student_rows ON admission.student_response USING ((student_id = ( SELECT app_user.student_id
   FROM admission.app_user
  WHERE (app_user.user_id = admission.current_app_user_id()))));


--
-- Name: seat_holding; Type: ROW SECURITY; Schema: admission; Owner: -
--

ALTER TABLE admission.seat_holding ENABLE ROW LEVEL SECURITY;

--
-- Name: sim_student_outcome; Type: ROW SECURITY; Schema: admission; Owner: -
--

ALTER TABLE admission.sim_student_outcome ENABLE ROW LEVEL SECURITY;

--
-- Name: sim_trace; Type: ROW SECURITY; Schema: admission; Owner: -
--

ALTER TABLE admission.sim_trace ENABLE ROW LEVEL SECURITY;

--
-- Name: student_response; Type: ROW SECURITY; Schema: admission; Owner: -
--

ALTER TABLE admission.student_response ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA admission; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA admission TO admission_app;


--
-- Name: FUNCTION accept_spot(p_pool bigint, p_key text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.accept_spot(p_pool bigint, p_key text) TO admission_app;


--
-- Name: FUNCTION actor(); Type: ACL; Schema: admission; Owner: -
--

REVOKE ALL ON FUNCTION admission.actor() FROM PUBLIC;


--
-- Name: FUNCTION add_document(p_year integer, p_name text, p_key text, p_mime text, p_checksum text, p_bytes integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.add_document(p_year integer, p_name text, p_key text, p_mime text, p_checksum text, p_bytes integer) TO admission_app;


--
-- Name: FUNCTION admin_dashboard(p_year integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.admin_dashboard(p_year integer) TO admission_app;


--
-- Name: FUNCTION audit_events(p_offset integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.audit_events(p_offset integer) TO admission_app;


--
-- Name: FUNCTION check_checkpoint(p_seq bigint, p_hash text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.check_checkpoint(p_seq bigint, p_hash text) TO admission_app;


--
-- Name: FUNCTION close_round(p_round integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.close_round(p_round integer) TO admission_app;


--
-- Name: FUNCTION close_spot(p_year integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.close_spot(p_year integer) TO admission_app;


--
-- Name: FUNCTION create_next_round(p_year integer, p_deadline timestamp with time zone); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.create_next_round(p_year integer, p_deadline timestamp with time zone) TO admission_app;


--
-- Name: FUNCTION create_session(p_user bigint, p_token text, p_csrf text, p_expiry timestamp with time zone); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.create_session(p_user bigint, p_token text, p_csrf text, p_expiry timestamp with time zone) TO admission_app;


--
-- Name: FUNCTION current_app_user_id(); Type: ACL; Schema: admission; Owner: -
--

REVOKE ALL ON FUNCTION admission.current_app_user_id() FROM PUBLIC;


--
-- Name: FUNCTION explanation_summary(p_round integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.explanation_summary(p_round integer) TO admission_app;


--
-- Name: FUNCTION finalize_admission(p_student bigint, p_year integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.finalize_admission(p_student bigint, p_year integer) TO admission_app;


--
-- Name: FUNCTION get_document(p_id bigint); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.get_document(p_id bigint) TO admission_app;


--
-- Name: FUNCTION import_exams(p_year integer, p_rows jsonb, p_commit boolean, p_revision bigint); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.import_exams(p_year integer, p_rows jsonb, p_commit boolean, p_revision bigint) TO admission_app;


--
-- Name: FUNCTION import_history(p_rows jsonb); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.import_history(p_rows jsonb) TO admission_app;


--
-- Name: FUNCTION job_finish(p_id bigint, p_status text, p_sim bigint, p_message text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.job_finish(p_id bigint, p_status text, p_sim bigint, p_message text) TO admission_app;


--
-- Name: FUNCTION job_start(p_name text, p_year integer, p_slot text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.job_start(p_name text, p_year integer, p_slot text) TO admission_app;


--
-- Name: FUNCTION job_targets(); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.job_targets() TO admission_app;


--
-- Name: FUNCTION lock_round(p_round integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.lock_round(p_round integer) TO admission_app;


--
-- Name: FUNCTION log_operation_failure(p_operation text, p_code text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.log_operation_failure(p_operation text, p_code text) TO admission_app;


--
-- Name: FUNCTION login_record(p_email text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.login_record(p_email text) TO admission_app;


--
-- Name: FUNCTION my_chances(p_year integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.my_chances(p_year integer) TO admission_app;


--
-- Name: FUNCTION open_spot(p_year integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.open_spot(p_year integer) TO admission_app;


--
-- Name: FUNCTION own_holding(p_year integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.own_holding(p_year integer) TO admission_app;


--
-- Name: FUNCTION pin_simulation(p_sim bigint, p_pin boolean); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.pin_simulation(p_sim bigint, p_pin boolean) TO admission_app;


--
-- Name: FUNCTION predictor_dashboard(p_year integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.predictor_dashboard(p_year integer) TO admission_app;


--
-- Name: FUNCTION prune_simulations(); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.prune_simulations() TO admission_app;


--
-- Name: FUNCTION record_exam(p_student bigint, p_year integer, p_category admission.seat_cat, p_marks numeric, p_crl integer, p_cat integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.record_exam(p_student bigint, p_year integer, p_category admission.seat_cat, p_marks numeric, p_crl integer, p_cat integer) TO admission_app;


--
-- Name: FUNCTION record_login_attempt(p_ip text, p_email text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.record_login_attempt(p_ip text, p_email text) TO admission_app;


--
-- Name: FUNCTION refresh_predictions(p_year integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.refresh_predictions(p_year integer) TO admission_app;


--
-- Name: FUNCTION register_student(p_email text, p_name text, p_hash text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.register_student(p_email text, p_name text, p_hash text) TO admission_app;


--
-- Name: FUNCTION remove_session(p_token text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.remove_session(p_token text) TO admission_app;


--
-- Name: FUNCTION require_role(VARIADIC allowed text[]); Type: ACL; Schema: admission; Owner: -
--

REVOKE ALL ON FUNCTION admission.require_role(VARIADIC allowed text[]) FROM PUBLIC;


--
-- Name: FUNCTION respond(p_round integer, p_decision text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.respond(p_round integer, p_decision text) TO admission_app;


--
-- Name: FUNCTION review_application(p_student bigint, p_year integer, p_approve boolean, p_reason text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.review_application(p_student bigint, p_year integer, p_approve boolean, p_reason text) TO admission_app;


--
-- Name: FUNCTION review_document(p_id bigint, p_approve boolean, p_reason text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.review_document(p_id bigint, p_approve boolean, p_reason text) TO admission_app;


--
-- Name: FUNCTION run_allocation(p_round integer, p_scenario jsonb, p_base bigint, p_publish boolean, p_key text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.run_allocation(p_round integer, p_scenario jsonb, p_base bigint, p_publish boolean, p_key text) TO admission_app;


--
-- Name: FUNCTION run_details(p_sim bigint); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.run_details(p_sim bigint) TO admission_app;


--
-- Name: FUNCTION run_mock(p_year integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.run_mock(p_year integer) TO admission_app;


--
-- Name: FUNCTION save_choices(p_year integer, p_programs integer[], p_lock boolean); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.save_choices(p_year integer, p_programs integer[], p_lock boolean) TO admission_app;


--
-- Name: FUNCTION seat_history(p_year integer, p_at timestamp with time zone); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.seat_history(p_year integer, p_at timestamp with time zone) TO admission_app;


--
-- Name: FUNCTION session_identity(p_token text); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.session_identity(p_token text) TO admission_app;


--
-- Name: FUNCTION set_response_deadline(p_round integer, p_deadline timestamp with time zone); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.set_response_deadline(p_round integer, p_deadline timestamp with time zone) TO admission_app;


--
-- Name: FUNCTION set_seats(p_year integer, p_program integer, p_category admission.seat_cat, p_seats integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.set_seats(p_year integer, p_program integer, p_category admission.seat_cat, p_seats integer) TO admission_app;


--
-- Name: FUNCTION simulation_analysis(p_sim bigint); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.simulation_analysis(p_sim bigint) TO admission_app;


--
-- Name: FUNCTION spot_availability(p_year integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.spot_availability(p_year integer) TO admission_app;


--
-- Name: FUNCTION submit_application(p_year integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.submit_application(p_year integer) TO admission_app;


--
-- Name: FUNCTION verify_ledger(); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.verify_ledger() TO admission_app;


--
-- Name: FUNCTION why_not(p_round integer); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.why_not(p_round integer) TO admission_app;


--
-- Name: FUNCTION workspace(); Type: ACL; Schema: admission; Owner: -
--

GRANT ALL ON FUNCTION admission.workspace() TO admission_app;


--
-- PostgreSQL database dump complete
--

\unrestrict hhcKYP5Nb1bUbrTJbBuTJWfogG7WXdwZaI0rtRkZkEpV4RCaYei6n3N6ulsceG2

