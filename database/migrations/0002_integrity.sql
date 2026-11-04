SET search_path=admission,pg_catalog,public;
CREATE FUNCTION append_event(p_entity text,p_op text,p_payload jsonb) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,admission,pg_temp AS $$
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
CREATE FUNCTION audit_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
BEGIN
  PERFORM admission.append_event(TG_TABLE_NAME,TG_OP,jsonb_build_object('old',to_jsonb(OLD),'new',to_jsonb(NEW)));
  RETURN NULL;
END $$;
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['seat_matrix','application','exam_result','choice','counselling_round','allocation','student_response','seat_holding','document_submission','spot_acceptance'] LOOP
    EXECUTE format('CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON admission.%I FOR EACH ROW EXECUTE FUNCTION admission.audit_change()',t);
  END LOOP;
END $$;
CREATE FUNCTION history_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
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
CREATE TRIGGER matrix_history AFTER INSERT OR UPDATE OR DELETE ON seat_matrix FOR EACH ROW EXECUTE FUNCTION history_change();

CREATE FUNCTION verify_ledger() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
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

CREATE FUNCTION guard_choices() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,admission,pg_temp AS $$
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
CREATE TRIGGER choices_guard BEFORE INSERT OR UPDATE OR DELETE ON choice FOR EACH ROW EXECUTE FUNCTION guard_choices();
