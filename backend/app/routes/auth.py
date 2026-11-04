import json
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, Response

from app.core.config import ROOT, settings
from app.core.security import digest, dummy_hash, identity, passwords, rate_limit, verify_password
from app.db import transaction
from app.schemas import Login, Register

router = APIRouter()


def start_session(user_id, response):
    token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    with transaction() as conn:
        conn.execute("SELECT admission.create_session(%s,%s,%s,%s)", (user_id, digest(token), digest(csrf), datetime.now(timezone.utc) + timedelta(hours=settings.session_hours)))
    for name, value, http_only in [("admission_session", token, True), ("admission_csrf", csrf, False)]:
        response.set_cookie(name, value, httponly=http_only, secure=settings.cookie_secure, samesite="lax", max_age=settings.session_hours * 3600, path="/")
    return {"authenticated": True, "csrf_token": csrf}


@router.post("/auth/login")
def login(data: Login, request: Request, response: Response):
    rate_limit(request, data.email)
    with transaction() as conn:
        record = conn.execute("SELECT admission.login_record(%s) AS value", (data.email,)).fetchone()["value"]
    valid = verify_password(data.password, record["password_hash"] if record else dummy_hash)
    if not valid or not record or not record["enabled"]:
        raise HTTPException(401, "Email or password is incorrect.")
    return start_session(record["user_id"], response)


@router.post("/auth/register", status_code=201)
def register(data: Register, request: Request, response: Response):
    rate_limit(request, data.email)
    if "@" not in data.email or len(data.password) < 10:
        raise HTTPException(422, "Use a valid email and a password of at least 10 characters.")
    with transaction() as conn:
        uid = conn.execute("SELECT admission.register_student(%s,%s,%s) AS value", (data.email, data.full_name, passwords.hash(data.password))).fetchone()["value"]
    return start_session(uid, response)


@router.get("/auth/me")
def me(user=Depends(identity)):
    return {key: value for key, value in user.items() if key != "csrf_hash"}


@router.post("/auth/logout")
def logout(request: Request, response: Response, user=Depends(identity)):
    with transaction() as conn:
        conn.execute("SELECT admission.remove_session(%s)", (digest(request.cookies["admission_session"]),))
    response.delete_cookie("admission_session", path="/")
    response.delete_cookie("admission_csrf", path="/")
    return {"authenticated": False}


@router.get("/dev/accounts")
def demo_accounts():
    if settings.app_env != "development":
        raise HTTPException(404)
    file = ROOT / ".local/demo-accounts.json"
    if not file.exists():
        return []
    accounts = json.loads(file.read_text())
    return [a for a in accounts if a["role"] != "STUDENT" or a.get("student_id") == 1]
