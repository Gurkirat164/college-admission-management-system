-- Later rounds begin locked: annual preferences and priorities remain frozen.
DO $change$
DECLARE definition text;
BEGIN
 SELECT pg_get_functiondef('admission.create_next_round(integer,timestamptz)'::regprocedure) INTO definition;
 definition:=replace(definition,'INSERT INTO admission.counselling_round(year,round_no,response_deadline) VALUES(p_year,previous.round_no+1,p_deadline)',
 'INSERT INTO admission.counselling_round(year,round_no,response_deadline,status) VALUES(p_year,previous.round_no+1,p_deadline,''LOCKED'')');
 EXECUTE definition;
 SELECT pg_get_functiondef('admission.lock_round(integer)'::regprocedure) INTO definition;
 definition:=replace(definition,'IF r.status IS NULL OR r.status<>''CHOICES_OPEN''', 'IF r.status=''LOCKED'' THEN RETURN; END IF; IF r.status IS NULL OR r.status<>''CHOICES_OPEN''');
 EXECUTE definition;
END $change$;
