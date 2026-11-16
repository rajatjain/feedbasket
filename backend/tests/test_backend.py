import re
import shutil
import sqlite3
from contextlib import closing
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config as AlembicConfig
from fastapi import HTTPException
from fastapi.testclient import TestClient
from sqlalchemy import delete, select, text
from sqlalchemy.orm import Session

from feedbasket import admin, auth, backups, extraction, feeds, library, scheduler
from feedbasket.config import Config
from feedbasket.db import Account, Article, ArticleTag, ArticleURL, Feed, FeedEntry, Job, LoginSession, get_setting, make_engine, now, set_setting, write
from feedbasket.main import create_app

DATA = Path(__file__).with_name("data")
FEED_URL = "https://www.nasa.gov/feed/"
ARTICLE_URL = "https://www.nasa.gov/missions/artemis/i-am-artemis-katie-spicer/"
READER = {"sub": "fixture-reader", "email": "reader@gmail.com", "email_verified": True}
ADMIN_USERNAME = "fixture-admin"
ADMIN_PASSWORD = "test password ñ"


def read_page(name, url):
    document = extraction.Document(url, (DATA / name).read_bytes(), "application/rss+xml")
    title, entries, _ = feeds.parse_feed(document)
    return title, entries


def article_document():
    return extraction.Document(ARTICLE_URL, (DATA / "nasa-artemis.html").read_bytes(), "text/html")


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def seeded_library(tmp_path):
    config = Config(db_path=tmp_path / "library.sqlite", backup_folder=str(tmp_path / "backups"),
                    admin_username=ADMIN_USERNAME, admin_password=ADMIN_PASSWORD)
    app = create_app(config, start_worker=False)
    with TestClient(app, base_url=config.public_url):
        _, entries = read_page("nasa.xml", FEED_URL)
        canonical, title, body, extractor = extraction.extract(article_document())
        assert body and extractor
        with write(app.state.engine) as db:
            owner = auth.create_local_account(db, config, "owner")
            token = auth.issue_session(db, owner.id)
            feed = feeds.subscribe(db, owner.id, FEED_URL, "NASA")
            feed.initial_done = True
            feed.next_check = now() + 86400
            for entry in entries:
                feeds.import_entry(db, feed, entry)
            saved, _ = library.save_article(db, owner.id, canonical, title, ["space", "weekend"])
            library.store_body(db, saved, body, extractor)
            fixture_ids = {"article": saved.id, "feed": feed.id, "account": owner.id}
            # The seed represents a completed import, with its scheduled refresh still pending.
            db.execute(delete(Job))
    return config, token, fixture_ids


@pytest.fixture
def backend(seeded_library):
    config, token, ids = seeded_library
    app = create_app(config, start_worker=False)
    with TestClient(app, base_url=config.public_url) as client:
        yield app, client, token, ids


def csrf_from(page):
    return re.search(r'name="token" value="([^"]+)"', page.text).group(1)


def admin_login(client):
    token = csrf_from(client.get("/admin"))
    page = client.post("/admin/login", data={
        "username": ADMIN_USERNAME, "password": ADMIN_PASSWORD, "token": token,
    })
    assert page.status_code == 200
    assert "Back Up Now" in page.text
    return csrf_from(page)


def test_feed_import_windows_and_backfill():
    pages = [read_page("nasa.xml", FEED_URL), read_page("nasa-2.xml", FEED_URL + "?paged=2")]
    real_keys = {entry.key for _, entries in pages for entry in entries}
    assert len(real_keys) == 20
    recent = datetime(2026, 11, 13, tzinfo=UTC)
    _, imported, end, _, _, reason = feeds.select_entries(pages, "initial", set(), today=recent)
    assert len(imported) == 10 and not end
    assert reason == "batch_limit"
    known = {entry.key for entry in imported}

    older = recent.replace(year=2028)
    _, imported, end, _, _, reason = feeds.select_entries(pages, "initial", set(), today=older)
    assert imported == [] and not end
    assert reason == "age_cutoff"
    _, batch, end, _, found, reason = feeds.select_entries(pages, "older", known, today=older)
    assert len(batch) == 10 and end
    assert found == 20 and reason == "end_of_feed"
    assert known.isdisjoint(entry.key for entry in batch)
    _, batch, end, *_ = feeds.select_entries(pages, "older", known | {entry.key for entry in batch}, today=older)
    assert batch == [] and end


def test_article_extraction_and_sanitization():
    canonical, title, body, extractor = extraction.extract(article_document())
    assert canonical == ARTICLE_URL and "Katie Spicer" in title
    assert extractor == "trafilatura"
    assert "Blue Moon" in body
    fragment = extraction.safe_html('<p><a href="./related">Related</a></p><script>example()</script>', ARTICLE_URL)
    assert 'href="' + ARTICLE_URL + 'related"' in fragment
    assert "<script" not in fragment and "example()" not in fragment


def test_original_mozilla_reader():
    if not shutil.which("node") or not (DATA.parents[1] / "node_modules/@mozilla/readability").is_dir():
        pytest.skip("Run npm ci in backend/ to install the optional Mozilla extractor")
    document = article_document()
    markup = extraction.mozilla(document.data, document.url)
    assert markup and "Blue Moon" in markup
    assert extraction.usable(extraction.safe_html(markup, document.url))


