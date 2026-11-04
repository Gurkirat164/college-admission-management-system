from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import psycopg
import pytest
from psycopg.types.json import Jsonb

from conftest import as_actor, login


def run(db, scenario=None, base=None, publish=False, key=None, round_id=1):
    c=db['conn']
    with c.transaction():
        c.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ')
        as_actor(c, db['accounts'])
        return c.execute('SELECT admission.run_allocation(%s,%s,%s,%s,%s) AS id',(round_id,Jsonb(scenario or {}),base,publish,key)).fetchone()['id']


def golden(db):
    c=db['conn']
    c.execute("UPDATE admission.application SET status='WITHDRAWN' WHERE student_id>3")
    c.execute('UPDATE admission.seat_matrix SET seats=0')
    c.execute("UPDATE admission.seat_matrix SET seats=1 WHERE (program_id=1 AND seat_category IN ('OPEN','OBC_NCL')) OR (program_id=2 AND seat_category='OPEN')")


def test_golden_reservation_and_monotonicity(db):
    golden(db)
    base=run(db)
    rows=db['conn'].execute('SELECT student_id,program_id,seat_category FROM admission.sim_result WHERE sim_id=%s ORDER BY student_id',(base,)).fetchall()
    assert [(r['student_id'],r['program_id'],r['seat_category']) for r in rows]==[(1,1,'OPEN'),(2,2,'OPEN'),(3,1,'OBC_NCL')]
    sim=run(db,{'seat_changes':[{'program_id':1,'seat_category':'OPEN','delta':1}]},base)
    checks=db['conn'].execute('SELECT checks FROM admission.sim_run WHERE sim_id=%s',(sim,)).fetchone()['checks']
    assert checks['stability']=='PASS' and checks['monotonicity']=='PASS'
    assert db['conn'].execute("SELECT count(*) AS n FROM admission.sim_diff WHERE sim_id=%s AND change_type='UPGRADED'",(sim,)).fetchone()['n']==1
    assert db['conn'].execute("SELECT seats FROM admission.seat_matrix WHERE year=2026 AND program_id=1 AND seat_category='OPEN'").fetchone()['seats']==1


def test_replay_uses_immutable_inputs(db):
    base=run(db)
    db['conn'].execute('UPDATE admission.seat_matrix SET seats=0')
    sim=run(db,{},base)
    assert db['conn'].execute("SELECT count(*) AS n FROM admission.sim_diff WHERE sim_id=%s AND change_type<>'UNCHANGED'",(sim,)).fetchone()['n']==0


def test_random_add_only_scenarios(db):
    import random
    generator=random.Random(42)
    base=run(db)
    for _ in range(12):
        scenario={'seat_changes':[{'program_id':generator.randint(1,5),'seat_category':'OPEN','delta':generator.randint(1,4)}]}
        sim=run(db,scenario,base)
        assert db['conn'].execute('SELECT checks FROM admission.sim_run WHERE sim_id=%s',(sim,)).fetchone()['checks']['monotonicity']=='PASS'


@pytest.mark.parametrize('scenario',[{'seat_changes':[{'program_id':999,'seat_category':'OPEN','delta':1}]},{'seat_changes':[{'program_id':1,'seat_category':'OPEN','delta':-100}]},{'withdrawal_rate':0.5},{'unknown':1}])
def test_invalid_scenarios_leave_no_partial_run(db,scenario):
    with pytest.raises(psycopg.Error): run(db,scenario)
    assert db['conn'].execute('SELECT count(*) AS n FROM admission.sim_run').fetchone()['n']==0


def test_publication_is_atomic_idempotent_and_locks_choices(db):
    c=db['conn'];as_actor(c,db['accounts'])
    c.execute('SELECT admission.lock_round(1)')
    sim=run(db,publish=True,key='publish-fixture-001')
    assert run(db,publish=True,key='publish-fixture-001')==sim
    with pytest.raises(psycopg.Error):run(db,publish=True,key='publish-other-key')
    assert c.execute('SELECT status FROM admission.counselling_round WHERE round_id=1').fetchone()['status']=='PUBLISHED'
    with pytest.raises(psycopg.Error): c.execute('DELETE FROM admission.choice WHERE student_id=1')


def test_null_scenario_cannot_bypass_publication_guard(db):
    c=db['conn'];as_actor(c,db['accounts']);c.execute('SELECT admission.lock_round(1)')
    with pytest.raises(psycopg.Error):c.execute("SELECT admission.run_allocation(1,NULL,NULL,true,'fixture-publish')")
    assert c.execute('SELECT count(*) AS n FROM admission.allocation').fetchone()['n']==0


