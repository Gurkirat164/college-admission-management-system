import hashlib
import hmac

from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from fastapi import HTTPException, Request

from app.core.config import settings
from app.db import transaction

passwords = PasswordHasher()
dummy_hash = passwords.hash("unused-timing-placeholder")


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def verify_password(password: str, password_hash: str) -> bool:
    try:
        return passwords.verify(password_hash, password)
    except VerificationError:
        return False


def rate_limit(request: Request, email: str = ""):
    key = request.client.host if request.client else "local"
    if settings.proxy_secret and hmac.compare_digest(request.headers.get('x-admission-proxy', ''), settings.proxy_secret):
        key = request.headers.get('x-forwarded-for', key)
    # Limits are counted in PostgreSQL (login_attempt), so they hold across API restarts and instances.
    with transaction() as conn:
        allowed = conn.execute("SELECT admission.record_login_attempt(%s,%s) AS value", (digest(key), digest(email.strip().lower()))).fetchone()["value"]
    if not allowed:
        raise HTTPException(429, "Too many login attempts. Try again in a minute.")


def identity(request: Request):
    token = request.cookies.get("admission_session")
    if not token:
        raise HTTPException(401, "Sign in to continue.")
    with transaction() as conn:
        user = conn.execute("SELECT admission.session_identity(%s) AS value", (digest(token),)).fetchone()["value"]
    if not user:
        raise HTTPException(401, "Your session expired. Sign in again.")
    if request.method not in ("GET", "HEAD", "OPTIONS"):
        csrf = request.headers.get("X-CSRF-Token", "")
        if not hmac.compare_digest(digest(csrf), user["csrf_hash"]):
            raise HTTPException(403, "Security token missing. Reload and try again.")
    return user