def test_account_access_and_admin_permissions(backend):
    app, client, token, ids = backend
    assert client.get("/api/v1/me").status_code == 401
    page = client.get("/admin", headers=bearer(token))
    assert "Admin sign-in" in page.text and "Back Up Now" not in page.text
    csrf = csrf_from(page)
    assert client.post("/admin/backup/run", data={"token": csrf}, headers=bearer(token)).status_code == 403
    assert "Invalid username or password" in client.post("/admin/login", data={
        "token": csrf, "username": ADMIN_USERNAME, "password": "incorrect",
    }).text
    assert client.cookies.get(admin.ADMIN_COOKIE) is None
    csrf = admin_login(client)
    assert client.post("/admin/backup/run", data={"token": "invalid"}).status_code == 403
    assert client.get("/api/v1/me", headers=bearer(token)).json()["admin"] is False
    with write(app.state.engine) as db:
        with pytest.raises(HTTPException, match="not been allowed"):
            auth.sign_in(db, app.state.config, READER)
    fields = {"token": csrf, "email": READER["email"]}
    assert "Allowed accounts updated" in client.post("/admin/access", data=fields | {"action": "allow"}).text
    with write(app.state.engine) as db:
        reader = auth.sign_in(db, app.state.config, READER)
        reader_token = auth.issue_session(db, reader.id)
    assert client.get("/api/v1/me", headers=bearer(reader_token)).json()["admin"] is False
    assert client.get(f"/api/v1/articles/{ids['article']}", headers=bearer(reader_token)).status_code == 404
    client.post("/admin/access", data=fields | {"action": "remove"})
    assert client.get("/api/v1/me", headers=bearer(reader_token)).status_code == 401
    session = client.cookies.get(admin.ADMIN_COOKIE)
    assert client.get("/api/v1/me").status_code == 401
    assert "Admin sign-in" in client.post("/admin/logout", data={"token": csrf}).text
    assert client.cookies.get(admin.ADMIN_COOKIE) is None
    assert "Back Up Now" not in client.get("/admin", headers={"Cookie": f"{admin.ADMIN_COOKIE}={session}"}).text


def test_migration_preserves_legacy_google_admin_as_reader(tmp_path):
    config = Config(db_path=tmp_path / "legacy.sqlite")
    engine = make_engine(config.db_path)
    try:
        migrations = AlembicConfig()
        migrations.set_main_option("script_location", str(DATA.parents[1] / "migrations"))
        with engine.begin() as connection:
            migrations.attributes["connection"] = connection
            command.upgrade(migrations, "0005")
            connection.execute(text("""
                INSERT INTO accounts (id, google_sub, email, name, picture, admin, quota)
                VALUES ('legacy-id', 'legacy-google', 'legacy@gmail.com', 'Legacy', '', 1, 100)
            """))
    finally:
        engine.dispose()

    app = create_app(config, start_worker=False)
    with TestClient(app, base_url=config.public_url) as client:
        with write(app.state.engine) as db:
            account = auth.sign_in(db, config, {"sub": "legacy-google", "email": "legacy@gmail.com", "email_verified": True})
            assert account.id == "legacy-id"
            token = auth.issue_session(db, account.id)
            assert "admin" not in Account.__table__.columns
            assert "admin" not in {row[1] for row in db.execute(text("PRAGMA table_info(accounts)"))}
        assert client.get("/api/v1/me", headers=bearer(token)).json()["admin"] is False
        assert client.post("/admin/backup/run", headers=bearer(token), data={"token": ""}).status_code == 403


def test_save_dedup_archive_trash_and_sync(backend, caplog):
    app, client, token, ids = backend
    caplog.set_level("INFO", logger="feedbasket.api")
    client.headers.update(bearer(token))
    article_id = ids["article"]
    path = f"/api/v1/articles/{article_id}"
    response = client.post("/api/v1/articles", json={"url": ARTICLE_URL + "?utm_medium=rss", "tags": ["NASA"]})
    assert response.status_code == 202
    assert response.json()["article"]["id"] == article_id
    assert client.patch(path, json={"action": "archive", "read": True}).status_code == 200
    for source in ("rss", "saved"):
        items = client.get(f"/api/v1/articles?source={source}&location=archive&tag=nasa").json()["items"]
        assert [(item["id"], item["read"]) for item in items] == [(article_id, True)]
    assert client.delete(path).json()["location"] == "trash"
    with write(app.state.engine) as db:
        _, entries = read_page("nasa.xml", FEED_URL)
        feed = db.get(Feed, ids["feed"])
        for entry in entries:
            assert not feeds.import_entry(db, feed, entry)
    assert client.get(path).json()["location"] == "trash"
    assert client.patch(path, json={"action": "restore"}).json()["location"] == "archive"
    assert f"Article saved article_id={article_id}" in caplog.text
    assert "utm_medium" not in caplog.text
    assert f"Article updated article_id={article_id} read=False->True location=inbox->archive" in caplog.text
    assert f"Article updated article_id={article_id} location=archive->trash" in caplog.text
    updates = client.get("/api/v1/sync").json()["items"]
    assert any(item["id"] == article_id and item["data"]["location"] == "archive" for item in updates)


