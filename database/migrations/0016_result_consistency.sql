SET search_path=admission,pg_catalog,public;
ALTER TABLE exam_result ADD CONSTRAINT subject_marks_total CHECK(maths IS NULL OR physics IS NULL OR chemistry IS NULL OR total_marks=maths+physics+chemistry);
DO $change$
DECLARE definition text;
BEGIN
 SELECT pg_get_functiondef('admission.record_exam(bigint,integer,admission.seat_cat,numeric,integer,integer)'::regprocedure) INTO definition;
 definition:=replace(definition,'cat_rank=excluded.cat_rank;','cat_rank=excluded.cat_rank,maths=NULL,physics=NULL,chemistry=NULL;');
 EXECUTE definition;
END $change$;
CREATE OR REPLACE FUNCTION review_application(p_student bigint,p_year int,p_approve boolean,p_reason text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
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
