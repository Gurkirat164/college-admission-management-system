import io
import json
from datetime import datetime, timezone

import psycopg
import pytest
from psycopg.types.json import Jsonb

from conftest import as_actor,login
from test_admission import run


def test_rank_import_preview_commit_and_stale_revision(db):
    c=db['conn'];as_actor(c,db['accounts'])
    rows=[{'student_id':1,'dob':'2007-01-02','maths':'99.00','physics':'98.00','chemistry':'97.00','category':'OBC_NCL'},
          {'student_id':2,'dob':'2007-01-03','maths':'99.00','physics':'98.00','chemistry':'97.00','category':'OPEN'}]
    before=c.execute('SELECT total_marks FROM admission.exam_result WHERE student_id=1').fetchone()['total_marks']
    with c.transaction():preview=c.execute('SELECT admission.import_exams(2026,%s,false,NULL) x',(Jsonb(rows),)).fetchone()['x']
    assert not preview['committed'] and c.execute('SELECT total_marks FROM admission.exam_result WHERE student_id=1').fetchone()['total_marks']==before
    assert [r['student_id'] for r in preview['results'][:2]]==[1,2]
    with c.transaction():committed=c.execute('SELECT admission.import_exams(2026,%s,true,%s) x',(Jsonb(rows),preview['input_revision'])).fetchone()['x']
    assert committed['committed']
    assert c.execute('SELECT total_marks FROM admission.exam_result WHERE student_id=1').fetchone()['total_marks']==294
    with pytest.raises(psycopg.Error):
        with c.transaction():c.execute('SELECT admission.import_exams(2026,%s,true,%s)',(Jsonb(rows),preview['input_revision']))
    invalid=[rows[0]|{'maths':'100.001'}]
    with pytest.raises(psycopg.Error):
        with c.transaction():c.execute('SELECT admission.import_exams(2026,%s,false,NULL)',(Jsonb(invalid),))


def test_mock_job_freshness_and_recorded_failure(db,monkeypatch):
    from app.core.config import settings
    from app.jobs.worker import run_job
    monkeypatch.setattr(settings,'database_url',db['app_url'])
    admin=next(a['user_id'] for a in db['accounts'] if a['role']=='ADMIN')
    result=run_job(2026,slot='fixture-night',user_id=admin)
    assert result['status']=='SUCCEEDED',result
    assert run_job(2026,slot='fixture-night',user_id=admin)['status']=='SKIPPED'
    c=db['conn'];as_actor(c,db['accounts'],email='diya@example.com')
    dashboard=c.execute('SELECT admission.predictor_dashboard(2026) x').fetchone()['x']
    assert dashboard['mock']['allocation']['program']=='CSE' and not dashboard['mock']['stale']
    assert dashboard['freshness']['refreshed_at'] and not dashboard['freshness']['stale']
    c.execute('SELECT admission.save_choices(2026,ARRAY[2,1],false)')
    assert c.execute('SELECT admission.predictor_dashboard(2026) x').fetchone()['x']['mock']['stale']
    as_actor(c,db['accounts']);c.execute('SELECT admission.lock_round(1)')
    failed=run_job(2026,slot='closed-window',user_id=admin)
    assert failed['status']=='FAILED'
    row=c.execute('SELECT status,completed_at FROM admission.job_run WHERE job_id=%s',(failed['job_id'],)).fetchone()
    assert row['status']=='FAILED' and row['completed_at']


def test_history_import_refresh_and_round_drift(client,db):
    headers=login(client,db)
    csv=b'year,round_no,program_id,seat_category,opening_rank,closing_rank,source\n2025,1,1,OPEN,1,5,synthetic\n2025,2,1,OPEN,1,8,synthetic\n'
    response=client.post('/api/v1/admin/history/import',headers=headers,files={'file':('history.csv',csv,'text/csv')})
    assert response.status_code==200 and response.json()['refreshed'],response.text
    login(client,db,email='diya@example.com')
    dashboard=client.get('/api/v1/me/predictor/2026').json()
    assert any(row['program_id']==1 and row['seat_category']=='OPEN' and row['drift_percent']>0 for row in dashboard['round_drift'])