@pytest.mark.parametrize("state", ["unread", "read", "archived_unread", "trashed_read"])
def test_resave_keeps_one_article_and_returns_it_to_unread_read_later(backend, state):
    app, client, token, ids = backend
    client.headers.update(bearer(token))
    article_id = ids["article"]
    path = f"/api/v1/articles/{article_id}"
    changes = {"starred": True, "read": state in {"read", "trashed_read"}}
    if state.startswith("archived"):
        changes["action"] = "archive"
    elif state.startswith("trashed"):
        assert client.patch(path, json={"action": "archive"}).status_code == 200
        changes["action"] = "trash"
    assert client.patch(path, json=changes).status_code == 200
    before = client.get(path).json()
    cursor = client.get("/api/v1/sync").json()["cursor"]

    saved = client.post("/api/v1/articles", json={"url": ARTICLE_URL + "?utm_medium=rss"})
    assert saved.status_code == 202
    article = saved.json()["article"]
    assert article["id"] == article_id
    assert article["location"] == "inbox" and not article["read"] and article["trash_origin"] is None
    for field in ("starred", "tags", "feed_ids", "saved_at"):
        assert article[field] == before[field]
    persisted = client.get(path).json()
    assert persisted["body_html"] == before["body_html"]
    assert persisted["location"] == "inbox" and not persisted["read"]
    items = client.get("/api/v1/articles", params={"source": "saved", "read": False}).json()["items"]
    assert [item["id"] for item in items] == [article_id]
    synced = client.get("/api/v1/sync", params={"after": cursor}).json()["items"]
    assert [item["id"] for item in synced] == ([] if state == "unread" else [article_id])
    with Session(app.state.engine) as db:
        assert db.scalar(select(Job).where(Job.target == article_id)) is None


def test_ranked_tags_count_articles_for_the_current_account(backend):
    app, client, token, ids = backend
    client.headers.update(bearer(token))
    with write(app.state.engine) as db:
        owner_id = ids["account"]
        archived, _ = library.save_article(db, owner_id, "https://example.com/archived", "Archived", ["weekend"])
        library.update_article(db, archived, action="archive")
        trashed, _ = library.save_article(db, owner_id, "https://example.com/trashed", "Trashed", ["space", "hidden"])
        library.update_article(db, trashed, action="trash")
        other = auth.create_local_account(db, app.state.config, "tag-reader")
        library.save_article(db, other.id, "https://example.com/private", "Private", ["space", "private"])

    assert client.get("/api/v1/tags?ranked=true").json() == [
        {"name": "weekend", "count": 2}, {"name": "space", "count": 1},
    ]
    assert client.get("/api/v1/tags").json() == ["space", "weekend"]


def test_tag_lifecycle_and_filters(backend):
    _, client, token, ids = backend
    client.headers.update(bearer(token))
    article_id = ids["article"]
    path = f"/api/v1/articles/{article_id}"

    def filtered(tag, **params):
        response = client.get("/api/v1/articles", params={"source": "saved", "tag": tag, **params})
        assert response.status_code == 200
        return [item["id"] for item in response.json()["items"]]

    assert client.get("/api/v1/tags").json() == ["space", "weekend"]
    response = client.post("/api/v1/articles", json={
        "url": ARTICLE_URL, "tags": [" Artemis ", "ARTEMIS", " "],
    })
    assert response.status_code == 202
    assert response.json()["article"]["tags"] == ["artemis", "space", "weekend"]
    assert filtered(" ARTEMIS ") == [article_id]
    assert filtered("artemis", feed_id=ids["feed"], read=False) == [article_id]
    assert filtered("artemis", read=True) == []

    assert client.patch(path, json={"tags": ["x" * 81]}).status_code == 422
    assert client.get("/api/v1/tags").json() == ["artemis", "space", "weekend"]
    assert client.patch(path, json={"tags": ["NASA"]}).json()["tags"] == ["nasa"]
    assert filtered("artemis") == []
    assert filtered("nasa") == [article_id]

    assert client.patch(path, json={"action": "archive"}).json()["location"] == "archive"
    assert client.get("/api/v1/tags").json() == []
    assert filtered("nasa", location="archive") == [article_id]
    assert client.patch(path, json={"action": "restore"}).json()["location"] == "inbox"
    assert client.get("/api/v1/tags").json() == ["nasa"]

    assert client.patch(path, json={"tags": []}).json()["tags"] == []
    assert client.get("/api/v1/tags").json() == []
    assert filtered("nasa") == []
    assert client.get(path).json()["saved_at"] is not None


@pytest.mark.parametrize("location", ["archive", "trash"])
def test_library_state_survives_restart(seeded_library, location):
    config, token, ids = seeded_library
    article_id = ids["article"]
    path = f"/api/v1/articles/{article_id}"
    with TestClient(create_app(config, start_worker=False), base_url=config.public_url,
                    headers=bearer(token)) as client:
        response = client.patch(path, json={"read": True, "tags": ["artemis"]})
        assert response.status_code == 200 and response.json()["read"] is True
        if location == "archive":
            response = client.patch(path, json={"action": "archive"})
        else:
            response = client.delete(path)
        assert response.status_code == 200 and response.json()["location"] == location

    with TestClient(create_app(config, start_worker=False), base_url=config.public_url,
                    headers=bearer(token)) as client:
        for source in ("all", "rss", "saved"):
            items = client.get("/api/v1/articles", params={"source": source, "location": location}).json()["items"]
            assert [(item["id"], item["read"], item["tags"]) for item in items] == [(article_id, True, ["artemis"])]
            inbox = client.get("/api/v1/articles", params={"source": source}).json()["items"]
            assert article_id not in {item["id"] for item in inbox}
        response = client.patch(path, json={"action": "restore", "read": False})
        assert response.status_code == 200
        assert response.json()["location"] == "inbox" and response.json()["read"] is False
        for source in ("rss", "saved"):
            items = client.get("/api/v1/articles", params={"source": source, "read": False}).json()["items"]
            assert article_id in {item["id"] for item in items}
        assert client.get("/api/v1/articles", params={"location": location}).json()["items"] == []


