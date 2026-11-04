"""Reproducible 20k/100-scenario/500-contender checks in disposable databases."""
import argparse
import json
import os
import platform
import random
import statistics
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager

import psycopg
from argon2 import PasswordHasher
from psycopg import sql
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from app.cli import migrate
from app.core.config import ROOT


@contextmanager
def fixture(owner_url,app_url,students):
    name='admission_verify_'+uuid.uuid4().hex[:12]
    owner_base=owner_url.rsplit('/',1)[0];app_base=app_url.rsplit('/',1)[0]
    with psycopg.connect(owner_base+'/postgres',autocommit=True) as control:
        control.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(name)))
        try:
            with psycopg.connect(owner_base+'/'+name) as conn:
                migrate(conn)
                # Fixture ingestion is excluded from engine timing; keep FK constraints enabled.
                for (table,) in conn.execute("SELECT tablename FROM pg_tables WHERE schemaname='admission'").fetchall():
                    conn.execute(sql.SQL('ALTER TABLE admission.{} DISABLE TRIGGER USER').format(sql.Identifier(table)))
                conn.execute((ROOT/'database/generators/benchmark.sql').read_text().replace(':students',str(int(students))))
                for (table,) in conn.execute("SELECT tablename FROM pg_tables WHERE schemaname='admission'").fetchall():
                    conn.execute(sql.SQL('ALTER TABLE admission.{} ENABLE TRIGGER USER').format(sql.Identifier(table)))
                password='verification-'+uuid.uuid4().hex
                hashed=PasswordHasher().hash(password)
                for role,i in [('ADMIN',1),('ANALYST',2),('ANALYST',3),('ANALYST',4)]:
                    conn.execute('INSERT INTO admission.app_user(user_id,email,full_name,password_hash,role) VALUES(%s,%s,%s,%s,%s)',(i,f'actor{i}@example.com',f'Fixture {role} {i}',hashed,role))
                conn.execute("INSERT INTO admission.app_user(user_id,email,full_name,password_hash,role,student_id) VALUES(10,'student@example.com','Synthetic request user',%s,'STUDENT',%s)",(hashed,students))
                conn.execute("SELECT admission.append_event('fixture','LOAD',jsonb_build_object('students',%s,'choices_per_student',12,'synthetic',true))",(students,))
                conn.commit()
            yield {'owner_url':owner_base+'/'+name,'app_url':app_base+'/'+name,'password':password}
        finally:
            control.execute(sql.SQL('DROP DATABASE {} WITH (FORCE)').format(sql.Identifier(name)))


def solve(f,scenario=None,base=None,actor=1,plans=False):
    started=time.perf_counter()
    for attempt in range(3):
        try:
            run,plan=solve_once(f,scenario,base,actor,plans)
            run['retries']=attempt
            run['total_wall_ms']=round((time.perf_counter()-started)*1000,2)
            return run,plan
        except (psycopg.errors.SerializationFailure,psycopg.errors.DeadlockDetected):
            if attempt==2:raise
            time.sleep(.05*(attempt+1))


def solve_once(f,scenario=None,base=None,actor=1,plans=False):
    start=time.perf_counter()
    with psycopg.connect(f['owner_url'],row_factory=dict_row,options='-c temp_buffers=64MB') as conn:
        conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ')
        conn.execute("SELECT set_config('app.user_id',%s,true)",(str(actor),))
        conn.execute("SET LOCAL statement_timeout='300s'")
        sid=conn.execute('SELECT admission.run_allocation(1,%s,%s,false,NULL) id',(Jsonb(scenario or {}),base)).fetchone()['id']
        run=conn.execute('SELECT checks,summary,duration_ms FROM admission.sim_run WHERE sim_id=%s',(sid,)).fetchone()
        plan={}
        if plans:
            conn.execute("INSERT INTO pg_temp.w_state SELECT student_id,min(k),'FREE' FROM pg_temp.w_choice GROUP BY student_id ON CONFLICT DO NOTHING")
            queries={
              'proposals':"SELECT c.student_id,c.program_id,c.seat_category FROM pg_temp.w_state s JOIN pg_temp.w_choice c ON c.student_id=s.student_id AND c.k=s.next_k WHERE s.status='FREE'",
              'trimming':"SELECT h.student_id,row_number() OVER(PARTITION BY program_id,seat_category ORDER BY rank_used,student_id) FROM pg_temp.w_hold h"}
            for label,query in queries.items():
                plan[label]=conn.execute('EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) '+query).fetchone()['QUERY PLAN']
        conn.commit()
    run.update(sim_id=sid,wall_ms=round((time.perf_counter()-start)*1000,2))
    return run,plan