def test_advanced_sandbox_cutoffs_ripple_masked_csv_and_pin(client,db):
    headers=login(client,db,role='ANALYST')
    baseline=client.post('/api/v1/simulations',headers=headers,json={'round_id':1}).json()
    result=client.post('/api/v1/simulations',headers=headers,json={'round_id':1,'base_sim_id':baseline['sim_id'],'scenario':{'seat_changes':[{'program_id':1,'seat_category':'OPEN','delta':1}],'label':'Extra place'}})
    assert result.status_code==201,result.text
    value=result.json();assert value['cutoffs'] and value['ripple']['nodes']
    exported=client.get(f"/api/v1/simulations/{value['sim_id']}/export")
    assert exported.status_code==200 and 'Student #' in exported.text
    assert 'Diya' not in exported.text and 'Kunal' not in exported.text and '@example.com' not in exported.text
    assert client.put(f"/api/v1/simulations/{value['sim_id']}/pin",headers=headers,json={'pinned':True}).status_code==200
    assert db['conn'].execute('SELECT pinned FROM admission.sim_run WHERE sim_id=%s',(value['sim_id'],)).fetchone()['pinned']
    # Student withdrawals are reproducible with the same baseline and seed.
    body={'round_id':1,'base_sim_id':baseline['sim_id'],'scenario':{'withdrawal_rate':0.3,'seed':'stable-fixture'}}
    a=client.post('/api/v1/simulations',headers=headers,json=body).json()
    b=client.post('/api/v1/simulations',headers=headers,json=body).json()
    assert [(r['student_id'],r['program']) for r in a['results']]==[(r['student_id'],r['program']) for r in b['results']]
    assert a['checks']['monotonicity']=='NOT_APPLICABLE'


@pytest.mark.parametrize('scenario',[{'withdrawal_rate':None,'seed':'x'},{'seat_changes':[None]},{'label':[]},{'seat_changes':None}])
def test_invalid_advanced_scenarios_are_rejected(db,scenario):
    with pytest.raises(psycopg.Error):run(db,scenario)


def test_final_confirmation_and_own_holding(client,db):
    c=db['conn'];as_actor(c,db['accounts']);c.execute('SELECT admission.lock_round(1)');run(db,publish=True,key='final-fixture-publish')
    c.execute("UPDATE admission.counselling_round SET response_deadline=now()-interval '1 second'")
    c.execute('SELECT admission.close_round(1)')
    headers=login(client,db)
    response=client.post('/api/v1/admin/admissions/2026/1/finalize',headers=headers)
    assert response.status_code==200,response.text
    data=client.get('/api/v1/admin/dashboard/2026').json()
    assert next(h for h in data['holdings'] if h['student_id']==1)['confirmed_at']
    login(client,db,email='diya@example.com')
    assert client.get('/api/v1/me/holding/2026').json()['final']


def test_storage_adapters_private_read_and_path_boundary(tmp_path):
    from app.storage import LocalStorage,S3Storage
    store=LocalStorage(tmp_path);store.put('fixture',b'%PDF-fixture','application/pdf')
    with store.open('fixture') as body:assert body.read()==b'%PDF-fixture'
    with pytest.raises(ValueError):store.open('../outside')
    objects={}
    class FakeS3:
        def put_object(self,**k):objects[k['Key']]=k['Body']
        def get_object(self,**k):return {'Body':io.BytesIO(objects[k['Key']])}
        def delete_object(self,**k):del objects[k['Key']]
    remote=S3Storage('private-fixture',FakeS3());remote.put('key',b'private','application/pdf')
    with remote.open('key') as body:assert body.read()==b'private'
    remote.delete('key');assert not objects


def test_recovery_with_committed_document(client,db,monkeypatch,tmp_path):
    from app.core.config import settings
    from app.recovery import backup
    monkeypatch.setattr(settings,'upload_dir',str(tmp_path))
    monkeypatch.setattr(settings,'migration_database_url',db['owner_url'])
    headers=login(client,db,email='diya@example.com')
    result=client.post('/api/v1/me/applications/2026/documents',headers=headers,files={'file':('recovery.pdf',b'%PDF-1.4\nSynthetic recovery fixture\n','application/pdf')})
    assert result.status_code==201,result.text
    folder=backup(restore_check=True)
    manifest=json.loads((folder/'manifest.json').read_text())
    assert len(manifest['documents'])==1


def test_csv_formula_sanitization():
    from app.routes.complete import csv_value
    assert csv_value('=HYPERLINK("bad")').startswith("'")
    assert csv_value('Student #12')=='Student #12' and csv_value(-10)==-10
    assert csv_value('  =SUM(1,2)').startswith("'") and csv_value('\n=SUM(1,2)').startswith("'")


