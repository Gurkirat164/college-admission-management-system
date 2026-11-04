from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

ROOT = Path(__file__).resolve().parents[3]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=ROOT / "backend" / ".env", extra="ignore")
    database_url: str = "postgresql://invalid@127.0.0.1:55432/admission"
    migration_database_url: str = ""
    app_env: str = "development"
    frontend_origin: str = "http://127.0.0.1:5173"
    cookie_secure: bool = False
    upload_dir: str = ".local/uploads"
    session_hours: int = 8
    storage_backend: str = "local"
    s3_bucket: str = ""
    s3_endpoint: str | None = None
    s3_region: str = "ap-southeast-1"
    scheduler_user_id: int = 0
    mock_run_time: str = "02:00"
    scheduler_timezone: str = "Asia/Kolkata"
    proxy_secret: str = ""
    job_token: str = ""


settings = Settings()
