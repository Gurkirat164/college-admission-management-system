SET search_path=admission,pg_catalog,public;
DROP MATERIALIZED VIEW mv_cutoff_trend;
CREATE MATERIALIZED VIEW mv_cutoff_trend AS
WITH final AS(SELECT DISTINCT ON(year,program_id,seat_category) * FROM hist_closing ORDER BY year,program_id,seat_category,round_no DESC),
drift AS(SELECT year,program_id,seat_category,closing_rank,
 first_value(closing_rank) OVER(PARTITION BY year,program_id,seat_category ORDER BY round_no) first_close,
 row_number() OVER(PARTITION BY year,program_id,seat_category ORDER BY round_no DESC) n FROM hist_closing)
SELECT cycle.year prediction_year,f.program_id,f.seat_category,count(*) years_of_data,min(f.closing_rank) toughest_close,max(f.closing_rank) easiest_close,
 greatest(1,least(2147483647,round(coalesce(regr_intercept(f.closing_rank,f.year)+regr_slope(f.closing_rank,f.year)*cycle.year,avg(f.closing_rank)))))::int projected_close,
 bool_and(f.source='synthetic') synthetic,
 (SELECT round(avg(100.0*(closing_rank-first_close)/nullif(first_close,0)),2) FROM drift d WHERE d.n=1 AND d.year<cycle.year AND d.program_id=f.program_id AND d.seat_category=f.seat_category) drift_percent
FROM admission_cycle cycle JOIN final f ON f.year<cycle.year GROUP BY cycle.year,f.program_id,f.seat_category;
CREATE UNIQUE INDEX ON mv_cutoff_trend(prediction_year,program_id,seat_category);
DO $change$
DECLARE definition text;
BEGIN
 SELECT pg_get_functiondef('admission.my_chances(integer)'::regprocedure) INTO definition;
 definition:=replace(definition,$find$WHERE (m.seat_category='OPEN'$find$,$replacement$WHERE m.prediction_year=p_year AND (m.seat_category='OPEN'$replacement$);
 EXECUTE definition;
 SELECT pg_get_functiondef('admission.predictor_dashboard(integer)'::regprocedure) INTO definition;
 definition:=replace(definition,'FROM admission.mv_cutoff_trend)','FROM admission.mv_cutoff_trend WHERE prediction_year=p_year)');
 EXECUTE definition;
END $change$;
CREATE VIEW allocation_trace AS SELECT cr.round_id,t.* FROM sim_trace t JOIN counselling_round cr ON cr.published_sim_id=t.sim_id;
ALTER TABLE sim_student_outcome ADD COLUMN reason_code text;
CREATE FUNCTION explanation_summary(p_round int) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT');
BEGIN
 RETURN(SELECT to_jsonb(o) FROM admission.sim_student_outcome o JOIN admission.counselling_round cr ON cr.published_sim_id=o.sim_id WHERE cr.round_id=p_round AND o.student_id=u.student_id);
END $$;
CREATE FUNCTION audit_events(p_offset int DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN','AUDITOR');
BEGIN
 RETURN jsonb_build_object('total',(SELECT count(*) FROM admission.audit_ledger),'events',coalesce((SELECT jsonb_agg(to_jsonb(e) ORDER BY seq DESC) FROM(
 SELECT seq,envelope->>'at' recorded_at,envelope->>'entity' entity,envelope->>'op' operation,envelope->>'actor_id' actor_id,hash
 FROM admission.audit_ledger ORDER BY seq DESC LIMIT 25 OFFSET greatest(0,p_offset)) e),'[]'::jsonb));
END $$;
CREATE FUNCTION check_checkpoint(p_seq bigint,p_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN','AUDITOR'); h text;
BEGIN
 SELECT hash INTO h FROM admission.audit_ledger WHERE seq=p_seq;
 RETURN jsonb_build_object('matches',h IS NOT NULL AND h=p_hash,'checkpoint_seq',p_seq,'chain_length',(SELECT last_seq FROM admission.audit_chain_head));
END $$;
GRANT EXECUTE ON FUNCTION explanation_summary(int),audit_events(int),check_checkpoint(bigint,text) TO admission_app;
