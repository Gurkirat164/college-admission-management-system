SET search_path=admission,pg_catalog,public;
ALTER TABLE job_run DROP CONSTRAINT job_run_sim_id_fkey;
ALTER TABLE job_run ADD FOREIGN KEY(sim_id) REFERENCES sim_run ON DELETE SET NULL;
CREATE OR REPLACE FUNCTION prune_simulations() RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
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
DO $change$
DECLARE definition text;
BEGIN
 SELECT pg_get_functiondef('admission.run_allocation(integer,jsonb,bigint,boolean,text)'::regprocedure) INTO definition;
 definition:=replace(definition,
 $old$jsonb_build_object('sim_id',v_sim,'snapshot_id',sid,'scenario',p_scenario)$old$,
 $new$(SELECT jsonb_build_object('sim_id',v_sim,'snapshot_id',sid,'scenario',p_scenario,'summary',summary,'checks',checks,'input_hash',snap.payload_hash)
 FROM admission.sim_run result JOIN admission.sim_input_snapshot snap USING(snapshot_id) WHERE result.sim_id=v_sim)$new$);
 EXECUTE definition;
END $change$;
