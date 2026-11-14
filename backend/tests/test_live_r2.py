"""Opt-in smoke test using only the configured bucket's tests/ prefix."""

import os
from dataclasses import replace
from urllib.parse import urlsplit
from uuid import uuid4

import httpx
import pytest
from botocore.exceptions import ClientError
from sqlalchemy import select
from sqlalchemy.orm import Session

from feedbasket import r2, scheduler
from feedbasket.config import Config
from feedbasket.db import Article, Job

pytestmark = pytest.mark.skipif(
    os.getenv("FEEDBASKET_LIVE_R2_TESTS") != "1",
    reason="Set FEEDBASKET_LIVE_R2_TESTS=1 to use Cloudflare R2",
)


def test_live_pdf_upload_download_and_delete(backend_config, start_backend, account_headers, pdf_bytes):
    configured = Config.load()
    endpoint = urlsplit(configured.r2_endpoint_url)
    if not configured.r2_configured or not endpoint.hostname.endswith(".r2.cloudflarestorage.com"):
        pytest.fail("Set the Cloudflare R2 S3 endpoint, bucket, access key and secret key.")

    config = replace(
        backend_config, r2_endpoint_url=configured.r2_endpoint_url, r2_bucket=configured.r2_bucket,
        r2_access_key_id=configured.r2_access_key_id, r2_secret_access_key=configured.r2_secret_access_key,
        pdf_prefix=f"tests/{uuid4()}/", backup_destination="local",
    )
    s3 = r2.client(config)
    bucket = config.r2_bucket
    # R2 represents an empty folder as a zero-byte object with a trailing slash.
    try:
        s3.put_object(Bucket=bucket, Key="tests/", Body=b"", IfNoneMatch="*")
    except ClientError as error:
        if error.response["ResponseMetadata"]["HTTPStatusCode"] != 412:
            raise

    data = pdf_bytes()
    import_id = str(uuid4())
    with start_backend(config) as (app, client):
        owner, = account_headers(app, "live-r2-reader")
        client.headers.update(owner)
        engine = app.state.engine
        try:
            response = client.post("/api/v1/pdfs/import", params={
                "import_id": import_id, "filename": "FeedBasket smoke test.pdf", "tags": ["smoke-test"],
            }, content=data, headers={"Content-Type": "application/pdf"})
            assert response.status_code == 201, response.text
            item = response.json()
            assert item["tags"] == ["smoke-test"] and item["pdf"]["size_bytes"] == len(data)
            with Session(engine) as db:
                key = db.get(Article, item["id"]).pdf_key
            assert key.startswith(config.pdf_prefix)
            assert s3.head_object(Bucket=bucket, Key=key)["ContentLength"] == len(data)

            pdf_path = f"/api/v1/pdfs/{item['id']}"
            article_path = f"/api/v1/articles/{item['id']}"
            download = client.get(f"{pdf_path}/download")
            assert download.status_code == 200
            with httpx.Client(timeout=15) as remote:
                response = remote.get(download.json()["url"])
                assert response.status_code == 200 and response.content == data
            assert client.get("/api/v1/storage").json()["pdf_used_bytes"] == len(data)
            assert client.delete(article_path).json()["location"] == "trash"
            deletion = client.delete(f"{pdf_path}/permanent")
            assert deletion.status_code == 202
            assert scheduler.tick(engine, config)
            with Session(engine) as db:
                assert db.get(Job, deletion.json()["job_id"]).status == "done"
                assert db.get(Article, item["id"]) is None
            assert client.get("/api/v1/storage").json()["pdf_used_bytes"] == 0
            assert s3.list_objects_v2(Bucket=bucket, Prefix=config.pdf_prefix)["KeyCount"] == 0
        finally:
            with Session(engine) as db:
                leftover = db.scalar(select(Article.pdf_key).where(Article.pdf_import_id == import_id))
            if leftover and leftover.startswith(config.pdf_prefix):
                s3.delete_object(Bucket=bucket, Key=leftover)
