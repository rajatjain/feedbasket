from copy import deepcopy
from http.server import BaseHTTPRequestHandler
from datetime import UTC, datetime, timedelta
from email.utils import format_datetime
from pathlib import Path
from urllib.parse import urlsplit
from xml.etree import ElementTree

import pytest
from sqlalchemy import select

from feedbasket import extraction, feeds, library, publisher as publisher_jobs, scheduler
from feedbasket.db import Article, Feed, FeedEntry, Job, now, write

DATA = Path(__file__).with_name("data")
ATOM = "{http://www.w3.org/2005/Atom}"
ARTICLE = "/missions/artemis/i-am-artemis-katie-spicer/"


PUBLISHER_NOW = datetime(2026, 11, 15, tzinfo=UTC)


class PublisherClock(datetime):
    @classmethod
    def now(cls, tz=None):
        return PUBLISHER_NOW.astimezone(tz or UTC)


class Publisher:
    def __init__(self, origin):
        self.origin = origin
        self.port = urlsplit(origin).port
        self.routes = {}
        self.requests = []

    def fetch(self, url):
        # All test traffic uses the actual HTTP fetcher and stays on this publisher.
        return extraction.fetch(url, resolve_address=self.resolve)

    def resolve(self, host, port):
        if host != "127.0.0.1" or port != self.port:
            raise extraction.FetchError("URL is outside the test publisher")
        return host

    def publish_article(self):
        source = (DATA / "nasa-artemis.html").read_bytes()
        source = source.replace(
            f'href="https://www.nasa.gov{ARTICLE}"'.encode(),
            f'href="{self.origin}{ARTICLE}"'.encode(),
            1,
        )
        self.routes[ARTICLE] = (200, {"Content-Type": "text/html"}, source)

    def publish_feed(self, path, filename, next_page=None, generator=None, *, age_days=None, duplicate_from=None):
        channel = ElementTree.parse(DATA / filename).getroot()
        items = channel.findall("./channel/item")
        for item in items:
            link = item.find("link")
            link.text = self.origin + urlsplit(link.text).path
        if age_days is not None:
            assert len(age_days) == len(items)
            for item, age in zip(items, age_days):
                date = item.find("pubDate")
                if age is None:
                    item.remove(date)
                else:
                    date.text = format_datetime(PUBLISHER_NOW - timedelta(days=age))
        if duplicate_from:
            previous = ElementTree.fromstring(self.routes[duplicate_from][2])
            channel.find("channel").insert(0, deepcopy(previous.find("./channel/item")))
        if next_page:
            ElementTree.SubElement(channel.find("channel"), ATOM + "link", {"rel": "next", "href": next_page})
        if generator:
            ElementTree.SubElement(channel.find("channel"), "generator").text = generator
        self.routes[path] = (
            200, {"Content-Type": "application/rss+xml"}, ElementTree.tostring(channel, encoding="utf-8"),
        )


@pytest.fixture
def publisher(http_server, monkeypatch):
    monkeypatch.setattr(feeds, "datetime", PublisherClock)
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            site.requests.append(self.path)
            status, headers, body = site.routes.get(self.path, (404, {}, b""))
            self.send_response(status)
            for name, value in headers.items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    with http_server(Handler) as server:
        site = Publisher(f"http://127.0.0.1:{server.server_port}")
        yield site


@pytest.fixture
def library_backend(backend_config, start_backend, account_headers):
    with start_backend(backend_config) as (app, client):
        owner, = account_headers(app, "owner")
        client.headers.update(owner)
        yield client, app.state.engine, backend_config


def run_job(backend, publisher, job_id, *, expected="done", advance=False):
    client, engine, config = backend
    if advance:
        # Advance only this job's due time so unrelated extraction jobs stay queued.
        with write(engine) as db:
            db.get(Job, job_id).run_at = 0
    assert scheduler.tick(engine, config, fetch_document=publisher.fetch)
    response = client.get(f"/api/v1/jobs/{job_id}")
    assert response.status_code == 200
    job = response.json()
    assert job["status"] == expected, job
    return job


