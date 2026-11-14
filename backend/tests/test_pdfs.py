from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from hashlib import sha256
from pathlib import Path
from uuid import uuid4

import httpx
import pytest
from alembic import command
from alembic.config import Config as AlembicConfig
from fastapi.testclient import TestClient
from sqlalchemy import select, text

from feedbasket import auth, scheduler
from feedbasket.config import Config
from feedbasket.db import Article, Highlight, Job, make_engine, write
from feedbasket.main import create_app


def headers(token):
    return {"Authorization": f"Bearer {token}"}


def test_migration_reclassifies_legacy_pdf_and_syncs_change(tmp_path):
    config = Config(db_path=tmp_path / "legacy.sqlite", backup_frequency="disabled")
    engine = make_engine(config.db_path)
    migrations = AlembicConfig()
    migrations.set_main_option("script_location", str(Path(__file__).parents[1] / "migrations"))
    highlight_id = str(uuid4())
    try:
        with engine.begin() as connection:
            migrations.attributes["connection"] = connection
            command.upgrade(migrations, "0007")
            connection.execute(text("""
                INSERT INTO accounts (id, google_sub, email, name, picture, username, quota)
                VALUES ('owner', 'local:owner', 'owner@local.invalid', 'owner', '', 'owner', 100)
            """))
            connection.execute(text("""
                INSERT INTO articles
                    (id, account_id, url, title, author, created_at, saved_at, read, location,
                     state_at, read_at, excerpt, body_bytes, content_status)
                VALUES ('legacy-pdf', 'owner', 'https://example.test/document', 'Saved report', '',
                        1, 1, 0, 'inbox', 1, 1, '', 0, 'pdf_unsupported')
            """))
            connection.execute(text("INSERT INTO article_tags (article_id, tag) VALUES ('legacy-pdf', 'research')"))
            command.upgrade(migrations, "0008")
            connection.execute(text("""
                INSERT INTO highlights (id, article_id, style, quote, color, anchor, created_at)
                VALUES (:id, 'legacy-pdf', 'highlight', 'Saved passage', '#ffe873', '{"kind":"pdf"}', 1)
            """), {"id": highlight_id})
            connection.execute(text("""
                INSERT INTO changes (account_id, kind, object_id, operation)
                VALUES ('owner', 'highlight', :id, 'upsert')
            """), {"id": highlight_id})
    finally:
        engine.dispose()
    app = create_app(config, start_worker=False)
    with TestClient(app, base_url=config.public_url) as client:
        with write(app.state.engine) as db:
            owner = headers(auth.issue_session(db, "owner"))
        item = client.get("/api/v1/articles/legacy-pdf", headers=owner).json()
        assert item["document_type"] == "pdf" and item["content_status"] == "ready"
        assert item["tags"] == ["research"] and item["url"] == "https://example.test/document"
        changes = client.get("/api/v1/sync", headers=owner).json()["items"]
        item_change, highlight_change = changes
        assert item_change["id"] == "legacy-pdf" and item_change["data"]["document_type"] == "pdf"
        assert highlight_change["id"] == highlight_id and highlight_change["data"]["quote"] == "Saved passage"
        with write(app.state.engine) as db:
            assert db.get(Highlight, ("owner", highlight_id)).article_id == "legacy-pdf"