def test_quota_and_body_cleanup(backend):
    app, client, token, ids = backend
    client.headers.update(bearer(token))
    storage = client.get("/api/v1/storage").json()
    assert storage["quota_bytes"] == 1_000_000_000 and storage["used_bytes"] > 0
    assert client.patch("/api/v1/storage", json={"quota_bytes": 1}).json()["at_limit"]
    result = client.post("/api/v1/storage/remove-content", json={}).json()
    assert result["article_count"] == 1 and result["bytes_freed"] == storage["used_bytes"]
    item = client.get(f"/api/v1/articles/{ids['article']}").json()
    assert item["tags"] == ["space", "weekend"] and item["body_html"] is None
    assert item["word_count"] is None
    canonical, _, body, extractor = extraction.extract(article_document())
    with write(app.state.engine) as db:
        article = library.article_for_id(db, ids["account"], ids["article"])
        assert article.url == canonical
        library.store_body(db, article, body, extractor)
    assert client.get(f"/api/v1/articles/{ids['article']}").json()["content_status"] == "quota"
    pdf = client.post("/api/v1/articles", json={"url": "https://example.com/file.pdf"})
    assert pdf.status_code == 202 and pdf.json()["article"]["document_type"] == "pdf"


def test_article_word_count_backfill_and_sync(backend):
    app, client, token, ids = backend
    client.headers.update(bearer(token))
    engine = app.state.engine
    with write(engine) as db:
        first = db.get(Article, ids["article"])
        library.store_body(db, first, "<p>Read <em>this</em> first.</p><p>Then stop.</p>", "rss")
        second = library.locate(db, ids["account"], "https://example.com/another-story")
        library.store_body(db, second, "<ul><li>One &amp;</li><li>two.</li></ul>", "rss")
        excerpt = library.locate(db, ids["account"], "https://example.com/excerpt")
        excerpt.excerpt = "Only a summary."
        expected = {first.id: 5, second.id: 2}
        excerpt_id = excerpt.id
    for article_id, count in expected.items():
        assert client.get(f"/api/v1/articles/{article_id}").json()["word_count"] == count

    with write(engine) as db:
        for article_id in expected:
            db.get(Article, article_id).word_count = None
    cursor = client.get("/api/v1/sync").json()["cursor"]
    for _ in expected:
        with write(engine) as db:
            assert library.backfill_word_counts(db, limit=1) == {ids["account"]}
    with write(engine) as db:
        assert not library.backfill_word_counts(db, limit=1)
        assert db.get(Article, excerpt_id).word_count is None

    changes = client.get("/api/v1/sync", params={"after": cursor}).json()["items"]
    assert {item["id"]: item["data"]["word_count"] for item in changes} == expected
    assert client.get(f"/api/v1/articles/{excerpt_id}").json()["word_count"] is None


def test_admin_backup_retention_and_restore(backend, tmp_path):
    app, client, token, ids = backend
    csrf = admin_login(client)
    folder = Path(app.state.config.backup_folder) / app.state.config.backup_prefix / "daily"
    assert not scheduler.tick(app.state.engine, app.state.config)
    with Session(app.state.engine) as db:
        next_at = get_setting(db, backups.NEXT_AT, 0)
    for _ in range(3):
        assert "Backup queued" in client.post("/admin/backup/run", data={"token": csrf}).text
        assert scheduler.tick(app.state.engine, app.state.config)
    with Session(app.state.engine) as db:
        assert get_setting(db, backups.NEXT_AT, 0) == next_at
    paths = list(folder.glob("*.sqlite"))
    assert len(paths) == 2
    before_restore = client.get("/api/v1/sync", headers=bearer(token)).json()
    with write(app.state.engine) as db:
        _, created = library.save_article(db, ids["account"], "https://example.com/original", "", [])
        assert created
    cursor = client.get("/api/v1/sync", headers=bearer(token)).json()["cursor"]
    assert cursor > before_restore["cursor"]
    with closing(sqlite3.connect(paths[0])) as snapshot:
        assert snapshot.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        assert snapshot.execute("PRAGMA foreign_key_check").fetchall() == []
        assert snapshot.execute("SELECT count(*) FROM login_sessions").fetchone() == (0,)

    restore_path = tmp_path / "restored.sqlite"
    shutil.copy2(paths[0], restore_path)
    restored = create_app(replace(app.state.config, db_path=restore_path), start_worker=False)
    with TestClient(restored, base_url=app.state.config.public_url) as restored_client:
        assert restored_client.get("/api/v1/me", headers=bearer(token)).status_code == 401
        with write(restored.state.engine) as db:
            restored_token = auth.issue_session(db, ids["account"])
        restored_client.headers.update(bearer(restored_token))
        # The new change reuses a sequence number already seen on the original database.
        replacement = restored_client.post("/api/v1/articles", json={"url": "https://example.com/replacement"})
        assert replacement.status_code == 202
        rebuilt = restored_client.get("/api/v1/sync").json()
        assert rebuilt["cursor"] >= cursor
        assert rebuilt["library_id"] != before_restore["library_id"]
        page = restored_client.get("/api/v1/sync", params={
            "after": cursor, "library_id": before_restore["library_id"],
        }).json()
        assert page == {"cursor": 0, "has_more": False, "items": [], "reset_required": True,
                        "library_id": rebuilt["library_id"]}
        assert any(change["id"] == replacement.json()["article"]["id"] for change in rebuilt["items"])
        item = restored_client.get(f"/api/v1/articles/{ids['article']}").json()
        assert "Blue Moon" in item["body_html"] and item["tags"] == ["space", "weekend"]
        assert restored_client.get("/api/v1/feeds").json()[0]["id"] == ids["feed"]