def test_redirect_and_canonical_merge_preserves_article_state(library_backend, publisher):
    client, _, _ = library_backend
    publisher.publish_article()
    alias = "/short-link"
    intermediate = "/print-edition"
    publisher.routes[alias] = (302, {"Location": intermediate}, b"")
    publisher.routes[intermediate] = publisher.routes[ARTICLE]
    original = client.post("/api/v1/articles", json={"url": publisher.origin + ARTICLE, "tags": ["artemis"]})
    assert original.status_code == 202
    original_id = original.json()["article"]["id"]
    duplicate = client.post("/api/v1/articles", json={"url": publisher.origin + alias, "tags": ["weekend"]})
    assert duplicate.status_code == 202
    duplicate_id = duplicate.json()["article"]["id"]
    assert duplicate_id != original_id

    assert client.patch(f"/api/v1/articles/{original_id}", json={"read": True, "action": "archive"}).status_code == 200
    cursor = client.get("/api/v1/sync").json()["cursor"]
    response = client.post(f"/api/v1/articles/{duplicate_id}/extract")
    assert response.status_code == 202
    run_job(library_backend, publisher, response.json()["job_id"], advance=True)

    assert publisher.requests == [alias, intermediate]
    original = client.get(f"/api/v1/articles/{original_id}").json()
    assert client.get(f"/api/v1/articles/{duplicate_id}").json() == original
    assert original["url"] == publisher.origin + ARTICLE
    assert original["read"] and original["location"] == "archive"
    assert original["tags"] == ["artemis", "weekend"]
    assert "Blue Moon" in original["body_html"]
    changes = client.get("/api/v1/sync", params={"after": cursor}).json()["items"]
    removed_id = ({original_id, duplicate_id} - {original["id"]}).pop()
    assert any(change["operation"] == "redirect" and change["id"] == removed_id
               and change["replacement_id"] == original["id"] for change in changes)
    for path in (alias, intermediate, ARTICLE):
        saved = client.post("/api/v1/articles", json={"url": publisher.origin + path})
        assert saved.json()["article"]["id"] == original["id"]


def test_refresh_and_backfill_follow_feed_pagination(library_backend, publisher):
    client, engine, _ = library_backend
    publisher.publish_feed("/feed", "nasa.xml", next_page="/older")
    publisher.publish_feed("/older", "nasa-2.xml", duplicate_from="/feed")
    head_url = publisher.origin + "/feed"
    subscription = client.post("/api/v1/feeds", json={"url": head_url})
    assert subscription.status_code == 202
    feed_id = subscription.json()["id"]
    feed_path = f"/api/v1/feeds/{feed_id}"

    # Seed five previously imported entries between a newer entry and skipped history.
    account_id = client.get("/api/v1/me").json()["id"]
    _, entries, _ = feeds.parse_feed(publisher.fetch(head_url))
    entries.sort(key=lambda entry: entry.published, reverse=True)
    with write(engine) as db:
        feed = db.get(Feed, feed_id)
        assert feed.account_id == account_id
        feed.initial_done = True
        feed.newest_at = entries[1].published
        for entry in entries[1:6]:
            assert feeds.import_entry(db, feed, entry)

    def items():
        return client.get("/api/v1/articles", params={"source": "rss", "feed_id": feed_id}).json()["items"]

    refresh = client.post(feed_path + "/refresh")
    assert refresh.status_code == 202
    publisher.requests.clear()
    run_job(library_backend, publisher, refresh.json()["job_id"], advance=True)
    assert publisher.requests == ["/feed"]
    assert {item["url"] for item in items()} == {entry.url for entry in entries[:6]}

    for count in (16, 20):
        publisher.requests.clear()
        response = client.post(feed_path + "/older")
        assert response.status_code == 202 and not response.json()["history_end"]
        run_job(library_backend, publisher, response.json()["job_id"], advance=True)
        assert publisher.requests == ["/feed", "/older"]
        assert len({item["id"] for item in items()}) == count
    _, archived_entries, _ = feeds.parse_feed(publisher.fetch(publisher.origin + "/older"))
    assert {item["url"] for item in items()} == {entry.url for entry in entries + archived_entries}
    with write(engine) as db:
        assert set(db.scalars(select(FeedEntry.key).where(FeedEntry.feed_id == feed_id))) == {
            entry.key for entry in entries + archived_entries
        }

    assert client.post(feed_path + "/older").json() == {
        "history_end": True, "message": "No more articles in this feed.",
    }


