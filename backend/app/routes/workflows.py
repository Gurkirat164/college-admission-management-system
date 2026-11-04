import hashlib
import uuid
import random
import time
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, UploadFile
from fastapi.responses import StreamingResponse
from urllib.parse import quote
from psycopg import sql
from psycopg import Error as DatabaseError
from psycopg.types.json import Jsonb
from pydantic import BaseModel, Field

from app.core.config import ROOT, settings
from app.core.security import identity
from app.db import transaction
from app.schemas import Choices, ResponseDecision, SeatChange, Simulation, SpotRequest
from app.storage import storage

router = APIRouter()


def call(name, args=(), user=None, repeatable=False):
    for attempt in range(3):
        try:
            with transaction(user["user_id"] if user else None, repeatable=repeatable) as conn:
                query = sql.SQL("SELECT admission.{}({}) AS value").format(sql.Identifier(name), sql.SQL(",").join(sql.Placeholder() for _ in args))
                return conn.execute(query, args).fetchone()["value"]
        except DatabaseError as exc:
            if exc.sqlstate not in ("40001", "40P01") or attempt == 2:
                if user and name not in ('log_operation_failure',):
                    try:
                        with transaction(user['user_id']) as failure_conn:
                            failure_conn.execute('SELECT admission.log_operation_failure(%s,%s)', (name, exc.sqlstate or 'UNKNOWN'))
                    except DatabaseError:
                        pass
                raise
            time.sleep(random.uniform(0.02, 0.08) * (attempt + 1))


class Review(BaseModel):
    approve: bool
    reason: str = Field(default="", max_length=500)


class ExamInput(BaseModel):
    category: Literal["OPEN", "EWS", "OBC_NCL", "SC", "ST"]
    total_marks: int = Field(ge=0, le=300)
    crl_rank: int = Field(gt=0)
    cat_rank: int | None = Field(default=None, gt=0)


class Publish(BaseModel):
    idempotency_key: str = Field(min_length=8, max_length=100)


class Deadline(BaseModel):
    deadline: str = Field(max_length=80)


@router.get("/workspace")
def workspace(user=Depends(identity)):
    return call("workspace", user=user)


@router.put("/me/choices/{year}")
def save_choices(year: int, data: Choices, lock: bool = False, user=Depends(identity)):
    call("save_choices", (year, data.program_ids, lock), user)
    return {"saved": True, "locked": lock}


@router.post("/me/applications/{year}/submit")
def submit(year: int, user=Depends(identity)):
    call("submit_application", (year,), user)
    return {"submitted": True}


@router.put("/me/rounds/{round_id}/response")
def respond(round_id: int, data: ResponseDecision, user=Depends(identity)):
    call("respond", (round_id, data.decision), user)
    return {"saved": True}


@router.get("/me/rounds/{round_id}/why-not")
def why_not(round_id: int, user=Depends(identity)):
    return call("why_not", (round_id,), user)


@router.get("/me/chances/{year}")
def chances(year: int, user=Depends(identity)):
    return call("my_chances", (year,), user)


@router.post("/simulations", status_code=201)
def simulate(data: Simulation, user=Depends(identity)):
    sid = call("run_allocation", (data.round_id, Jsonb(data.scenario), data.base_sim_id, False, None), user, repeatable=True)
    return call("simulation_analysis", (sid,), user)


@router.get("/simulations/{sim_id}")
def simulation(sim_id: int, user=Depends(identity)):
    return call("simulation_analysis", (sim_id,), user)


@router.post("/admin/rounds/{round_id}/lock")
def lock_round(round_id: int, user=Depends(identity)):
    call("lock_round", (round_id,), user)
    return {"locked": True}


@router.post("/admin/rounds/{round_id}/publish")
def publish(round_id: int, data: Publish, user=Depends(identity)):
    sid = call("run_allocation", (round_id, Jsonb({}), None, True, data.idempotency_key), user, repeatable=True)
    workspace = call('workspace', user=user)
    call('refresh_predictions', (workspace['year'],), user)
    return call("simulation_analysis", (sid,), user)


@router.post("/admin/rounds/{round_id}/close")
def close_round(round_id: int, user=Depends(identity)):
    call("close_round", (round_id,), user)
    return {"closed": True}


