import logging
import secrets
from urllib.parse import urlparse
from contextlib import asynccontextmanager

import psycopg
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from psycopg_pool import PoolTimeout

from app.core.config import settings
from app.db import pool, transaction
from app.routes import auth, workflows, complete


@asynccontextmanager
async def lifespan(app):
    if settings.app_env == 'production' and (not settings.cookie_secure or urlparse(settings.frontend_origin).scheme!='https'):
        raise RuntimeError('Production requires COOKIE_SECURE=true and an HTTPS frontend origin')
    pool.open()
    yield
    pool.close()


app = FastAPI(title="College Admission API", version="0.1.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=[settings.frontend_origin], allow_credentials=True, allow_methods=["GET", "POST", "PUT", "PATCH"], allow_headers=["Content-Type", "X-CSRF-Token"])
app.include_router(auth.router, prefix="/api/v1")
app.include_router(workflows.router, prefix="/api/v1")
app.include_router(complete.router, prefix="/api/v1")


@app.middleware("http")
async def request_security(request: Request, call_next):
    origin = request.headers.get("origin")
    if request.url.path.startswith('/api/') and settings.proxy_secret and request.url.path not in ('/api/v1/health', '/api/v1/ready'):
        if not secrets.compare_digest(request.headers.get('x-admission-proxy', ''), settings.proxy_secret):
            return JSONResponse({'detail': 'Use the admission website to access this service.'}, status_code=403)
    if request.method not in ("GET", "HEAD", "OPTIONS") and origin and origin != settings.frontend_origin:
        return JSONResponse({"detail": "Request origin is not allowed."}, status_code=403)
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Frame-Options"] = "DENY"
    return response


@app.exception_handler(psycopg.Error)
def database_error(request, exc):
    code = exc.sqlstate
    if code == "42501":
        status, message = 403, exc.diag.message_primary
    elif code == "P0002":
        status, message = 404, "Record not found."
    elif code == "P0001":
        status, message = 409, exc.diag.message_primary
    elif code in ("23505", "23503", "23514", "23502", "22P02", "22003", "22007", "22023", "22008"):
        status, message = 422, "The submitted values conflict with admission records or validation rules."
    elif code in ("40001", "40P01", "57014"):
        status, message = 409, "Another operation changed these records. Refresh and try again."
    else:
        logging.getLogger("admission").error("Database operation failed with SQLSTATE %s", code)
        status, message = 503, "Database request could not complete. Please try again shortly."
    return JSONResponse({"detail": message}, status_code=status)


@app.exception_handler(PoolTimeout)
def database_timeout(request, exc):
    return JSONResponse({"detail": "The admission database is starting. Please try again shortly."}, status_code=503)


@app.get("/api/v1/health")
def health():
    return {"status": "ok", "service": "admission-api"}


@app.get("/api/v1/ready")
def ready():
    with transaction() as conn:
        conn.execute("SELECT 1")
    return {"status": "ready", "database": "postgresql"}


@app.post('/internal/jobs/daily')
def daily_jobs(request: Request):
    if not settings.job_token or not secrets.compare_digest(request.headers.get('authorization', ''), 'Bearer ' + settings.job_token):
        return JSONResponse({'detail': 'Unauthorized'}, status_code=401)
    from app.jobs.worker import tick
    results = tick()
    return JSONResponse({'results': results}, status_code=503 if any(r['status'] == 'FAILED' for r in results) else 200)