def test_custom_feed_title_syncs_and_survives_refresh(library_backend, publisher):
    client, engine, _ = library_backend
    publisher.publish_feed("/feed", "nasa.xml")
    subscription = client.post("/api/v1/feeds", json={
        "url": publisher.origin + "/feed", "title": "Original publisher name", "interval_minutes": 30,
    }).json()
    path = f"/api/v1/feeds/{subscription['id']}"
    cursor = client.get("/api/v1/sync").json()["cursor"]
    assert client.patch(path, json={"custom_title": "   "}).status_code == 422

    renamed = client.patch(path, json={"custom_title": "  Space News  "}).json()
    assert renamed["title"] == renamed["custom_title"] == "Space News"
    assert renamed["interval_minutes"] == 30
    assert renamed["next_check"] == subscription["next_check"]
    updates = client.get("/api/v1/sync", params={"after": cursor}).json()
    assert [item["data"]["title"] for item in updates["items"]] == ["Space News"]

    job_id = client.post(path + "/refresh").json()["job_id"]
    run_job(library_backend, publisher, job_id, advance=True)
    assert client.get("/api/v1/feeds").json()[0]["title"] == "Space News"
    assert client.patch(path, json={"interval_minutes": 60}).json()["title"] == "Space News"

    restored = client.patch(path, json={"custom_title": None}).json()
    with write(engine) as db:
        publisher_name = db.get(Feed, subscription["id"]).title
    assert publisher_name != "Original publisher name"
    assert restored["title"] == publisher_name
    assert restored["custom_title"] is None
    assert restored["interval_minutes"] == 60
    other = client.post("/api/v1/auth/signup", json={"username": "other"}).json()
    assert client.patch(path, json={"custom_title": "Other"}, headers={
        "Authorization": f"Bearer {other['token']}",
    }).status_code == 404


def test_older_job_resumes_after_deadline(library_backend, publisher, monkeypatch):
    client, engine, config = library_backend
    publisher.publish_feed("/feed", "nasa.xml", next_page="/older")
    publisher.publish_feed("/older", "nasa-2.xml")
    url = publisher.origin + "/feed"
    feed_id = client.post("/api/v1/feeds", json={"url": url}).json()["id"]
    feed_path = f"/api/v1/feeds/{feed_id}"
    _, entries, _ = feeds.parse_feed(publisher.fetch(url))
    with write(engine) as db:
        feed = db.get(Feed, feed_id)
        feed.initial_done = True
        feed.next_check = now() + 3600
        for entry in entries[:5]:
            feeds.import_entry(db, feed, entry)

    allow_older_page = False
    visited = []

    def fetch(_, url):
        visited.append(url)
        if url.endswith("/older") and not allow_older_page:
            raise publisher_jobs.DeadlineExceeded()
        return publisher.fetch(url)

    monkeypatch.setattr(publisher_jobs.Budget, "fetch", fetch)
    for expected_count in (10, 20):
        job_id = client.post(feed_path + "/older").json()["job_id"]
        with write(engine) as db:
            db.get(Job, job_id).run_at = 0
        assert scheduler.tick(engine, config)
        assert client.get(f"/api/v1/jobs/{job_id}").json()["status"] == "done"
        items = client.get("/api/v1/articles", params={"feed_id": feed_id}).json()["items"]
        assert len(items) == expected_count
        if not allow_older_page:
            assert not client.get("/api/v1/feeds").json()[0]["history_end"]
        allow_older_page = True

    assert visited == [url, publisher.origin + "/older", publisher.origin + "/older"]
    assert client.get("/api/v1/feeds").json()[0]["history_end"]


@pytest.mark.parametrize(("ages", "initial_indexes"), [
    pytest.param((1, 364, 365, 366, 400, None, 402, 403, 404, 405), (0, 1, 2), id="exact-age-cutoff"),
    pytest.param((None, 1, None, 2, 3, 4, 5, 6, 7, 8), (1, 3, 4, 5, 6, 7, 8, 9), id="undated-history"),
])
def test_initial_import_leaves_older_posts_for_manual_backfill(library_backend, publisher, ages, initial_indexes):
    client, engine, _ = library_backend
    publisher.publish_feed("/feed", "nasa.xml", age_days=ages)
    tree = ElementTree.fromstring(publisher.routes["/feed"][2])
    entries = [(item.findtext("link"), item.findtext("guid")) for item in tree.findall("./channel/item")]
    feed_id = client.post("/api/v1/feeds", json={"url": publisher.origin + "/feed"}).json()["id"]
    feed_path = f"/api/v1/feeds/{feed_id}"

    def assert_items(indexes):
        expected = [entries[index] for index in indexes]
        items = client.get("/api/v1/articles", params={"feed_id": feed_id}).json()["items"]
        assert {item["url"] for item in items} == {url for url, _ in expected}
        with write(engine) as db:
            assert set(db.scalars(select(FeedEntry.key).where(FeedEntry.feed_id == feed_id))) == {
                guid for _, guid in expected
            }

    for _ in range(2):
        job = client.post(feed_path + "/refresh").json()
        run_job(library_backend, publisher, job["job_id"], advance=True)
        assert_items(initial_indexes)
    job = client.post(feed_path + "/older").json()
    run_job(library_backend, publisher, job["job_id"], advance=True)
    assert_items(range(len(entries)))