def test_linked_pdfs_share_tags_and_highlights_across_restart(backend_config, start_backend, account_headers):
    config = backend_config
    link = "https://example.test/download?utm_source=signed&token=abc#page=4"
    with start_backend(config) as (app, client):
        owner, other = account_headers(app, "pdf-owner", "other")
        client.headers.update(owner)
        save = {"url": link, "document_type": "pdf", "tags": [" Research "]}
        pdf = client.post("/api/v1/articles", json=save).json()["article"]
        assert pdf["url"] == link and pdf["pdf"]["source"] == "link"
        assert client.post("/api/v1/articles", json=save).json()["article"]["id"] == pdf["id"]
        assert client.get(f"/api/v1/pdfs/{pdf['id']}/download").json() == {"url": link, "expires_in": None}
        with write(app.state.engine) as db:
            assert db.scalar(select(Job)) is None
            stored = db.get(Article, pdf["id"])
            assert stored.body is None and stored.pdf_key is None

        article = client.post("/api/v1/articles", json={"url": "https://example.test/article", "tags": ["research"]})
        article_id = article.json()["article"]["id"]
        assert client.get("/api/v1/tags?ranked=true").json() == [{"name": "research", "count": 2}]
        params = {"source": "saved", "tag": "research", "document_type": "pdf"}
        assert [item["id"] for item in client.get("/api/v1/articles", params=params).json()["items"]] == [pdf["id"]]
        cursor = client.get("/api/v1/sync").json()["cursor"]
        position = f"/api/v1/pdfs/{pdf['id']}/position"
        saved_position = client.put(position, json={"page": 4, "offset": 0.3}).json()
        assert client.put(position, json={"page": 1, "offset": 0, "updated_at": 1}).json() == saved_position
        mark_data = {"id": str(uuid4()), "style": "underline", "quote": "Side channels carry water.",
                     "anchor": {"kind": "pdf", "quads": [{"page": 4, "points": [0.1, 0.2, 0.6, 0.2, 0.1, 0.3, 0.6, 0.3]}]}}
        mark_path = f"/api/v1/articles/{pdf['id']}/highlights"
        assert client.post(mark_path, json=mark_data).status_code == 201
        assert client.post(mark_path, json=mark_data).status_code == 201
        assert client.post(f"/api/v1/articles/{article_id}/highlights", json={
            "quote": "Rivers can heal.", "anchor": {"kind": "article", "suffix": " given a little room"},
        }).status_code == 201
        assert client.get("/api/v1/highlights?tag=research&search=side").json()["items"][0]["id"] == mark_data["id"]
        client.patch(f"/api/v1/articles/{pdf['id']}", json={"tags": ["rivers"]})
        assert client.get("/api/v1/highlights?tag=research&document_type=pdf").json()["items"] == []
        assert client.get(position.removesuffix("/position") + "/download", headers=other).status_code == 404
        assert client.get("/api/v1/highlights", headers=other).json()["items"] == []

    with start_backend(config, headers=owner) as (_, client):
        changes = client.get("/api/v1/sync", params={"after": cursor}).json()["items"]
        assert any(change["kind"] == "highlight" and change["id"] == mark_data["id"] for change in changes)
        item = client.get(f"/api/v1/articles/{pdf['id']}").json()
        assert item["reading_position"] == saved_position and not item["read"]
        assert client.get("/api/v1/storage").json()["pdf_used_bytes"] == 0
        client.delete(f"/api/v1/articles/{pdf['id']}")
        assert client.delete(f"/api/v1/pdfs/{pdf['id']}/permanent").status_code == 204
        assert client.get(f"/api/v1/articles/{pdf['id']}").status_code == 404
        changes = client.get("/api/v1/sync", params={"after": cursor}).json()["items"]
        assert any(change["operation"] == "delete" and change["id"] == mark_data["id"] for change in changes)


def test_highlight_uuid_is_scoped_to_account(backend_config, start_backend, account_headers):
    with start_backend(backend_config) as (app, client):
        owner, other = account_headers(app, "pdf-owner", "other")
        article_ids = [
            client.post("/api/v1/articles", json={"url": "https://example.test/document.pdf"},
                        headers=account).json()["article"]["id"]
            for account in (owner, other)
        ]
        mark_id = str(uuid4())
        mark = {"id": mark_id, "quote": "Owner highlight", "anchor": {
            "kind": "pdf", "quads": [{"page": 1, "points": [0.1, 0.2, 0.6, 0.2, 0.1, 0.3, 0.6, 0.3]}],
        }}
        for account, article_id, quote in zip((owner, other), article_ids, ("Owner highlight", "Other highlight")):
            response = client.post(f"/api/v1/articles/{article_id}/highlights", json=mark | {"quote": quote}, headers=account)
            assert response.status_code == 201 and response.json()["id"] == mark_id
        assert client.delete(f"/api/v1/highlights/{mark_id}", headers=owner).status_code == 204
        owner_marks = [item for item in client.get("/api/v1/sync", headers=owner).json()["items"]
                       if item["kind"] == "highlight"]
        assert [(item["id"], item["operation"], item["data"]) for item in owner_marks] == [(mark_id, "delete", None)]
        other_marks = client.get("/api/v1/highlights", headers=other).json()["items"]
        assert [(item["id"], item["quote"]) for item in other_marks] == [(mark_id, "Other highlight")]
        assert client.delete(f"/api/v1/highlights/{mark_id}", headers=owner).status_code == 404
        with write(app.state.engine) as db:
            surviving = db.scalars(select(Highlight).where(Highlight.id == mark_id)).one()
            assert surviving.account_id == db.get(Article, article_ids[1]).account_id