def test_student_scope_csrf_and_analyst_restriction(client,db):
    assert client.get('/api/v1/workspace').status_code==401
    headers=login(client,db,email='diya@example.com')
    workspace=client.get('/api/v1/workspace').json()
    assert workspace['application']['student_id']==1 and 'applications' not in workspace
    assert client.put('/api/v1/me/choices/2026',json={'program_ids':[1,2]}).status_code==403
    assert client.put('/api/v1/me/choices/2026',headers=headers,json={'program_ids':[2,1]}).status_code==200
    assert client.post('/api/v1/simulations',headers=headers,json={'round_id':1}).status_code==403
    headers=login(client,db,role='ANALYST')
    assert client.post('/api/v1/admin/rounds/1/lock',headers=headers).status_code==403
    result=client.post('/api/v1/simulations',headers=headers,json={'round_id':1})
    assert result.status_code==201,result.text
    assert all(r['student_name'].startswith('Student #') for r in result.json()['results'])


def test_direct_runtime_writes_are_denied(db):
    with psycopg.connect(db['app_url']) as c:
        with pytest.raises(psycopg.errors.InsufficientPrivilege): c.execute('UPDATE admission.seat_matrix SET seats=999')


def test_audit_detects_metadata_tampering_and_history(db):
    c=db['conn'];as_actor(c,db['accounts'])
    assert c.execute('SELECT admission.verify_ledger() AS value').fetchone()['value']['valid']
    before=datetime.now(timezone.utc)
    c.execute("UPDATE admission.seat_matrix SET seats=9 WHERE year=2026 AND program_id=1 AND seat_category='OPEN'")
    historic=c.execute("SELECT seats FROM admission.seat_matrix_history WHERE year=2026 AND program_id=1 AND seat_category='OPEN' AND valid @> %s",(before,)).fetchone()
    assert historic['seats']==2
    c.execute("UPDATE admission.audit_ledger SET envelope=jsonb_set(envelope,'{actor_id}','999') WHERE seq=1")
    verification=c.execute('SELECT admission.verify_ledger() AS value').fetchone()['value']
    assert not verification['valid'] and verification['first_invalid_seq']==1


def test_freeze_float_withdraw_and_next_round(db):
    c=db['conn'];as_actor(c,db['accounts']);c.execute('SELECT admission.lock_round(1)');run(db,publish=True,key='round-one-key')
    as_actor(c,db['accounts'],email='diya@example.com');c.execute("SELECT admission.respond(1,'WITHDRAW')")
    as_actor(c,db['accounts'],email='kunal@example.com');c.execute("SELECT admission.respond(1,'FLOAT')")
    as_actor(c,db['accounts']);c.execute("UPDATE admission.counselling_round SET response_deadline=now()-interval '1 minute' WHERE round_id=1")
    c.execute('SELECT admission.close_round(1)')
    round_id=c.execute("SELECT admission.create_next_round(2026,now()+interval '1 hour') AS id").fetchone()['id']
    c.execute('SELECT admission.lock_round(%s)',(round_id,))
    run(db,publish=True,key='round-two-key',round_id=round_id)
    assert c.execute('SELECT count(*) AS n FROM admission.allocation WHERE round_id=%s AND student_id=1',(round_id,)).fetchone()['n']==0
    assert c.execute("SELECT count(*) AS n FROM admission.student_response WHERE round_id=1 AND is_default").fetchone()['n']>0


def test_spot_race_and_retry_are_transactional(db):
    c=db['conn'];as_actor(c,db['accounts'])
    c.execute("UPDATE admission.counselling_round SET status='CLOSED'")
    c.execute('UPDATE admission.seat_matrix SET seats=0')
    c.execute("UPDATE admission.seat_matrix SET seats=1 WHERE program_id=1 AND seat_category='OPEN'")
    c.execute('SELECT admission.open_spot(2026)')
    pool=c.execute("SELECT pool_id FROM admission.spot_pool WHERE program_id=1 AND seat_category='OPEN'").fetchone()['pool_id']
    students=[a for a in db['accounts'] if a['role']=='STUDENT']
    def accept(account):
        with psycopg.connect(db['app_url']) as conn:
            conn.execute("SELECT set_config('app.user_id',%s,true)",(str(account['user_id']),))
            return account,conn.execute('SELECT admission.accept_spot(%s,%s)',(pool,'spot-fixture-'+str(account['user_id']))).fetchone()[0]
    with ThreadPoolExecutor(max_workers=8) as executor:results=list(executor.map(accept,students))
    winners=[a for a,r in results if r['status']=='ACCEPTED']
    assert len(winners)==1
    _,retry=accept(winners[0]);assert retry['status']=='ACCEPTED' and retry['replayed']
    assert c.execute('SELECT seats_left FROM admission.spot_pool WHERE pool_id=%s',(pool,)).fetchone()['seats_left']==0
    assert c.execute('SELECT count(*) AS n FROM admission.seat_holding').fetchone()['n']==1


def test_documents_cannot_be_downloaded_by_another_student(client,db):
    headers=login(client,db,email='diya@example.com')
    result=client.post('/api/v1/me/applications/2026/documents',headers=headers,files={'file':('synthetic.pdf',b'%PDF-1.4\nSynthetic fixture\n','application/pdf')})
    assert result.status_code==201,result.text
    document_id=result.json()['document_id']
    assert client.get(f'/api/v1/documents/{document_id}').status_code==200
    login(client,db,email='kunal@example.com')
    assert client.get(f'/api/v1/documents/{document_id}').status_code==404