def test_recheck_imports_unadvertised_wordpress_pages(library_backend, publisher):
    client, _, _ = library_backend
    publisher.publish_feed("/feed", "nasa.xml", generator="https://wordpress.org/")
    publisher.publish_feed("/feed?paged=2", "nasa-2.xml")
    publisher.routes["/feed?paged=3"] = publisher.routes["/feed?paged=2"]
    feed_id = client.post("/api/v1/feeds", json={"url": publisher.origin + "/feed"}).json()["id"]
    feed_path = f"/api/v1/feeds/{feed_id}"
    refresh = client.post(feed_path + "/refresh").json()
    run_job(library_backend, publisher, refresh["job_id"], advance=True)
    assert client.post(feed_path + "/older").json()["history_end"]
    publisher.requests.clear()
    job = client.post(feed_path + "/older", params={"recheck": "true"}).json()
    run_job(library_backend, publisher, job["job_id"], advance=True)
    assert publisher.requests == ["/feed", "/feed?paged=2", "/feed?paged=3"]
    articles = client.get("/api/v1/articles", params={"feed_id": feed_id}).json()["items"]
    assert len({article["id"] for article in articles}) == 20
    assert client.post(feed_path + "/older").json()["history_end"]


@pytest.mark.parametrize("homepage, target", [
    (b'<nav><a href="/archives">Archives</a></nav>', "/archives"),
    (b'<link rel="archives" href="/past-posts">', "/past-posts"),
    (b'<nav><a href="https://example.org/archives">Archives</a></nav>', "/blog"),
])
def test_browse_older_posts_opens_archive_or_publisher_homepage(library_backend, publisher, monkeypatch, homepage, target):
    client, _, _ = library_backend
    publisher.routes["/feed"] = (
        200, {"Content-Type": "application/rss+xml"},
        b'<rss version="2.0"><channel><title>Publisher</title><link>/blog</link></channel></rss>',
    )
    publisher.routes["/blog"] = (200, {"Content-Type": "text/html"}, homepage)
    monkeypatch.setattr(feeds, "fetch", publisher.fetch)
    feed = client.post("/api/v1/feeds", json={"url": publisher.origin + "/feed"}).json()

    response = client.get(f"/api/v1/feeds/{feed['id']}/archive")

    assert response.status_code == 200
    assert response.json() == {"url": publisher.origin + target}
    assert publisher.requests == ["/feed", "/blog"]


@pytest.mark.parametrize("kind", ["refresh", "extract"])
def test_publisher_failure_retries_and_recovers(library_backend, publisher, kind):
    client, engine, config = library_backend
    path = "/feed" if kind == "refresh" else ARTICLE
    publisher.routes[path] = (503, {}, b"Service unavailable")
    if kind == "refresh":
        response = client.post("/api/v1/feeds", json={"url": publisher.origin + path})
        assert response.status_code == 202
        target_id = response.json()["id"]
        queued = client.post(f"/api/v1/feeds/{target_id}/refresh")
    else:
        response = client.post("/api/v1/articles", json={"url": publisher.origin + path})
        assert response.status_code == 202
        target_id = response.json()["article"]["id"]
        queued = client.post(f"/api/v1/articles/{target_id}/extract")
    assert queued.status_code == 202
    job_id = queued.json()["job_id"]

    for attempt in range(1, 4):
        expected = "queued" if attempt < 3 else "failed"
        job = run_job(library_backend, publisher, job_id, expected=expected, advance=attempt > 1)
        assert job["attempts"] == attempt and job["error"] == "Publisher returned HTTP 503"
        if attempt < 3:
            assert not scheduler.tick(engine, config, fetch_document=publisher.fetch)
        else:
            assert job["finished_at"]
    assert publisher.requests == [path] * 3

    if kind == "refresh":
        feed = client.get("/api/v1/feeds").json()[0]
        assert feed["error"] == job["error"] and not feed["initial_done"]
        assert feed["next_check"] == feed["last_checked"] + config.feed_interval * 60
        publisher.publish_feed(path, "nasa.xml")
        with write(engine) as db:
            db.get(Feed, target_id).next_check = now()
        assert scheduler.tick(engine, config, fetch_document=publisher.fetch)
        feed = client.get("/api/v1/feeds").json()[0]
        assert feed["initial_done"] and feed["error"] is None
    else:
        detail_url = f"/api/v1/articles/{target_id}"
        article = client.get(detail_url).json()
        assert article["content_status"] == "failed" and article["content_error"] == job["error"]
        publisher.publish_article()
        retry = client.post(detail_url + "/extract")
        assert retry.status_code == 202 and retry.json()["job_id"] != job_id
        run_job(library_backend, publisher, retry.json()["job_id"])
        article = client.get(detail_url).json()
        assert article["content_status"] == "ready" and "Blue Moon" in article["body_html"]