def test_pdf_link_deduplicates_exact_url_and_keeps_distinct_queries(backend_config, start_backend, account_headers):
    with start_backend(backend_config) as (app, client):
        owner, = account_headers(app, "pdf-owner")
        client.headers.update(owner)
        path = "/api/v1/articles"
        url = "https://example.test/download?utm_source=signature-a&token=secret#page=4"
        article = client.post(path, json={"url": url, "tags": ["research"]}).json()["article"]
        first = client.post(path, json={"url": url, "document_type": "pdf"}).json()["article"]
        assert first["id"] == article["id"] and first["tags"] == ["research"] and first["url"] == url
        second_url = url.replace("signature-a", "signature-b")
        second = client.post(path, json={"url": second_url, "document_type": "pdf"}).json()["article"]
        assert second["id"] != first["id"] and second["url"] == second_url
        assert client.post(path, json={"url": url}).json()["article"]["id"] == first["id"]
        assert len(client.get(path, params={"document_type": "pdf"}).json()["items"]) == 2

        signed_url = "https://example.test/another?utm_source=required"
        signed_article = client.post(path, json={"url": signed_url}).json()["article"]
        unsigned = client.post(path, json={"url": signed_url.split("?")[0], "document_type": "pdf"}).json()["article"]
        signed = client.post(path, json={"url": signed_url, "document_type": "pdf"}).json()["article"]
        assert signed["id"] == signed_article["id"] and signed["id"] != unsigned["id"]


@pytest.fixture
def upload_backend(backend_config, s3_endpoint):
    endpoint, root = s3_endpoint
    config = replace(backend_config, r2_endpoint_url=f"http://127.0.0.1:{endpoint.server_port}/test-bucket", r2_bucket="test-bucket",
                    r2_access_key_id="fixture-access", r2_secret_access_key="fixture-secret")
    return config, endpoint, root / config.pdf_prefix


def test_r2_upload_reconciles_commit_after_lost_response_and_restart(upload_backend, pdf_bytes, start_backend, account_headers):
    config, endpoint, files = upload_backend
    params = {"import_id": str(uuid4()), "filename": "River guide.pdf", "tags": ["research", "rivers"]}
    path = "/api/v1/pdfs/import"
    data = pdf_bytes()
    with start_backend(config) as (app, client):
        owner, = account_headers(app, "pdf-owner")
        endpoint.drop_upload_response = True
        assert client.post(path, params=params, content=data, headers=owner).status_code == 503
        assert client.get("/api/v1/articles?source=saved", headers=owner).json()["items"] == []
        assert client.get("/api/v1/tags?ranked=true", headers=owner).json() == []
        with write(app.state.engine) as db:
            pending = db.scalar(select(Article).where(Article.pdf_import_id == params["import_id"]))
            pending_id = pending.id
            object_path = files.parent / pending.pdf_key
            assert pending.saved_at is None
        assert object_path.read_bytes() == data
    endpoint.drop_upload_response = False
    with start_backend(config, headers=owner) as (_, client):
        result = client.post(path, params=params, content=data)
        assert result.status_code == 201, result.text
        item = result.json()
        assert item["id"] == pending_id
        assert client.post(path, params=params, content=data).json()["id"] == pending_id
        assert client.post(path, params=params, content=pdf_bytes(3)).status_code == 409
        assert client.get("/api/v1/storage").json()["pdf_used_bytes"] == len(data)
        assert list(files.rglob("*.pdf")) == [object_path]


