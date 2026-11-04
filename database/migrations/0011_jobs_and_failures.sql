SET search_path=admission,pg_catalog,public;
CREATE FUNCTION job_targets() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN');
BEGIN
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('year',year,'choices_open',NOT choices_locked AND choice_deadline>clock_timestamp())) FROM admission.admission_cycle),'[]'::jsonb);
END $$;
CREATE FUNCTION log_operation_failure(p_operation text,p_code text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.actor();
BEGIN
 PERFORM admission.append_event('operation','FAILED',jsonb_build_object('operation',left(p_operation,100),'code',left(p_code,10)));
END $$;
GRANT EXECUTE ON FUNCTION job_targets(),log_operation_failure(text,text) TO admission_app;