@pytest.mark.parametrize("status", [401, 403])
def test_reader_access_refusal_finishes_on_first_attempt(library_backend, publisher, caplog, status):
    client, _, _ = library_backend
    publisher.routes[ARTICLE] = (status, {}, b"")
    saved = client.post("/api/v1/articles", json={"url": publisher.origin + ARTICLE, "tags": ["weekend"]})
    assert saved.status_code == 202
    article_id = saved.json()["article"]["id"]
    detail_url = f"/api/v1/articles/{article_id}"
    queued = client.post(detail_url + "/extract")
    cursor = client.get("/api/v1/sync").json()["cursor"]

    job = run_job(library_backend, publisher, queued.json()["job_id"], expected="failed")
    assert publisher.requests == [ARTICLE]
    assert job["attempts"] == 1 and job["finished_at"]
    assert job["error"] == f"Publisher returned HTTP {status}" and job["error"] in caplog.text
    assert f"target_id={article_id}" in caplog.text
    assert "attempt=1 status=failed retry_in_seconds=0" in caplog.text
    article = client.get(detail_url).json()
    assert article["content_status"] == "failed" and article["content_error"] == job["error"]
    assert article["tags"] == ["weekend"] and article["body_html"] is None
    changes = client.get("/api/v1/sync", params={"after": cursor}).json()["items"]
    assert [change["data"]["content_status"] for change in changes] == ["failed"]

    publisher.publish_article()
    retry = client.post(detail_url + "/extract")
    assert retry.status_code == 202 and retry.json()["job_id"] != job["id"]
    run_job(library_backend, publisher, retry.json()["job_id"])
    article = client.get(detail_url).json()
    assert article["content_status"] == "ready" and "Blue Moon" in article["body_html"]


def test_discovery_probes_unadvertised_feed_on_request(library_backend, publisher, monkeypatch):
    client, _, _ = library_backend
    monkeypatch.setattr(feeds, "fetch", publisher.fetch)
    publisher.routes["/blog/"] = (200, {"Content-Type": "text/html"}, b"<html><title>Blog</title></html>")
    publisher.routes["/rss.xml"] = (200, {"Content-Type": "text/html"}, b"<html><title>Missing</title></html>")
    publisher.publish_feed("/feed.xml", "nasa.xml")
    params = {"url": publisher.origin + "/blog/"}
    path = "/api/v1/feeds/discover"

    assert client.get(path, params=params).json() == []
    assert publisher.requests == ["/blog/"]
    publisher.requests.clear()
    response = client.get(path, params=params | {"probe": True})
    assert response.status_code == 200
    assert response.json() == [{"url": publisher.origin + "/feed.xml", "title": "NASA"}]
    assert publisher.requests == ["/blog/", "/rss.xml", "/feed.xml"]


