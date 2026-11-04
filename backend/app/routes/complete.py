import csv
import io
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, UploadFile
from fastapi.responses import Response
from psycopg.types.json import Jsonb
from pydantic import BaseModel, Field

from app.core.security import identity
from app.jobs.worker import run_job
from app.routes.workflows import call

router = APIRouter()


def csv_rows(file, required):
    raw = file.file.read(5 * 1024 * 1024 + 1)
    if len(raw) > 5 * 1024 * 1024:
        raise HTTPException(422, 'CSV imports must be at most 5 MB.')
    try:
        reader = csv.DictReader(io.StringIO(raw.decode('utf-8-sig')))
        if reader.fieldnames is None or set(reader.fieldnames) != set(required) or len(reader.fieldnames) != len(required):
            raise ValueError('columns')
        rows = list(reader)
        if any(None in row or any(value is None for value in row.values()) for row in rows):
            raise ValueError('row width')
        return rows
    except (UnicodeError, csv.Error, ValueError):
        raise HTTPException(422, 'Use a UTF-8 CSV with exactly these columns: ' + ', '.join(required))


def require_admin(user):
    if user['role'] != 'ADMIN':
        raise HTTPException(403, 'Only an admission admin can use this action.')


@router.post('/admin/exams/{year}/import')
def import_exams(year: int, file: UploadFile, commit: bool = False, expected_revision: int | None = None, user=Depends(identity)):
    require_admin(user)
    rows = csv_rows(file, ['student_id','dob','maths','physics','chemistry','category'])
    try:
        for row in rows:
            row['student_id'] = int(row['student_id'])
            datetime.strptime(row['dob'], '%Y-%m-%d')
            # Preserve decimal strings; PostgreSQL validates precision and ranges.
    except ValueError:
        raise HTTPException(422, 'Student IDs must be integers and birth dates must use YYYY-MM-DD.')
    return call('import_exams', (year, Jsonb(rows), commit, expected_revision), user)


@router.post('/admin/history/import')
def import_history(file: UploadFile, user=Depends(identity)):
    require_admin(user)
    rows = csv_rows(file, ['year','round_no','program_id','seat_category','opening_rank','closing_rank','source'])
    try:
        for row in rows:
            for key in ['year','round_no','program_id','opening_rank','closing_rank']:
                row[key] = int(row[key])
    except ValueError:
        raise HTTPException(422, 'Years, round numbers, program IDs and ranks must be integers.')
    count = call('import_history', (Jsonb(rows),), user)
    workspace = call('workspace', user=user)
    refresh = call('refresh_predictions', (workspace['year'],), user)
    return {'imported_rows': count, **refresh}


@router.get('/me/predictor/{year}')
def predictor(year: int, user=Depends(identity)):
    return call('predictor_dashboard', (year,), user)


@router.get('/me/holding/{year}')
def holding(year: int, user=Depends(identity)):
    return call('own_holding', (year,), user)


@router.get('/admin/dashboard/{year}')
def dashboard(year: int, user=Depends(identity)):
    return call('admin_dashboard', (year,), user)


@router.post('/admin/jobs/{year}/mock')
def mock(year: int, user=Depends(identity)):
    require_admin(user)
    return run_job(year, user_id=user['user_id'])


@router.post('/admin/predictions/{year}/refresh')
def refresh(year: int, user=Depends(identity)):
    return call('refresh_predictions', (year,), user)


@router.post('/admin/spot/{year}/close')
def close_spot(year: int, user=Depends(identity)):
    call('close_spot', (year,), user)
    return {'closed': True}


class Pin(BaseModel):
    pinned: bool


class Checkpoint(BaseModel):
    seq: int = Field(ge=1)
    hash: str = Field(pattern='^[0-9a-f]{64}$')


@router.get('/audit/events')
def events(offset: int = 0, user=Depends(identity)):
    return call('audit_events', (offset,), user)


@router.post('/audit/checkpoint')
def checkpoint(data: Checkpoint, user=Depends(identity)):
    return call('check_checkpoint', (data.seq, data.hash), user)


@router.get('/me/rounds/{round_id}/explanation-summary')
def explanation(round_id: int, user=Depends(identity)):
    return call('explanation_summary', (round_id,), user)


@router.put('/simulations/{sim_id}/pin')
def pin(sim_id: int, data: Pin, user=Depends(identity)):
    call('pin_simulation', (sim_id, data.pinned), user)
    return {'pinned': data.pinned}


def csv_value(value):
    if isinstance(value, str) and (value.startswith(('\t','\r','\n')) or value.lstrip().startswith(('=', '+', '-', '@'))):
        return "'" + value
    return value


@router.get('/simulations/{sim_id}/export')
def export(sim_id: int, user=Depends(identity)):
    run = call('simulation_analysis', (sim_id,), user)
    output = io.StringIO(newline='')
    writer = csv.writer(output)
    writer.writerow(['student','before_program','after_program','before_pool','after_pool','change'])
    for row in run['diff']:
        writer.writerow([csv_value(row.get(key) or '') for key in ['student_name','base_code','sim_code','base_category','sim_category','change_type']])
    return Response(output.getvalue(), media_type='text/csv; charset=utf-8', headers={'Content-Disposition':f'attachment; filename="simulation-{sim_id}.csv"'})