def test_abandoned_upload_releases_reserved_quota_and_removes_object(upload_backend, pdf_bytes, start_backend, account_headers):
    config, endpoint, files = upload_backend
    data = pdf_bytes()
    with start_backend(config) as (app, client):
        owner, = account_headers(app, "pdf-owner")
        client.headers.update(owner)
        params = {"import_id": str(uuid4()), "filename": "Abandoned.pdf", "tags": ["pending-only"]}
        path = "/api/v1/pdfs/import"
        assert client.patch("/api/v1/storage/pdfs", json={"quota_bytes": len(data)}).status_code == 200
        endpoint.drop_upload_response = True
        assert client.post(path, params=params, content=data).status_code == 503
        endpoint.drop_upload_response = False
        replacement = params | {"import_id": str(uuid4())}
        assert client.post(path, params=replacement, content=data).status_code == 409
        assert client.get("/api/v1/tags?ranked=true").json() == []
        assert len(list(files.rglob("*.pdf"))) == 1
        with write(app.state.engine) as db:
            abandoned = db.scalar(select(Article).where(Article.pdf_import_id == params["import_id"]))
            abandoned_id = abandoned.id
            abandoned.pdf_expires_at = 0
            job = db.scalar(select(Job).where(Job.kind == "pdf_cleanup"))
            job.run_at = 0
        assert scheduler.tick(app.state.engine, config)
        assert list(files.rglob("*.pdf")) == []
        with write(app.state.engine) as db:
            assert db.get(Article, abandoned_id) is None
        assert client.get("/api/v1/sync").json()["items"] == []
        assert client.post(path, params=replacement, content=data).status_code == 201


@pytest.mark.parametrize(("content", "quota_delta", "status"), [
    pytest.param(b"ID3 fake audio", 0, 415, id="audio"),
    pytest.param(b"%PDF-1.7\ninvalid", 0, 415, id="corrupt-pdf"),
    pytest.param(None, -1, 409, id="over-quota"),
    pytest.param(None, 0, 201, id="exact-quota"),
])
def test_r2_upload_validation_and_quota(upload_backend, pdf_bytes, content, quota_delta, status,
                                        start_backend, account_headers):
    config, _, files = upload_backend
    data = pdf_bytes()
    with start_backend(config) as (app, client):
        owner, other = account_headers(app, "pdf-owner", "other")
        client.headers.update(owner)
        params = {"import_id": str(uuid4()), "filename": "River guide.pdf", "tags": ["research", "rivers"]}
        assert client.patch("/api/v1/storage/pdfs", json={"quota_bytes": len(data) + quota_delta}).status_code == 200
        result = client.post("/api/v1/pdfs/import", params=params, content=data if content is None else content)
        assert result.status_code == status, result.text
        with write(app.state.engine) as db:
            stored = list(db.scalars(select(Article)))
            assert len(stored) == (1 if status == 201 else 0)
        storage = client.get("/api/v1/storage").json()
        assert storage["used_bytes"] == 0
        if status != 201:
            assert storage["pdf_used_bytes"] == 0 and list(files.rglob("*.pdf")) == []
            assert client.get("/api/v1/sync").json()["items"] == []
            return

        item = result.json()
        assert item["tags"] == ["research", "rivers"]
        assert item["pdf"]["page_count"] == 2 and item["pdf"]["size_bytes"] == len(data)
        assert storage["pdf_used_bytes"] == len(data)
        article_path = f"/api/v1/articles/{item['id']}"
        pdf_path = f"/api/v1/pdfs/{item['id']}"
        assert client.get(f"{pdf_path}/download", headers=other).status_code == 404
        download = client.get(f"{pdf_path}/download").json()
        assert httpx.get(download["url"], timeout=5).content == data
        assert client.put(f"{pdf_path}/position", json={"page": 3, "offset": 0}).status_code == 422
        assert client.put(f"{pdf_path}/position", json={"page": 2, "offset": 0.7}).status_code == 200
        mark = client.post(f"{article_path}/highlights", json={"quote": "summary", "anchor": {
            "kind": "pdf", "quads": [{"page": 2, "points": [0.1, 0.2, 0.6, 0.2, 0.1, 0.3, 0.6, 0.3]}],
        }})
        assert mark.status_code == 201
        assert mark.json()["anchor"]["document_revision"] == sha256(data).hexdigest()