@pytest.mark.parametrize(("path", "kind", "status"), [
    pytest.param("/feed.xml", "feed", 200, id="direct-rss"),
    pytest.param(ARTICLE, "article", 200, id="article-with-feed"),
    pytest.param("/download?utm_source=signed#page=4", "pdf", 200, id="extensionless-pdf"),
    pytest.param("/report", "unsupported", 200, id="unsupported-docx"),
    pytest.param("/audio", "unsupported", 200, id="unsupported-audio"),
    pytest.param("/protected", None, 422, id="publisher-signin"),
])
def test_guided_add_preview_and_save(library_backend, publisher, monkeypatch, path, kind, status, pdf_bytes):
    client, engine, _ = library_backend
    monkeypatch.setattr(publisher_jobs.Budget, "preview", lambda _, url: extraction.fetch(
        url, resolve_address=publisher.resolve, preview=True,
    ))
    if kind == "article":
        publisher.publish_article()
        code, headers, markup = publisher.routes[ARTICLE]
        feed_link = b'<link rel="alternate" type="application/rss+xml" href="/feed.xml" title="River updates">'
        head, separator, rest = markup.partition(b"</head>")
        assert separator
        publisher.routes[ARTICLE] = code, headers, head + feed_link + separator + rest
    if kind in {"article", "feed"}:
        publisher.publish_feed("/feed.xml", "nasa.xml")
    elif kind == "pdf":
        publisher.routes[path.split("#")[0]] = (200, {"Content-Type": "application/octet-stream"}, pdf_bytes())
    elif path == "/protected":
        publisher.routes[path] = (403, {}, b"")
    else:
        media = {"audio": "audio/mpeg", "report": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"}
        publisher.routes[path] = (200, {"Content-Type": media[path[1:]]}, b"Unsupported file fixture")
    url = publisher.origin + path
    response = client.get("/api/v1/links/preview", params={"url": url})
    assert response.status_code == status
    preview = response.json()
    if kind:
        assert preview["kind"] == kind and preview["url"] == url
    else:
        assert preview["detail"]["code"] == "preview_unavailable"
    assert client.get("/api/v1/sync").json()["items"] == []
    with write(engine) as db:
        for model in (Article, Feed, Job):
            assert db.scalar(select(model)) is None

    if kind == "feed":
        candidate, = preview["feeds"]
        assert candidate["format"] == "RSS"
        saved = client.post("/api/v1/feeds", json={"url": candidate["url"]})
        assert saved.status_code == 202
        with write(engine) as db:
            assert db.get(Feed, saved.json()["id"]).url == candidate["url"]
        article_id, feed_id = None, saved.json()["id"]
    elif kind in {"article", "pdf"}:
        body = {"url": preview["url"], "title": preview["title"], "tags": [" Research "], "document_type": kind}
        if kind == "article":
            candidate, = preview["feeds"]
            assert candidate["title"] == "River updates"
            body["subscribe_url"] = candidate["url"]
        saved = client.post("/api/v1/articles", json=body)
        assert saved.status_code == 202
        item = saved.json()["article"]
        article_id, feed_id = item["id"], saved.json()["feed"]["id"] if saved.json()["feed"] else None
        assert item["document_type"] == kind and item["tags"] == ["research"]
        with write(engine) as db:
            stored = db.get(Article, item["id"])
            assert stored.url == url and stored.body is None and stored.pdf_key is None
            if kind == "article":
                assert db.get(Feed, saved.json()["feed"]["id"]).url == candidate["url"]
    else:
        return

    assert client.get("/api/v1/sync").json()["items"]
    with write(engine) as db:
        queued = {job.kind: job.id for job in db.scalars(select(Job).where(Job.status == "queued"))}
        assert queued.keys() == {"feed": {"refresh"}, "article": {"extract", "refresh"}, "pdf": set()}[kind]
    if article_id and "extract" in queued:
        run_job(library_backend, publisher, queued["extract"], advance=True)
        detail = client.get(f"/api/v1/articles/{article_id}").json()
        assert detail["content_status"] == "ready" and "Blue Moon" in detail["body_html"]
    if feed_id:
        run_job(library_backend, publisher, queued["refresh"], advance=True)
        assert len(client.get("/api/v1/articles", params={"feed_id": feed_id}).json()["items"]) == 10
        with write(engine) as db:
            assert db.get(Feed, feed_id).initial_done
            assert len(list(db.scalars(select(FeedEntry.key).where(FeedEntry.feed_id == feed_id)))) == 10


def test_extraction_preserves_inline_code_and_preformatted_blocks(library_backend, publisher):
    client, _, _ = library_backend
    publisher.routes["/technical-note"] = (200, {"Content-Type": "text/html"}, b"""
        <html><head><title>A technical note</title></head><body><article>
        <p>This technical note explains how model names are displayed in the library.
        A model name can include its version, size, and file format.
        Keep the exact name when looking it up in another application.</p>
        <p>Take <a href="/model"><code>model-35B</code></a>:</p>
        <ul><li>Choose the file with <code>Q4_K_M</code> in its name.</li></ul>
        <table><tr><th>Part</th><th>Meaning</th></tr>
        <tr><td><code>35B</code></td><td>The parameter count.</td></tr></table>
        <p>Use <code>&lt;name&gt;</code> in a configuration file.</p>
        <pre><code>model --version</code></pre>
        <pre>First line
    indented output</pre>
        </article></body></html>
    """)
    article = client.post("/api/v1/articles", json={"url": publisher.origin + "/technical-note"}).json()["article"]
    path = f"/api/v1/articles/{article['id']}"
    run_job(library_backend, publisher, client.post(path + "/extract").json()["job_id"])
    detail = client.get(path).json()
    assert detail["extractor"] == "trafilatura"
    tree = extraction.parse_html(detail["body_html"])
    link, = tree.xpath('//p/a[code="model-35B"]')
    assert link.getparent().text == "Take " and link.tail == ":"
    assert link.get("href") == publisher.origin + "/model"
    assert tree.xpath('//li/code[text()="Q4_K_M"]')
    assert tree.xpath('//td/code[text()="35B"]')
    assert tree.xpath('//p/code[text()="<name>"]')
    assert [block.text_content().strip() for block in tree.xpath('//pre')] == [
        "model --version", "First line\n    indented output",
    ]


def test_manual_reader_refresh_preserves_existing_rss_body_on_failure(library_backend, publisher):
    client, engine, _ = library_backend
    publisher.publish_article()
    article = client.post("/api/v1/articles", json={
        "url": publisher.origin + ARTICLE, "tags": ["weekend"],
    }).json()["article"]
    article_id = article["id"]
    path = f"/api/v1/articles/{article_id}"
    initial_job = client.post(path + "/extract").json()["job_id"]
    run_job(library_backend, publisher, initial_job)
    old = "<p>Existing content from the RSS feed.</p>"
    with write(engine) as db:
        library.store_body(db, db.get(Article, article_id), old, "rss")
    assert client.patch(path, json={"read": True, "starred": True}).status_code == 200

    good_response = publisher.routes[ARTICLE]
    for bad_response in (
        (503, {}, b"Unavailable"),
        (200, {"Content-Type": "application/pdf"}, b"%PDF-1.7"),
        (200, {"Content-Type": "text/html"}, b"<html><body>No article.</body></html>"),
    ):
        publisher.routes[ARTICLE] = bad_response
        response = client.post(path + "/refresh-reader")
        assert response.status_code == 202
        job_id = response.json()["job_id"]
        assert client.get(path).json()["body_html"] == old
        run_job(library_backend, publisher, job_id, expected="failed")
        detail = client.get(path).json()
        assert detail["body_html"] == old and detail["content_status"] == "ready"
        assert detail["document_type"] == "article"

    publisher.routes[ARTICLE] = good_response
    run_job(library_backend, publisher, client.post(path + "/refresh-reader").json()["job_id"])
    detail = client.get(path).json()
    assert "Blue Moon" in detail["body_html"] and detail["extractor"] == "trafilatura"
    assert detail["read"] and detail["starred"] and detail["tags"] == ["weekend"]


def test_article_extraction_discovers_extensionless_pdf(library_backend, publisher):
    client, _, _ = library_backend
    publisher.routes["/download"] = (200, {"Content-Type": "application/pdf"}, b"%PDF-1.7\n")
    url = publisher.origin + "/download"
    article = client.post("/api/v1/articles", json={"url": url, "tags": ["research"]}).json()["article"]
    path = f"/api/v1/articles/{article['id']}"
    queued = client.post(path + "/extract").json()["job_id"]
    run_job(library_backend, publisher, queued)
    detail = client.get(path).json()
    assert detail["document_type"] == "pdf"
    assert detail["url"] == url and detail["tags"] == ["research"] and detail["body_html"] is None
    assert client.post(path + "/extract").status_code == 415


def test_subscription_preview_is_read_only_and_keeps_legacy_discovery(library_backend, publisher, monkeypatch):
    client, _, _ = library_backend
    monkeypatch.setattr(feeds, "fetch", publisher.fetch)
    publisher.routes["/"] = (200, {"Content-Type": "text/html"}, b"""
        <html><head><title>Field Notes</title><meta name="description" content="Essays on design.">
        <link rel="alternate" type="application/rss+xml" href="/comments/feed/" title="Comments Feed">
        <link rel="alternate" type="application/rss+xml" href="/feed.xml" title="All posts">
        <link rel="alternate" type="application/atom+xml" href="/design.xml" title="Design essays">
        </head><body><main>Welcome to Field Notes.</main></body></html>
    """)
    publisher.publish_feed("/feed.xml", "nasa.xml")
    path = "/api/v1/feeds/discover"
    candidates = client.get(path, params={"url": publisher.origin + "/", "preview": True}).json()
    assert candidates == {
        "url": publisher.origin + "/", "title": "Field Notes", "description": "Essays on design.",
        "feeds": [
            {"url": publisher.origin + "/feed.xml", "title": "All posts", "format": "RSS"},
            {"url": publisher.origin + "/design.xml", "title": "Design essays", "format": "Atom"},
            {"url": publisher.origin + "/comments/feed/", "title": "Comments Feed", "format": "RSS"},
        ],
    }
    legacy = client.get(path, params={"url": publisher.origin + "/"}).json()
    assert legacy == [{"url": item["url"], "title": item["title"]} for item in candidates["feeds"]]
    direct = client.get(path, params={"url": publisher.origin + "/feed.xml", "preview": True}).json()
    assert direct["feeds"][0]["url"] == publisher.origin + "/feed.xml"
    assert direct["feeds"][0]["format"] == "RSS"
    assert client.get("/api/v1/feeds").json() == []
    assert client.post("/api/v1/feeds", json={"url": publisher.origin + "/feed.xml"}).status_code == 202
    checked = client.get(path, params={
        "url": publisher.origin + "/", "preview": True, "check_subscriptions": True,
    }).json()
    assert [item["already_subscribed"] for item in checked["feeds"]] == [True, False, False]


def test_article_linked_feeds_exclude_existing_subscriptions(library_backend, publisher, monkeypatch):
    client, engine, _ = library_backend
    monkeypatch.setattr(feeds, "fetch", publisher.fetch)
    publisher.publish_feed("/linked.xml", "nasa.xml")
    publisher.routes["/blog"] = (200, {"Content-Type": "text/html"}, b"""
        <title>Publisher</title><link rel="alternate" type="application/rss+xml" href="/linked.xml">
    """)
    article_id = client.post("/api/v1/articles", json={"url": publisher.origin + "/article"}).json()["article"]["id"]
    with write(engine) as db:
        db.get(Article, article_id).body = '<p><a href="/blog">Blog</a> <a href="/linked.xml">RSS</a></p>'
    path = f"/api/v1/articles/{article_id}/linked-feeds"
    response = client.get(path)
    assert response.status_code == 200
    assert [item["url"] for item in response.json()] == [publisher.origin + "/linked.xml"]
    feed = client.post("/api/v1/feeds", json={"url": publisher.origin + "/linked.xml"}).json()
    assert client.get(path).json() == []
    assert client.delete(f"/api/v1/feeds/{feed['id']}").status_code == 204
    assert [item["url"] for item in client.get(path).json()] == [publisher.origin + "/linked.xml"]


def test_follow_website_records_changes_without_replacing_previous_versions(library_backend, publisher, monkeypatch):
    client, _, _ = library_backend
    monkeypatch.setattr(feeds, "fetch", publisher.fetch)

    def publish(text, navigation):
        page = f"<html><head><title>The Small Hours</title></head><body><main><nav>{navigation}</nav>"
        page += f"<p>{text}</p><script>ignored()</script></main></body></html>"
        publisher.routes["/notes"] = (200, {"Content-Type": "text/html"}, page.encode())

    url = publisher.origin + "/notes"
    publish("Original notes.", "Home")
    preview = client.get("/api/v1/feeds/discover", params={"url": url, "preview": True}).json()
    assert preview["title"] == "The Small Hours" and preview["feeds"] == []
    request = {"url": preview["url"], "title": preview["title"], "kind": "website"}
    subscription = client.post("/api/v1/feeds", json=request)
    assert subscription.status_code == 202
    feed = subscription.json()
    assert feed["kind"] == "website"
    assert client.post("/api/v1/feeds", json=request).json()["id"] == feed["id"]
    assert client.post("/api/v1/feeds", json={"url": url}).status_code == 409
    feed_path = f"/api/v1/feeds/{feed['id']}"

    def refresh():
        queued = client.post(feed_path + "/refresh")
        assert queued.status_code == 202
        run_job(library_backend, publisher, queued.json()["job_id"])
        return client.get("/api/v1/articles", params={"feed_id": feed["id"]}).json()["items"]

    first, = refresh()
    first_path = f"/api/v1/articles/{first['id']}"
    assert client.patch(first_path, json={"read": True}).status_code == 200
    publish("Original notes.", "New navigation")
    assert len(refresh()) == 1
    publish("Updated notes.", "New navigation")
    versions = refresh()
    assert len(versions) == 2
    second = next(item for item in versions if item["id"] != first["id"])
    assert not second["read"] and second["excerpt"] == "Updated notes."
    original = client.get(first_path).json()
    assert original["read"] and "Original notes." in original["body_html"]
    assert "ignored()" not in original["body_html"]
    assert client.post(first_path + "/extract").status_code == 409
    assert client.post(feed_path + "/older").json()["history_end"]
