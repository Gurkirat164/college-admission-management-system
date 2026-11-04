SET search_path=admission,pg_catalog,public;

CREATE FUNCTION login_record(p_email text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
 SELECT jsonb_build_object('user_id',user_id,'password_hash',password_hash,'enabled',enabled)
 FROM admission.app_user WHERE email=lower(trim(p_email))
$$;
CREATE FUNCTION create_session(p_user bigint,p_token text,p_csrf text,p_expiry timestamptz) RETURNS void LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
 INSERT INTO admission.app_session(token_hash,user_id,csrf_hash,expires_at) VALUES(p_token,p_user,p_csrf,p_expiry)
$$;
CREATE FUNCTION session_identity(p_token text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
 SELECT jsonb_build_object('user_id',u.user_id,'email',u.email,'full_name',u.full_name,'role',u.role,'student_id',u.student_id,'csrf_hash',s.csrf_hash)
 FROM admission.app_session s JOIN admission.app_user u USING(user_id)
 WHERE s.token_hash=p_token AND s.expires_at>clock_timestamp() AND u.enabled
$$;
CREATE FUNCTION remove_session(p_token text) RETURNS void LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$ DELETE FROM admission.app_session WHERE token_hash=p_token $$;
CREATE FUNCTION register_student(p_email text,p_name text,p_hash text) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE sid bigint; uid bigint; y int;
BEGIN
 INSERT INTO admission.student(full_name) VALUES(trim(p_name)) RETURNING student_id INTO sid;
 INSERT INTO admission.app_user(email,full_name,password_hash,role,student_id) VALUES(lower(trim(p_email)),trim(p_name),p_hash,'STUDENT',sid) RETURNING user_id INTO uid;
 SELECT max(year) INTO y FROM admission.admission_cycle WHERE NOT choices_locked AND choice_deadline>clock_timestamp();
 IF y IS NOT NULL THEN INSERT INTO admission.application(student_id,year) VALUES(sid,y); END IF;
 RETURN uid;
END $$;

CREATE FUNCTION workspace() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
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

CREATE FUNCTION save_choices(p_year int,p_programs int[],p_lock boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
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

CREATE FUNCTION set_seats(p_year int,p_program int,p_category admission.seat_cat,p_seats int) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); c admission.admission_cycle;
BEGIN
 SELECT * INTO c FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 IF c.choices_locked THEN RAISE EXCEPTION 'Seat matrix is locked for this cycle'; END IF;
 UPDATE admission.seat_matrix SET seats=p_seats WHERE year=p_year AND program_id=p_program AND seat_category=p_category;
 IF NOT FOUND THEN RAISE EXCEPTION 'Seat pool not found'; END IF;
 UPDATE admission.admission_cycle SET input_revision=input_revision+1 WHERE year=p_year;
END $$;

CREATE FUNCTION lock_round(p_round int) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); y int; r admission.counselling_round;
BEGIN
 SELECT year INTO y FROM admission.counselling_round WHERE round_id=p_round;
 PERFORM 1 FROM admission.admission_cycle WHERE year=y FOR UPDATE;
 SELECT * INTO r FROM admission.counselling_round WHERE round_id=p_round FOR UPDATE;
 IF r.status IS NULL OR r.status<>'CHOICES_OPEN' THEN RAISE EXCEPTION 'Round is not open for locking'; END IF;
 IF r.round_no>1 AND NOT EXISTS(SELECT 1 FROM admission.counselling_round WHERE year=y AND round_no=r.round_no-1 AND status='CLOSED') THEN RAISE EXCEPTION 'Close the previous round first'; END IF;
 UPDATE admission.admission_cycle SET choices_locked=true,input_revision=input_revision+1 WHERE year=y;
 UPDATE admission.counselling_round SET status='LOCKED' WHERE round_id=p_round;
END $$;

CREATE FUNCTION respond(p_round int,p_decision text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
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

CREATE FUNCTION close_round(p_round int) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
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

CREATE FUNCTION review_application(p_student bigint,p_year int,p_approve boolean,p_reason text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); c admission.admission_cycle;
BEGIN
 SELECT * INTO c FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 IF c.choices_locked THEN RAISE EXCEPTION 'Eligibility is locked for this cycle'; END IF;
 IF p_approve AND NOT EXISTS(SELECT 1 FROM admission.exam_result WHERE student_id=p_student AND year=p_year) THEN RAISE EXCEPTION 'An annual exam result is required before verification'; END IF;
 IF NOT p_approve AND length(trim(coalesce(p_reason,'')))<3 THEN RAISE EXCEPTION 'Provide a rejection reason'; END IF;
 UPDATE admission.application SET status=CASE WHEN p_approve THEN 'VERIFIED' ELSE 'REJECTED' END,review_reason=p_reason WHERE student_id=p_student AND year=p_year;
 IF NOT FOUND THEN RAISE EXCEPTION 'Application not found'; END IF;
 UPDATE admission.admission_cycle SET input_revision=input_revision+1 WHERE year=p_year;
END $$;

CREATE FUNCTION add_document(p_year int,p_name text,p_key text,p_mime text,p_checksum text,p_bytes int) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT'); c admission.admission_cycle; n bigint;
BEGIN
 SELECT * INTO c FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 IF c.choices_locked OR c.choice_deadline<=clock_timestamp() THEN RAISE EXCEPTION 'Document submission window is closed'; END IF;
 INSERT INTO admission.document_submission(student_id,year,original_name,storage_key,mime_type,checksum,byte_count)
 VALUES(u.student_id,p_year,p_name,p_key,p_mime,p_checksum,p_bytes) RETURNING document_id INTO n;
 RETURN n;
END $$;
CREATE FUNCTION get_document(p_id bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.actor(); d admission.document_submission;
BEGIN
 SELECT * INTO d FROM admission.document_submission WHERE document_id=p_id;
 IF d.document_id IS NULL OR (u.role<>'ADMIN' AND (u.role<>'STUDENT' OR u.student_id<>d.student_id)) THEN RAISE EXCEPTION 'Document not found' USING ERRCODE='P0002'; END IF;
 RETURN to_jsonb(d);
END $$;
CREATE FUNCTION review_document(p_id bigint,p_approve boolean,p_reason text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); d admission.document_submission;
BEGIN
 SELECT * INTO d FROM admission.document_submission WHERE document_id=p_id;
 PERFORM 1 FROM admission.admission_cycle WHERE year=d.year AND NOT choices_locked FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Document is missing or the cycle is locked'; END IF;
 IF NOT p_approve AND length(trim(coalesce(p_reason,'')))<3 THEN RAISE EXCEPTION 'Provide a rejection reason'; END IF;
 UPDATE admission.document_submission SET status=CASE WHEN p_approve THEN 'VERIFIED' ELSE 'REJECTED' END,reason=p_reason WHERE document_id=p_id;
END $$;
