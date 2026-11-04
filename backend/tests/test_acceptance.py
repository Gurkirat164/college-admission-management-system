from concurrent.futures import ThreadPoolExecutor
import threading
import psycopg
import pytest
from psycopg import sql
from psycopg.types.json import Jsonb
from conftest import as_actor
from test_admission import run


def test_slide_stays_in_institute_while_float_can_upgrade(db):
 c=db['conn'];as_actor(c,db['accounts']);c.execute('SELECT admission.lock_round(1)');run(db,publish=True,key='round1-slide-test')
 as_actor(c,db['accounts'],email='dev@example.com');c.execute("SELECT admission.respond(1,'WITHDRAW')")
 as_actor(c,db['accounts'],email='rohan@example.com');c.execute("SELECT admission.respond(1,'SLIDE')")
 as_actor(c,db['accounts'],email='arjun@example.com');c.execute("SELECT admission.respond(1,'FLOAT')")
 as_actor(c,db['accounts']);c.execute("UPDATE admission.counselling_round SET response_deadline=now()-interval '1 second'");c.execute('SELECT admission.close_round(1)')
 rid=c.execute("SELECT admission.create_next_round(2026,now()+interval '1 day') n").fetchone()['n'];c.execute('SELECT admission.lock_round(%s)',(rid,));run(db,publish=True,key='round2-slide-test',round_id=rid)
 assert c.execute('SELECT program_id FROM admission.allocation WHERE round_id=%s AND student_id=6',(rid,)).fetchone()['program_id']==4
 assert c.execute('SELECT program_id FROM admission.allocation WHERE round_id=%s AND student_id=8',(rid,)).fetchone()['program_id']==2


def test_atomic_publication_failure_rolls_back_ledger_and_results(db):
 c=db['conn'];as_actor(c,db['accounts']);c.execute('SELECT admission.lock_round(1)')
 before=c.execute('SELECT last_seq,last_hash FROM admission.audit_chain_head').fetchone()
 c.execute("CREATE FUNCTION admission.fail_publication() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'Injected publication failure';END$$")
 c.execute('CREATE TRIGGER injected_failure AFTER INSERT ON admission.allocation FOR EACH ROW EXECUTE FUNCTION admission.fail_publication()')
 with pytest.raises(psycopg.Error):run(db,publish=True,key='atomic-failure-key')
 assert c.execute('SELECT count(*) n FROM admission.allocation').fetchone()['n']==0
 assert c.execute('SELECT count(*) n FROM admission.sim_run').fetchone()['n']==0
 assert c.execute('SELECT last_seq,last_hash FROM admission.audit_chain_head').fetchone()==before
 assert c.execute('SELECT status FROM admission.counselling_round').fetchone()['status']=='LOCKED'


def test_two_admins_publish_only_once(db):
 c=db['conn'];as_actor(c,db['accounts']);c.execute('SELECT admission.lock_round(1)')
 first=next(a for a in db['accounts'] if a['role']=='ADMIN')['user_id']
 second=c.execute("INSERT INTO admission.app_user(email,full_name,password_hash,role) SELECT 'second@example.com','Second admin',password_hash,'ADMIN' FROM admission.app_user WHERE user_id=%s RETURNING user_id",(first,)).fetchone()['user_id']
 barrier=threading.Barrier(2)
 def publish(uid):
  barrier.wait()
  for attempt in range(3):
   try:
    with psycopg.connect(db['app_url']) as conn:
     conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ');conn.execute("SELECT set_config('app.user_id',%s,true)",(str(uid),))
     conn.execute('SELECT admission.run_allocation(1,%s,NULL,true,%s)',(Jsonb({}),'concurrent-key-'+str(uid)))
    return 'published'
   except psycopg.errors.SerializationFailure:
    if attempt==2:raise
   except psycopg.errors.RaiseException:return 'conflict'
 with ThreadPoolExecutor(max_workers=2) as executor:outcomes=list(executor.map(publish,[first,second]))
 assert sorted(outcomes)==['conflict','published']
 assert c.execute('SELECT count(*) n FROM admission.sim_run WHERE is_published').fetchone()['n']==1


def test_empty_choices_zero_capacity_and_missing_pool_terminate(db):
 c=db['conn'];c.execute('UPDATE admission.seat_matrix SET seats=0');c.execute('DELETE FROM admission.choice WHERE student_id=1')
 result=run(db)
 assert c.execute('SELECT count(*) n FROM admission.sim_result WHERE sim_id=%s',(result,)).fetchone()['n']==0
 row=c.execute('SELECT reason_code FROM admission.sim_student_outcome WHERE sim_id=%s AND student_id=1',(result,)).fetchone()
 assert row['reason_code']=='NO_ELIGIBLE_CHOICES'
 c.execute("DELETE FROM admission.seat_matrix WHERE program_id=1 AND seat_category='OPEN'")
 assert run(db)>result