def benchmark(owner,app):
    report={'machine':{'platform':platform.platform(),'cpu':platform.processor(),'logical_cpus':os.cpu_count()},'seed':42}
    with fixture(owner,app,20000) as f:
        with psycopg.connect(f['owner_url']) as conn:
            report['postgresql_version']=conn.execute('SHOW server_version').fetchone()[0]
            report['dataset']={key:conn.execute('SELECT count(*) FROM admission.'+key).fetchone()[0] for key in ['student','choice','program','seat_matrix']}
        print('Running 20,000-student allocation samples.',flush=True)
        baseline,plans=solve(f,plans=True);samples=[baseline]
        (ROOT/'evidence/query-plans.json').write_text(json.dumps(plans,default=str,indent=2))
        for n in range(4):
            run,_=solve(f,{'label':f'Benchmark replay {n+1}'},baseline['sim_id']);samples.append(run)
            print(f"Allocation sample {n+2}/5: {run['duration_ms']} ms",flush=True)
        times=sorted(s['duration_ms'] for s in samples)
        report['allocation']={'samples':samples,'p50_ms':statistics.median(times),'p95_ms':times[-1],'p95_method':'nearest-rank, five samples','target_under_5000_ms':all(t<5000 for t in times)}
        (ROOT/'evidence/scale-verification.json').write_text(json.dumps(report,default=str,indent=2))
        print('Measuring three concurrent analysts and normal student API reads.',flush=True)
        from fastapi.testclient import TestClient
        from psycopg_pool import ConnectionPool
        import app.db as db_module
        import app.main as main
        previous_db,previous_main=db_module.pool,main.pool
        request_pool=ConnectionPool(f['app_url'],open=False,min_size=0,max_size=4,kwargs={'row_factory':dict_row})
        db_module.pool=main.pool=request_pool
        try:
            with TestClient(main.app) as client:
                response=client.post('/api/v1/auth/login',json={'email':'student@example.com','password':f['password']});response.raise_for_status()
                with ThreadPoolExecutor(max_workers=3) as workers:
                    futures=[workers.submit(solve,f,{'label':f'Concurrent analyst {actor}'},baseline['sim_id'],actor) for actor in (2,3,4)]
                    latencies=[]
                    while not all(future.done() for future in futures) or len(latencies)<10:
                        start=time.perf_counter();response=client.get('/api/v1/workspace');response.raise_for_status();latencies.append(round((time.perf_counter()-start)*1000,2));time.sleep(.1)
                    concurrent=[future.result()[0] for future in futures]
                report['concurrent_analysts']={'runs':concurrent,'student_http_samples':len(latencies),'student_http_p50_ms':statistics.median(latencies),'student_http_max_ms':max(latencies)}
        finally:
            db_module.pool,main.pool=previous_db,previous_main
        print('Running 500 distinct spot contenders with 50 concurrent clients.',flush=True)
        report['spot']=spot_race(f)
    with fixture(owner,app,300) as f:
        baseline,_=solve(f);generator=random.Random(42);durations=[]
        for n in range(100):
            scenario={'seat_changes':[{'program_id':generator.randint(1,30),'seat_category':generator.choice(['OPEN','EWS','OBC_NCL','SC','ST']),'delta':generator.randint(1,5)}]}
            run,_=solve(f,scenario,baseline['sim_id'])
            if run['checks']['monotonicity']!='PASS':raise AssertionError('Monotonicity did not pass')
            durations.append(run['duration_ms'])
            if (n+1)%20==0:print(f'Add-only scenarios: {n+1}/100 passed.',flush=True)
        report['property_tests']={'scenarios':100,'students_per_scenario':300,'seed':42,'violations':0,'p50_ms':statistics.median(durations)}
    (ROOT/'evidence/scale-verification.json').write_text(json.dumps(report,default=str,indent=2))
    print(json.dumps({key:report[key] for key in ['postgresql_version','dataset','spot','property_tests']},indent=2),flush=True)