def test_due_backup_runs_without_manual_queue(backend):
    app, _, _, _ = backend
    with write(app.state.engine) as db:
        set_setting(db, backups.NEXT_AT, now() - 60)
    assert scheduler.tick(app.state.engine, app.state.config)
    root = Path(app.state.config.backup_folder) / app.state.config.backup_prefix
    assert list((root / "daily").glob("*.sqlite"))
    assert not scheduler.tick(app.state.engine, app.state.config)


def test_subscription_schedule_unsubscribe_and_resubscribe(backend):
    app, client, token, ids = backend
    client.headers.update(bearer(token))
    feed_path = f"/api/v1/feeds/{ids['feed']}"
    cursor = client.get("/api/v1/sync", params={"limit": 200}).json()["cursor"]
    last_checked = now()
    with write(app.state.engine) as db:
        db.get(Feed, ids["feed"]).last_checked = last_checked

    response = client.patch(feed_path, json={"interval_minutes": 15})
    assert response.status_code == 200
    assert response.json()["next_check"] == last_checked + 15 * 60
    assert client.patch(feed_path, json={"interval_minutes": 1}).status_code == 422

    with write(app.state.engine) as db:
        feed_articles = list(db.scalars(select(Article).join(FeedEntry).where(FeedEntry.feed_id == ids["feed"])))
        keep = next(article for article in feed_articles if article.id != ids["article"])
        keep.starred = True
        keep_id = keep.id
        deleted_ids = {article.id for article in feed_articles} - {keep_id}
    assert ids["article"] in deleted_ids
    client.post(feed_path + "/refresh")
    assert client.delete(feed_path).status_code == 204
    assert client.get("/api/v1/feeds").json() == []
    assert client.get("/api/v1/articles", params={"source": "rss"}).json()["items"] == []
    assert client.get(f"/api/v1/articles/{ids['article']}").status_code == 404
    starred = client.get("/api/v1/articles", params={"location": "starred"}).json()["items"]
    assert [article["id"] for article in starred] == [keep_id]
    assert starred[0]["feed_ids"] == []
    with Session(app.state.engine) as db:
        assert db.get(Feed, ids["feed"]) is None
        for model in (FeedEntry, ArticleTag, ArticleURL):
            assert db.scalar(select(model).where(model.article_id.in_(deleted_ids))) is None
        assert db.scalar(select(Job).where(Job.target == ids["feed"])) is None
    updates = client.get("/api/v1/sync", params={"after": cursor}).json()["items"]
    assert any(item["kind"] == "feed" and item["operation"] == "delete" for item in updates)
    assert {item["id"] for item in updates if item["kind"] == "article" and item["operation"] == "delete"} == deleted_ids

    response = client.post("/api/v1/feeds", json={"url": FEED_URL})
    assert response.status_code == 202
    assert response.json()["id"] != ids["feed"]
    assert response.json()["initial_done"] is False
    feed_path = f"/api/v1/feeds/{response.json()['id']}"
    queued = client.post(feed_path + "/refresh").json()
    assert client.post(feed_path + "/refresh").json()["job_id"] == queued["job_id"]
    assert client.get(f"/api/v1/jobs/{queued['job_id']}").json()["status"] == "queued"


def test_backup_failure_retries_and_recovers(backend, tmp_path):
    app, client, token, _ = backend
    engine, config = app.state.engine, app.state.config
    csrf = admin_login(client)
    blocked = tmp_path / "backup-file"
    blocked.write_text("Existing file")
    with write(engine) as db:
        set_setting(db, "backup_folder", blocked)
    response = client.post("/admin/backup/run", data={"token": csrf})
    assert "Backup queued" in response.text

    for attempt in range(1, 4):
        assert scheduler.tick(engine, config)
        with write(engine) as db:
            job = db.scalar(select(Job).where(Job.kind == "backup"))
            assert job.attempts == attempt and job.error
            if attempt < 3:
                assert job.status == "queued" and job.run_at > now()
                job.run_at = now()  # Advance the persisted due time without waiting in the test.
            else:
                assert job.status == "failed" and job.finished_at
                failed_id = job.id

    assert "Retry" in client.get("/admin").text
    assert blocked.read_text() == "Existing file"
    response = client.post("/admin/backup/settings", data={
        "token": csrf, "folder": config.backup_folder, "frequency": "daily",
    })
    assert "Backup settings saved" in response.text
    assert "Retry queued" in client.post(f"/admin/jobs/{failed_id}/retry", data={"token": csrf}).text
    assert scheduler.tick(engine, config)
    with Session(engine) as db:
        assert db.get(Job, failed_id).status == "retried"
        assert Path(get_setting(db, "backup_last_path", "")).is_file()