def test_sparse_history_and_refresh_failure_are_explicit(db):
 c=db['conn'];as_actor(c,db['accounts']);c.execute('DELETE FROM admission.hist_closing WHERE year<2025')
 assert c.execute('SELECT admission.refresh_predictions(2026) x').fetchone()['x']['refreshed']
 as_actor(c,db['accounts'],email='diya@example.com')
 bands=c.execute('SELECT admission.my_chances(2026) x').fetchone()['x'];assert bands and all(b['band']=='INSUFFICIENT_DATA' for b in bands)
 as_actor(c,db['accounts']);name=c.execute("SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid WHERE i.indrelid='admission.mv_cutoff_trend'::regclass LIMIT 1").fetchone()['relname']
 c.execute(sql.SQL('DROP INDEX {}').format(sql.Identifier('admission',name)))
 assert not c.execute('SELECT admission.refresh_predictions(2026) x').fetchone()['x']['refreshed']
 assert c.execute('SELECT stale,error FROM admission.prediction_state').fetchone()['error']


def test_current_year_cutoffs_do_not_leak_into_current_year_forecast(db):
 c=db['conn'];as_actor(c,db['accounts']);c.execute('SELECT admission.refresh_predictions(2026)')
 before=c.execute('SELECT projected_close FROM admission.mv_cutoff_trend WHERE prediction_year=2026 AND program_id=1 AND seat_category=\'OPEN\'').fetchone()['projected_close']
 c.execute("INSERT INTO admission.hist_closing(year,program_id,seat_category,closing_rank,source) VALUES(2026,1,'OPEN',999999,'imported')")
 c.execute('SELECT admission.refresh_predictions(2026)')
 assert c.execute('SELECT projected_close FROM admission.mv_cutoff_trend WHERE prediction_year=2026 AND program_id=1 AND seat_category=\'OPEN\'').fetchone()['projected_close']==before


def test_year_scoped_ranks_and_duplicate_rejection(db):
 c=db['conn'];c.execute("INSERT INTO admission.admission_cycle(year,choice_deadline) VALUES(2027,now()+interval '1 year')")
 c.execute("INSERT INTO admission.application(student_id,year,status) VALUES(1,2027,'VERIFIED'),(2,2027,'VERIFIED')")
 c.execute('INSERT INTO admission.exam_result(student_id,year,total_marks,crl_rank) VALUES(1,2027,290,1)')
 with pytest.raises(psycopg.errors.UniqueViolation):c.execute('INSERT INTO admission.exam_result(student_id,year,total_marks,crl_rank) VALUES(2,2027,280,1)')
 assert c.execute("SELECT count(*) n FROM admission.program WHERE code='CSE'").fetchone()['n']==2


def test_history_boundary_rollback_and_checkpoint(db):
 c=db['conn'];as_actor(c,db['accounts'])
 before=c.execute('SELECT last_seq,last_hash FROM admission.audit_chain_head').fetchone()
 assert c.execute('SELECT admission.check_checkpoint(%s,%s) x',(before['last_seq'],before['last_hash'])).fetchone()['x']['matches']
 with pytest.raises(RuntimeError):
  with c.transaction():
   c.execute("UPDATE admission.seat_matrix SET seats=8 WHERE program_id=1 AND seat_category='OPEN'")
   raise RuntimeError('rollback fixture')
 assert c.execute('SELECT last_seq,last_hash FROM admission.audit_chain_head').fetchone()==before
 c.execute("UPDATE admission.seat_matrix SET seats=5 WHERE program_id=1 AND seat_category='OPEN'")
 boundary=c.execute("SELECT lower(valid) t FROM admission.seat_matrix_history WHERE program_id=1 AND seat_category='OPEN' AND upper_inf(valid)").fetchone()['t']
 assert c.execute("SELECT seats FROM admission.seat_matrix_history WHERE program_id=1 AND seat_category='OPEN' AND valid @> %s",(boundary,)).fetchone()['seats']==5


def test_retention_keeps_pinned_and_published_inputs(db):
 c=db['conn'];base=run(db);child=run(db,{},base);as_actor(c,db['accounts'])
 c.execute("UPDATE admission.sim_run SET started_at=now()-interval '8 days'")
 c.execute('SELECT admission.pin_simulation(%s,true)',(child,));c.execute('SELECT admission.prune_simulations()')
 assert c.execute('SELECT count(*) n FROM admission.sim_run').fetchone()['n']==2
 c.execute('SELECT admission.pin_simulation(%s,false)',(child,));c.execute('SELECT admission.prune_simulations()');c.execute('SELECT admission.prune_simulations()')
 assert c.execute('SELECT count(*) n FROM admission.sim_run').fetchone()['n']==0