def test_new_student_submission_document_review_and_verification(client,db):
    credentials={'email':'new-student@example.com','password':'synthetic-registration-123','full_name':'Synthetic New Applicant','role':'ADMIN'}
    response=client.post('/api/v1/auth/register',json=credentials)
    assert response.status_code==201,response.text
    headers={'X-CSRF-Token':response.json()['csrf_token']}
    workspace=client.get('/api/v1/workspace').json()
    assert workspace['user']['role']=='STUDENT' and workspace['application']['status']=='DRAFT'
    sid=workspace['user']['student_id']
    uploaded=client.post('/api/v1/me/applications/2026/documents',headers=headers,files={'file':('synthetic.pdf',b'%PDF-1.4\nSynthetic exam record\n','application/pdf')})
    assert uploaded.status_code==201,uploaded.text
    assert client.post('/api/v1/me/applications/2026/submit',headers=headers).status_code==200
    admin=login(client,db)
    exam=client.put(f'/api/v1/admin/applications/2026/{sid}/exam',headers=admin,json={'category':'OPEN','total_marks':200,'crl_rank':13,'cat_rank':None})
    assert exam.status_code==200,exam.text
    assert client.post(f'/api/v1/admin/applications/2026/{sid}/review',headers=admin,json={'approve':True}).status_code==409
    assert client.post(f"/api/v1/admin/documents/{uploaded.json()['document_id']}/review",headers=admin,json={'approve':True}).status_code==200
    assert client.post(f'/api/v1/admin/applications/2026/{sid}/review',headers=admin,json={'approve':True}).status_code==200


def test_fresh_demo_requires_new_explicit_name_and_preserves_live_config(db,monkeypatch):
    import uuid
    from pathlib import Path
    from psycopg import sql
    from psycopg.conninfo import conninfo_to_dict
    from app.core.config import settings,ROOT
    from app.demo import create_demo
    monkeypatch.setattr(settings,'migration_database_url',db['owner_url'])
    name='admission_demo_test_'+uuid.uuid4().hex[:10]
    previous=(ROOT/'backend/.env').read_bytes() if (ROOT/'backend/.env').exists() else None
    params=conninfo_to_dict(db['owner_url'])|{'dbname':'postgres'}
    try:
        assert create_demo(name)==name
        with pytest.raises(ValueError):create_demo(name)
        assert ((ROOT/'backend/.env').read_bytes() if (ROOT/'backend/.env').exists() else None)==previous
        with pytest.raises(ValueError):create_demo('admission')
    finally:
        with psycopg.connect(**params,autocommit=True) as conn:conn.execute(sql.SQL('DROP DATABASE IF EXISTS {} WITH (FORCE)').format(sql.Identifier(name)))
        (ROOT/'.local'/f'{name}-accounts.json').unlink(missing_ok=True)


def test_admin_overview_shows_latest_baseline_then_published_round(client,db):
    headers=login(client,db)
    empty=client.get('/api/v1/admin/overview/2026')
    assert empty.status_code==200,empty.text
    data=empty.json()
    assert data['run'] is None and data['seats']==[]
    assert sum(p['seats'] for p in data['pools'])==15
    assert data['applicants']['total']==12 and data['applicants']['by_category']=={'OPEN':8,'OBC_NCL':4}
    assert data['funnel']=={'applied':12,'submitted':12,'verified':12,'ranked':12,'chose':12}
    assert (data['demand'][0]['code'],data['demand'][0]['first_choice'],data['demand'][0]['seats'])==('CSE',12,3)
    baseline=run(db)
    data=client.get('/api/v1/admin/overview/2026').json()
    assert data['run']['sim_id']==baseline and not data['run']['is_published'] and not data['run']['inputs_changed']
    assert len(data['seats'])==12 and data['unplaced']==[]
    assert [r['sim_id'] for r in data['runs']]==[baseline]
    diya=next(s for s in data['seats'] if s['student_id']==1)
    assert (diya['seat_category'],diya['admission_category'],diya['pref_order'])==('OPEN','OBC_NCL',1)
    c=db['conn'];as_actor(c,db['accounts']);c.execute('SELECT admission.lock_round(1)')
    published=run(db,publish=True,key='overview-fixture-publish')
    data=client.get('/api/v1/admin/overview/2026').json()
    assert data['run']['sim_id']==published and data['run']['is_published'] and data['round']['status']=='PUBLISHED'
    login(client,db,email='diya@example.com')
    assert client.get('/api/v1/admin/overview/2026').status_code==403