@pytest.mark.parametrize("retry", [False, True])
def test_expired_backup_staging_cleanup_preserves_pending_retries(backend, monkeypatch, retry):
    app, client, _, ids = backend
    engine, config = app.state.engine, app.state.config
    csrf = admin_login(client)
    sunday = int(datetime(2026, 11, 15, tzinfo=backups.TIMEZONE).timestamp())
    monkeypatch.setattr(scheduler, "now", lambda: sunday)
    root = Path(config.backup_folder) / config.backup_prefix
    root.mkdir(parents=True)
    blocked = root / "weekly"
    blocked.touch()
    with write(engine) as db:
        db.get(Feed, ids["feed"]).next_check = sunday + 86400
        set_setting(db, backups.NEXT_AT, sunday)
    for attempt in range(1, 4):
        assert scheduler.tick(engine, config)
        with write(engine) as db:
            job = db.scalar(select(Job).where(Job.kind == "backup"))
            job.run_at = sunday
            assert job.attempts == attempt
            assert job.status == ("queued" if attempt < 3 else "failed")
            job_id = job.id
        scheduler.clean_expired(engine, config, sunday)
        staged, = config.db_path.parent.glob(f".{config.db_path.name}.feedbasket-*.sqlite.pending")
    data = staged.read_bytes()
    unrelated = staged.with_name(f".other.sqlite.{next((root / 'daily').glob('*.sqlite')).name}.pending")
    unrelated.write_bytes(b"Another database's staging file")
    if retry:
        assert "Retry queued" in client.post(f"/admin/jobs/{job_id}/retry", data={"token": csrf}).text
        with write(engine) as db:
            queued = db.scalar(select(Job).where(Job.kind == "backup", Job.status == "queued"))
            queued.run_at = sunday
    scheduler.clean_expired(engine, config, sunday + 30 * 86400 + 1)
    with Session(engine) as db:
        assert db.get(Job, job_id) is None
    assert unrelated.is_file()
    if retry:
        assert staged.read_bytes() == data
        blocked.unlink()
        assert scheduler.tick(engine, config)
        weekly, = blocked.glob("*.sqlite")
        assert weekly.read_bytes() == data
    assert not staged.exists()


def test_worker_requeues_interrupted_job(backend):
    app, client, token, ids = backend
    client.headers.update(bearer(token))
    response = client.post(f"/api/v1/feeds/{ids['feed']}/refresh")
    job_id = response.json()["job_id"]
    with write(app.state.engine) as db:
        job = db.get(Job, job_id)
        job.status = "running"
        job.attempts = 1
    scheduler.recover_jobs(app.state.engine)
    job = client.get(f"/api/v1/jobs/{job_id}").json()
    assert job["status"] == "queued" and job["attempts"] == 1


def test_explicit_restore_target_is_safe_to_retry(backend):
    _, client, token, ids = backend
    client.headers.update(bearer(token))
    path = f"/api/v1/articles/{ids['article']}"
    assert client.patch(path, json={"action": "archive"}).json()["location"] == "archive"
    assert client.delete(path).json()["trash_origin"] == "archive"
    for _ in range(2):
        result = client.patch(path, json={"action": "restore_archive"}).json()
        assert result["location"] == "archive" and result["trash_origin"] is None
    for _ in range(2):
        result = client.patch(path, json={"action": "restore_inbox"}).json()
        assert result["location"] == "inbox" and result["trash_origin"] is None


@pytest.mark.parametrize(("setup", "location"), [
    ({}, "inbox"),
    ({"read": True, "starred": True}, "inbox"),
    ({"read": True, "action": "archive"}, "archive"),
    ({"read": True}, "trash"),
])
def test_leaving_an_article_only_trashes_unprotected_read_articles(backend, setup, location):
    app, client, token, ids = backend
    client.headers.update(bearer(token))
    path = f"/api/v1/articles/{ids['article']}"
    assert client.patch(path, json=setup).status_code == 200
    timestamps = set()
    for _ in range(2):
        result = client.patch(path, json={"action": "trash_if_read"})
        assert result.status_code == 200 and result.json()["location"] == location
        with Session(app.state.engine) as db:
            article = db.get(Article, ids["article"])
            assert article.location == location
            timestamps.add(article.state_at)
    assert len(timestamps) == 1


