"""S3 operations for the private PDF bucket."""

from contextlib import contextmanager
from functools import lru_cache
from urllib.parse import urlsplit, urlunsplit

import boto3
from botocore.config import Config as S3Config
from botocore.exceptions import BotoCoreError, ClientError

DOWNLOAD_SECONDS = 300


class StorageUnavailable(Exception):
    def __init__(self):
        super().__init__("PDF storage is unavailable. Try again.")


@lru_cache(maxsize=4)
def client(config):
    endpoint = urlunsplit(urlsplit(config.r2_endpoint_url)._replace(path=""))
    return boto3.session.Session().client(
        "s3", endpoint_url=endpoint, region_name="auto",
        aws_access_key_id=config.r2_access_key_id, aws_secret_access_key=config.r2_secret_access_key,
        config=S3Config(signature_version="s3v4", s3={"addressing_style": "path"},
                        connect_timeout=5, read_timeout=30, retries={"total_max_attempts": 2, "mode": "standard"},
                        request_checksum_calculation="when_required", response_checksum_validation="when_required"),
    )


@contextmanager
def operation(config):
    if not config.r2_configured:
        raise StorageUnavailable()
    try:
        yield client(config)
    except (BotoCoreError, ClientError) as error:
        raise StorageUnavailable() from error


def upload(config, key, file, size, digest):
    with operation(config) as s3:
        try:
            s3.put_object(Bucket=config.r2_bucket, Key=key, Body=file, ContentLength=size,
                          ContentType="application/pdf", Metadata={"sha256": digest}, IfNoneMatch="*")
        except ClientError as error:
            if error.response["ResponseMetadata"]["HTTPStatusCode"] != 412:
                raise
            existing = s3.head_object(Bucket=config.r2_bucket, Key=key)
            if existing["ContentLength"] != size or existing.get("Metadata", {}).get("sha256") != digest:
                raise StorageUnavailable() from error


def download_url(config, key):
    with operation(config) as s3:
        return s3.generate_presigned_url("get_object", Params={"Bucket": config.r2_bucket, "Key": key},
                                         ExpiresIn=DOWNLOAD_SECONDS)


def delete(config, key):
    with operation(config) as s3:
        s3.delete_object(Bucket=config.r2_bucket, Key=key)