def test_r2_concurrent_uploads_compete_for_last_quota_slot(upload_backend, pdf_bytes, start_backend, account_headers):
    config, endpoint, files = upload_backend
    data = pdf_bytes()
    with start_backend(config) as (app, client):
        owner, = account_headers(app, "pdf-owner")
        client.headers.update(owner)
        assert client.patch("/api/v1/storage/pdfs", json={"quota_bytes": len(data)}).status_code == 200
        endpoint.block_upload = True

        def upload():
            return client.post("/api/v1/pdfs/import", params={
                "import_id": str(uuid4()), "filename": "Guide.pdf",
            }, content=data)

        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(upload)
            try:
                assert endpoint.upload_started.wait(timeout=5)
                rejected = pool.submit(upload).result(timeout=5)
                assert rejected.status_code == 409
            finally:
                endpoint.release_upload.set()
            saved = first.result(timeout=5)
        assert saved.status_code == 201
        with write(app.state.engine) as db:
            stored, = db.scalars(select(Article)).all()
            assert stored.id == saved.json()["id"] and stored.saved_at is not None
        assert len(list(files.rglob("*.pdf"))) == 1
        assert client.get("/api/v1/storage").json()["pdf_used_bytes"] == len(data)


@pytest.mark.parametrize("fault", ["fail_delete", "drop_delete_response"], ids=["object-remains", "object-already-gone"])
def test_r2_permanent_delete_recovers_after_restart(upload_backend, pdf_bytes, start_backend, account_headers, fault):
    config, endpoint, files = upload_backend
    data = pdf_bytes()
    with start_backend(config) as (app, client):
        owner, other = account_headers(app, "pdf-owner", "other")
        client.headers.update(owner)
        result = client.post("/api/v1/pdfs/import", params={
            "import_id": str(uuid4()), "filename": "Guide.pdf",
        }, content=data)
        assert result.status_code == 201, result.text
        item = result.json()
        object_path, = files.rglob("*.pdf")
        article_path = f"/api/v1/articles/{item['id']}"
        pdf_path = f"/api/v1/pdfs/{item['id']}"
        mark = client.post(f"{article_path}/highlights", json={"quote": "summary", "anchor": {
            "kind": "pdf", "quads": [{"page": 2, "points": [0.1, 0.2, 0.6, 0.2, 0.1, 0.3, 0.6, 0.3]}],
        }}).json()
        assert client.delete(f"{pdf_path}/permanent").status_code == 409
        assert client.delete(article_path).json()["location"] == "trash"
        assert client.get("/api/v1/storage").json()["pdf_used_bytes"] == len(data)
        assert client.patch(article_path, json={"action": "restore"}).json()["location"] == "inbox"
        assert client.delete(article_path).status_code == 200
        setattr(endpoint, fault, True)
        deletion = client.delete(f"{pdf_path}/permanent")
        assert deletion.status_code == 202
        job_id = deletion.json()["job_id"]
        assert client.delete(f"{pdf_path}/permanent").json()["job_id"] == job_id
        assert client.patch(article_path, json={"action": "restore"}).status_code == 409
        before = client.get("/api/v1/sync").json()["cursor"]
        assert scheduler.tick(app.state.engine, config)
        assert object_path.is_file() == (fault == "fail_delete")
        assert client.get(f"/api/v1/jobs/{job_id}").json()["status"] == "queued"
        assert client.get("/api/v1/storage").json()["pdf_used_bytes"] == len(data)

    setattr(endpoint, fault, False)
    with start_backend(config, headers=owner) as (app, client):
        with write(app.state.engine) as db:
            db.get(Job, job_id).run_at = 0
        assert scheduler.tick(app.state.engine, config)
        assert not object_path.exists()
        assert client.get(article_path).status_code == 404
        assert client.get(f"/api/v1/jobs/{job_id}").json()["status"] == "done"
        assert client.get(f"/api/v1/jobs/{job_id}", headers=other).status_code == 404
        assert client.get("/api/v1/storage").json()["pdf_used_bytes"] == 0
        with write(app.state.engine) as db:
            assert db.get(Article, item["id"]) is None
            assert db.scalar(select(Highlight).where(Highlight.id == mark["id"])) is None
        changes = client.get("/api/v1/sync", params={"after": before}).json()["items"]
        assert {(change["kind"], change["operation"], change["id"]) for change in changes} == {
            ("article", "delete", item["id"]), ("highlight", "delete", mark["id"]),
        }