@router.post("/admin/rounds/{year}/next")
def next_round(year: int, data: Deadline, user=Depends(identity)):
    return {"round_id": call("create_next_round", (year, data.deadline), user)}


@router.put("/admin/rounds/{round_id}/deadline")
def deadline(round_id: int, data: Deadline, user=Depends(identity)):
    call("set_response_deadline", (round_id, data.deadline), user)
    return {"saved": True}


@router.put("/admin/seat-matrix/{year}/{program_id}/{category}")
def seats(year: int, program_id: int, category: Literal["OPEN", "EWS", "OBC_NCL", "SC", "ST"], data: SeatChange, user=Depends(identity)):
    call("set_seats", (year, program_id, category, data.seats), user)
    return {"saved": True}


@router.post("/admin/applications/{year}/{student_id}/review")
def review(year: int, student_id: int, data: Review, user=Depends(identity)):
    call("review_application", (student_id, year, data.approve, data.reason), user)
    return {"saved": True}


@router.put("/admin/applications/{year}/{student_id}/exam")
def exam(year: int, student_id: int, data: ExamInput, user=Depends(identity)):
    call("record_exam", (student_id, year, data.category, data.total_marks, data.crl_rank, data.cat_rank), user)
    return {"saved": True}


@router.get("/audit/verify")
def verify(user=Depends(identity)):
    return call("verify_ledger", user=user)


@router.get("/audit/seat-history")
def history(year: int, at: str = Query(max_length=80), user=Depends(identity)):
    return call("seat_history", (year, at), user)


@router.get("/spot/{year}")
def spot(year: int, user=Depends(identity)):
    return call("spot_availability", (year,), user)


@router.post("/admin/spot/{year}/open")
def open_spot(year: int, user=Depends(identity)):
    call("open_spot", (year,), user)
    return {"opened": True}


@router.post("/me/spot/accept")
def accept(data: SpotRequest, user=Depends(identity)):
    return call("accept_spot", (data.pool_id, data.idempotency_key), user)


@router.post("/admin/admissions/{year}/{student_id}/finalize")
def finalize(year: int, student_id: int, user=Depends(identity)):
    call("finalize_admission", (student_id, year), user)
    return {"confirmed": True}


@router.post("/me/applications/{year}/documents", status_code=201)
def upload(year: int, file: UploadFile, user=Depends(identity)):
    if user["role"] != "STUDENT":
        raise HTTPException(403, "Only students can submit documents.")
    data = file.file.read(5 * 1024 * 1024 + 1)
    if not data or len(data) > 5 * 1024 * 1024:
        raise HTTPException(422, "Choose a nonempty PDF, PNG or JPEG up to 5 MB.")
    signatures = [(b"%PDF-", "application/pdf"), (b"\x89PNG\r\n\x1a\n", "image/png"), (b"\xff\xd8\xff", "image/jpeg")]
    mime = next((mime for signature, mime in signatures if data.startswith(signature)), None)
    if mime is None:
        raise HTTPException(422, "The file must be a PDF, PNG or JPEG.")
    key = uuid.uuid4().hex
    store = storage()
    store.put(key, data, mime)
    try:
        document_id = call("add_document", (year, Path(file.filename or "document").name[:200], key, mime, hashlib.sha256(data).hexdigest(), len(data)), user)
    except Exception:
        store.delete(key)
        raise
    return {"document_id": document_id, "status": "PENDING"}


@router.get("/documents/{document_id}")
def document(document_id: int, user=Depends(identity)):
    record = call("get_document", (document_id,), user)
    try:
        body = storage().open(record['storage_key'])
    except FileNotFoundError:
        raise HTTPException(404, "Document file is unavailable.")
    def chunks():
        try:
            while chunk := body.read(65536):
                yield chunk
        finally:
            body.close()
    return StreamingResponse(chunks(), media_type=record['mime_type'], headers={'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff', 'Content-Disposition':"attachment; filename*=UTF-8''"+quote(record['original_name'], safe='')})


@router.post("/admin/documents/{document_id}/review")
def review_doc(document_id: int, data: Review, user=Depends(identity)):
    call("review_document", (document_id, data.approve, data.reason), user)
    return {"saved": True}