def spot_race(f):
    with psycopg.connect(f['owner_url']) as conn:
        conn.execute("SELECT set_config('app.user_id','1',true)")
        conn.execute("UPDATE admission.counselling_round SET status='CLOSED'")
        conn.execute('UPDATE admission.seat_matrix SET seats=0')
        conn.execute("UPDATE admission.seat_matrix SET seats=1 WHERE program_id=1 AND seat_category='OPEN'")
        conn.execute("INSERT INTO admission.app_user(user_id,email,full_name,password_hash,role,student_id) SELECT 1000+g,'contender'||g||'@example.com','Synthetic Contender '||g,'not-a-login-hash','STUDENT',g FROM generate_series(1,500) g")
        conn.execute('SELECT admission.open_spot(2026)')
        pool_id=conn.execute("SELECT pool_id FROM admission.spot_pool WHERE program_id=1 AND seat_category='OPEN'").fetchone()[0]
    def contender(n):
        retries=0
        for attempt in range(3):
            try:
                with psycopg.connect(f['app_url']) as conn:
                    conn.execute("SELECT set_config('app.user_id',%s,true)",(str(1000+n),))
                    result=conn.execute('SELECT admission.accept_spot(%s,%s)',(pool_id,'scale-contender-'+str(n))).fetchone()[0]
                return result['status'],retries
            except (psycopg.errors.DeadlockDetected,psycopg.errors.SerializationFailure):
                retries+=1;time.sleep(.01*(attempt+1))
        return 'FAILED',retries
    start=time.perf_counter()
    with ThreadPoolExecutor(max_workers=50) as executor:outcomes=list(executor.map(contender,range(1,501)))
    counts={state:sum(result==state for result,_ in outcomes) for state in ['ACCEPTED','SEAT_UNAVAILABLE','FAILED']}
    with psycopg.connect(f['owner_url']) as conn:
        left=conn.execute('SELECT seats_left FROM admission.spot_pool WHERE pool_id=%s',(pool_id,)).fetchone()[0]
        accepted=conn.execute('SELECT count(*) FROM admission.spot_acceptance').fetchone()[0]
        holdings=conn.execute('SELECT count(*) FROM admission.seat_holding').fetchone()[0]
        if counts!={'ACCEPTED':1,'SEAT_UNAVAILABLE':499,'FAILED':0} or (left,accepted,holdings)!=(0,1,1):raise AssertionError('Spot invariant failed: '+str(counts))
        conn.execute('CREATE TABLE public.unsafe_demo_acceptance(student_id int PRIMARY KEY)')
    barrier=threading.Barrier(50)
    def broken(n):
        with psycopg.connect(f['owner_url']) as conn:
            available=conn.execute('SELECT count(*) FROM public.unsafe_demo_acceptance').fetchone()[0]<1
            barrier.wait(timeout=30)
            if available:conn.execute('INSERT INTO public.unsafe_demo_acceptance VALUES(%s)',(n,))
    with ThreadPoolExecutor(max_workers=50) as executor:list(executor.map(broken,range(1,51)))
    with psycopg.connect(f['owner_url']) as conn:unsafe=conn.execute('SELECT count(*) FROM public.unsafe_demo_acceptance').fetchone()[0]
    if unsafe!=50:raise AssertionError('Controlled unsafe race was not reproduced')
    return {'attempts':500,'concurrent_clients':50,'outcomes':counts,'seats_left':left,'acceptances':accepted,'holdings':holdings,'retries':sum(r for _,r in outcomes),'duration_ms':round((time.perf_counter()-start)*1000,2),'unsafe_demo':{'clients':50,'overbooked_acceptances':unsafe,'capacity':1,'scope':'disposable verification table only'}}


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--owner-url-env',default='MIGRATION_DATABASE_URL');parser.add_argument('--app-url-env',default='DATABASE_URL');args=parser.parse_args()
    from app.core.config import settings
    benchmark(os.environ.get(args.owner_url_env) or settings.migration_database_url,os.environ.get(args.app_url_env) or settings.database_url)
