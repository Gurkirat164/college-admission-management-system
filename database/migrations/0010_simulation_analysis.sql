SET search_path=admission,pg_catalog,public;
CREATE FUNCTION simulation_analysis(p_sim bigint) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
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
CREATE FUNCTION own_holding(p_year int) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('STUDENT');
BEGIN
 RETURN(SELECT to_jsonb(h)||jsonb_build_object('program',p.code,'institute',p.institute,'confirmed_at',f.confirmed_at) FROM admission.seat_holding h JOIN admission.program p USING(program_id) LEFT JOIN admission.final_admission f USING(year,student_id) WHERE year=p_year AND student_id=u.student_id);
END $$;
GRANT EXECUTE ON FUNCTION simulation_analysis(bigint),own_holding(int) TO admission_app;
