"""Private file adapters. S3 is optional and never provisions cloud resources."""
import io
from pathlib import Path

from app.core.config import ROOT, settings


class LocalStorage:
    def __init__(self, directory):
        self.directory = Path(directory).resolve()

    def path(self, key):
        path = (self.directory / key).resolve()
        if path.parent != self.directory:
            raise ValueError('Invalid storage key')
        return path

    def put(self, key, data, mime):
        self.directory.mkdir(parents=True, exist_ok=True)
        self.path(key).write_bytes(data)

    def delete(self, key):
        self.path(key).unlink(missing_ok=True)

    def open(self, key):
        return self.path(key).open('rb')


class S3Storage:
    def __init__(self, bucket, client=None):
        if not bucket:
            raise ValueError('S3_BUCKET is required for private S3 storage')
        if client is None:
            try:
                import boto3
                from botocore.config import Config
            except ImportError as exc:
                raise RuntimeError('Install the backend s3 extra before selecting S3 storage') from exc
            client = boto3.client('s3', endpoint_url=settings.s3_endpoint, region_name=settings.s3_region,
                                  config=Config(signature_version='s3v4', s3={'addressing_style': 'path'}))
        self.bucket, self.client = bucket, client

    def put(self, key, data, mime):
        self.client.put_object(Bucket=self.bucket, Key=key, Body=data, ContentType=mime)

    def delete(self, key):
        self.client.delete_object(Bucket=self.bucket, Key=key)

    def open(self, key):
        return self.client.get_object(Bucket=self.bucket, Key=key)['Body']


def storage():
    if settings.storage_backend == 'local':
        return LocalStorage(ROOT / settings.upload_dir)
    if settings.storage_backend == 's3':
        return S3Storage(settings.s3_bucket)
    raise ValueError('STORAGE_BACKEND must be local or s3')