def test_trash_cleanup_expires_articles_and_highlights_after_30_days(backend):
    app, client, token, ids = backend
    client.headers.update(bearer(token))
    prefix = "/api/v1/articles"
    expired = ids["article"]
    mark = client.post(f"{prefix}/{expired}/highlights", json={
        "quote": "Saved passage", "anchor": {"kind": "article"},
    })
    assert mark.status_code == 201

    def save(name):
        response = client.post(prefix, json={"url": f"https://example.test/{name}"})
        assert response.status_code == 202
        return response.json()["article"]["id"]

    fresh, restored, pdf = map(save, ("fresh", "restored", "guide.pdf"))
    moment = now()
    cutoff = (moment - 30 * 86400) * 1_000_000_000
    for article_id in (expired, fresh, restored):
        assert client.patch(f"{prefix}/{article_id}", json={
            "read": True, "action": "trash_if_read",
        }).json()["location"] == "trash"
    pdf_path = f"{prefix}/{pdf}"
    assert client.patch(pdf_path, json={
        "read": True, "action": "trash_if_read",
    }).json()["location"] == "inbox"
    assert client.delete(pdf_path).json()["location"] == "trash"

    with write(app.state.engine) as db:
        for article_id, timestamp in ((expired, cutoff), (fresh, cutoff + 1), (restored, cutoff), (pdf, cutoff)):
            db.get(Article, article_id).state_at = timestamp
    result = client.patch(f"{prefix}/{restored}", json={"read": False, "action": "restore_inbox"}).json()
    assert result["location"] == "inbox" and not result["read"]
    cursor = client.get("/api/v1/sync").json()["cursor"]
    config = app.state.config
    assert scheduler.clean_expired(app.state.engine, config, moment) == {ids["account"]}
    assert scheduler.clean_expired(app.state.engine, config, moment) == set()
    assert client.get(f"{prefix}/{expired}").status_code == 404
    assert client.get(f"{prefix}/{fresh}").json()["location"] == "trash"
    assert client.get(f"{prefix}/{restored}").json()["location"] == "inbox"
    assert client.get(pdf_path).json()["location"] == "trash"
    changes = client.get("/api/v1/sync", params={"after": cursor}).json()["items"]
    assert {(change["kind"], change["id"], change["operation"]) for change in changes} == {
        ("article", expired, "delete"), ("highlight", mark.json()["id"], "delete"),
    }


def test_starred_articles_sync_and_survive_archive_and_trash(backend):
    _, client, token, ids = backend
    client.headers.update(bearer(token))
    saved_path = f"/api/v1/articles/{ids['article']}"
    rss = client.get("/api/v1/articles", params={"source": "rss"}).json()["items"]
    rss_only = next(item for item in rss if item["saved_at"] is None)
    rss_path = f"/api/v1/articles/{rss_only['id']}"
    cursor = client.get("/api/v1/sync").json()["cursor"]
    assert client.get(saved_path).json()["starred"] is False
    for path in (saved_path, rss_path):
        assert client.patch(path, json={"starred": True}).json()["starred"] is True
    assert client.patch(saved_path, json={"action": "archive"}).json()["location"] == "archive"
    changes = client.get("/api/v1/sync", params={"after": cursor}).json()["items"]
    assert {change["id"] for change in changes if change["data"]["starred"]} == {ids["article"], rss_only["id"]}

    def starred_ids():
        return {item["id"] for item in client.get("/api/v1/articles", params={"location": "starred"}).json()["items"]}

    assert starred_ids() == {ids["article"], rss_only["id"]}
    assert client.patch(saved_path, json={"action": "trash"}).json()["trash_origin"] == "archive"
    assert client.patch(rss_path, json={"action": "trash"}).json()["trash_origin"] == "inbox"
    assert starred_ids() == set()
    assert client.patch(saved_path, json={"action": "restore_archive"}).json()["location"] == "archive"
    assert starred_ids() == {ids["article"]}
    assert client.patch(saved_path, json={"starred": False}).json()["starred"] is False
    assert starred_ids() == set()


def test_username_connects_both_clients_without_google(tmp_path):
    config = Config(db_path=tmp_path / "local.sqlite", admin_username=ADMIN_USERNAME, admin_password=ADMIN_PASSWORD)
    app = create_app(config, start_worker=False)
    with TestClient(app, base_url=config.public_url) as client:
        with write(app.state.engine) as db:
            account = auth.create_local_account(db, config, "local-reader")
            internal_id = account.id
        assert client.get("/health").json()["google_configured"] is False
        page = client.get("/admin")
        assert "Sign in with Google" not in page.text
        assert client.post("/api/v1/auth/connect", json={"username": internal_id}).status_code == 401
        assert client.post("/api/v1/auth/start").status_code == 503
        first = client.post("/api/v1/auth/connect", json={"username": "local-reader"})
        second = client.post("/api/v1/auth/connect", json={"username": "local-reader"})
        assert first.status_code == second.status_code == 200
        one, two = first.json(), second.json()
        assert one["token"] != two["token"]
        assert one["profile"] == two["profile"] == {
            "id": internal_id, "email": "", "name": "local-reader", "picture": "", "admin": False, "username": "local-reader",
        }
        saved = client.post("/api/v1/articles", json={"url": ARTICLE_URL}, headers=bearer(one["token"]))
        assert saved.status_code == 202
        items = client.get("/api/v1/articles?source=saved", headers=bearer(two["token"])).json()["items"]
        assert [item["id"] for item in items] == [saved.json()["article"]["id"]]
        reconnect = client.post("/api/v1/auth/connect", json={"username": "local-reader", "temporary_session": True})
        assert reconnect.status_code == 200
        temporary = reconnect.json()
        assert temporary["profile"] == one["profile"]
        assert client.get("/api/v1/me", headers=bearer(temporary["token"])).status_code == 200
        with Session(app.state.engine) as db:
            assert db.get(LoginSession, auth.digest(one["token"])).expires_at == auth.LOCAL_SESSION_EXPIRY
            expiration = db.get(LoginSession, auth.digest(temporary["token"])).expires_at
            assert 0 < expiration - now() <= auth.SESSION_TTL
        csrf = admin_login(client)
        response = client.post("/admin/accounts", data={"username": "another-reader", "token": csrf})
        assert "Created account another-reader" in response.text
        separate = client.post("/api/v1/auth/connect", json={"username": "another-reader"}).json()
        assert separate["profile"]["admin"] is False
        assert client.get("/api/v1/articles?source=saved", headers=bearer(separate["token"])).json()["items"] == []


