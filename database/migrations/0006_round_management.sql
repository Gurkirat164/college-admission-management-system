SET search_path=admission,pg_catalog,public;
CREATE FUNCTION create_next_round(p_year int,p_deadline timestamptz) RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); previous admission.counselling_round; n int;
BEGIN
 PERFORM 1 FROM admission.admission_cycle WHERE year=p_year FOR UPDATE;
 SELECT * INTO previous FROM admission.counselling_round WHERE year=p_year ORDER BY round_no DESC LIMIT 1;
 IF previous.status IS DISTINCT FROM 'CLOSED' THEN RAISE EXCEPTION 'Close the previous round before creating the next'; END IF;
 IF EXISTS(SELECT 1 FROM admission.spot_pool WHERE year=p_year) OR EXISTS(SELECT 1 FROM admission.seat_holding WHERE year=p_year AND final) THEN RAISE EXCEPTION 'The cycle has moved beyond ordinary counselling'; END IF;
 IF p_deadline<=clock_timestamp() THEN RAISE EXCEPTION 'Response deadline must be in the future'; END IF;
 INSERT INTO admission.counselling_round(year,round_no,response_deadline) VALUES(p_year,previous.round_no+1,p_deadline) RETURNING round_id INTO n;
 RETURN n;
END $$;
CREATE FUNCTION set_response_deadline(p_round int,p_deadline timestamptz) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
DECLARE u admission.app_user:=admission.require_role('ADMIN'); y int;
BEGIN
 SELECT year INTO y FROM admission.counselling_round WHERE round_id=p_round;
 PERFORM 1 FROM admission.admission_cycle WHERE year=y FOR UPDATE;
 IF p_deadline<=clock_timestamp() THEN RAISE EXCEPTION 'Response deadline must be in the future'; END IF;
 UPDATE admission.counselling_round SET response_deadline=p_deadline WHERE round_id=p_round AND status IN ('CHOICES_OPEN','LOCKED');
 IF NOT FOUND THEN RAISE EXCEPTION 'Only unpublished rounds can change their deadline'; END IF;
END $$;
GRANT EXECUTE ON FUNCTION create_next_round(int,timestamptz),set_response_deadline(int,timestamptz) TO admission_app;