def test_reader_can_sign_up_and_connect_a_second_client(tmp_path):
    config = Config(db_path=tmp_path / "signup.sqlite")
    with TestClient(create_app(config, start_worker=False), base_url=config.public_url) as client:
        endpoint = "/api/v1/auth/signup"
        assert client.post(endpoint, json={"username": "   "}).status_code == 422
        response = client.post(endpoint, json={"username": "  NewReader  "})
        assert response.status_code == 201
        signup = response.json()
        assert signup["profile"]["name"] == "newreader"
        assert signup["profile"]["admin"] is False
        assert client.get("/api/v1/me", headers=bearer(signup["token"])).json() == signup["profile"]
        assert client.post(endpoint, json={"username": "NEWREADER"}).status_code == 409
        connected = client.post("/api/v1/auth/connect", json={"username": "newreader"})
        assert connected.status_code == 200
        assert connected.json()["profile"] == signup["profile"]
        assert connected.json()["token"] != signup["token"]
        assert client.post("/api/v1/auth/logout", headers=bearer(signup["token"])).status_code == 204
        assert client.get("/api/v1/me", headers=bearer(signup["token"])).status_code == 401
        assert client.get("/api/v1/me", headers=bearer(connected.json()["token"])).status_code == 200


def test_admin_requires_configured_password(tmp_path):
    config = Config(db_path=tmp_path / "library.sqlite")
    with TestClient(create_app(config, start_worker=False), base_url=config.public_url) as client:
        page = client.get("/admin")
        assert "ADMIN_PASSWORD" in page.text and 'name="password"' not in page.text
        assert client.post("/admin/backup/run", data={"token": ""}).status_code == 403
        assert client.get("/health").status_code == 200


def test_feed_category_upgrade_preserves_a_populated_library(seeded_library):
    config, token, ids = seeded_library
    engine = make_engine(config.db_path)
    try:
        migrations = AlembicConfig()
        migrations.set_main_option("script_location", str(DATA.parents[1] / "migrations"))
        with engine.begin() as connection:
            before = connection.execute(text("SELECT count(*) FROM feed_entries")).scalar_one()
            assert before > 0
            migrations.attributes["connection"] = connection
            command.downgrade(migrations, "0011")
    finally:
        engine.dispose()

    app = create_app(config, start_worker=False)
    with TestClient(app, base_url=config.public_url, headers=bearer(token)) as client:
        subscription, = client.get("/api/v1/feeds").json()
        assert subscription["id"] == ids["feed"] and subscription["category_id"] is None
        assert client.get("/api/v1/articles/" + ids["article"]).json()["tags"] == ["space", "weekend"]
        assert client.get("/api/v1/feed-categories").json() == []
        with Session(app.state.engine) as db:
            assert db.execute(text("SELECT count(*) FROM feed_entries")).scalar_one() == before
            assert db.execute(text("PRAGMA foreign_key_check")).all() == []


def test_feed_category_order_upgrade_backfills_and_syncs_existing_categories(seeded_library):
    config, token, ids = seeded_library
    path = "/api/v1/feed-categories"
    with TestClient(create_app(config, start_worker=False), base_url=config.public_url, headers=bearer(token)) as client:
        sports = client.post(path, json={"name": "Sports"}).json()
        art = client.post(path, json={"name": "Art"}).json()
        assert client.patch("/api/v1/feeds/" + ids["feed"], json={"category_id": sports["id"]}).status_code == 200
        baseline = client.get("/api/v1/sync").json()
    engine = make_engine(config.db_path)
    try:
        migrations = AlembicConfig()
        migrations.set_main_option("script_location", str(DATA.parents[1] / "migrations"))
        with engine.begin() as connection:
            migrations.attributes["connection"] = connection
            command.downgrade(migrations, "0012")
    finally:
        engine.dispose()

    with TestClient(create_app(config, start_worker=False), base_url=config.public_url, headers=bearer(token)) as client:
        assert client.get(path).json() == [art | {"position": 0}, sports | {"position": 1}]
        assert client.get("/api/v1/feeds").json()[0]["category_id"] == sports["id"]
        updates = client.get("/api/v1/sync", params={"after": baseline["cursor"]}).json()["items"]
        assert {item["id"]: item["data"]["position"] for item in updates if item["kind"] == "feed_category"} == {
            art["id"]: 0, sports["id"]: 1,
        }
