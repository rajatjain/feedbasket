from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import UTC, datetime, timedelta
from email.utils import format_datetime
from pathlib import Path
from threading import Thread
from urllib.parse import urlsplit
from xml.etree import ElementTree

import pytest
from fastapi.testclient import TestClient

from feedbasket import auth, extraction, feeds, scheduler
from feedbasket.config import Config
from feedbasket.db import Article, Feed, Job, now, write
from feedbasket.main import create_app

DATA = Path(__file__).with_name("data")
ATOM = "{http://www.w3.org/2005/Atom}"
ARTICLE = "/missions/artemis/i-am-artemis-katie-spicer/"


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

    def publish_feed(self, path, filename, next_page=None, generator=None):
        channel = ElementTree.parse(DATA / filename).getroot()
        for link in channel.findall("./channel/item/link"):
            link.text = self.origin + urlsplit(link.text).path
        if next_page:
            ElementTree.SubElement(channel.find("channel"), ATOM + "link", {"rel": "next", "href": next_page})
        if generator:
            ElementTree.SubElement(channel.find("channel"), "generator").text = generator
        self.routes[path] = (
            200, {"Content-Type": "application/rss+xml"}, ElementTree.tostring(channel, encoding="utf-8"),
        )


@pytest.fixture
def publisher():
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

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        site = Publisher(f"http://127.0.0.1:{server.server_port}")
        worker = Thread(target=server.serve_forever)
        worker.start()
        try:
            yield site
        finally:
            server.shutdown()
            worker.join()


@pytest.fixture
def library_backend(tmp_path):
    email = "owner@gmail.com"
    config = Config(db_path=tmp_path / "workflow.sqlite", admin_email=email, backup_frequency="disabled")
    app = create_app(config, start_worker=False)
    with TestClient(app, base_url=config.public_url) as client:
        with write(app.state.engine) as db:
            account = auth.sign_in(db, config, {"sub": "fixture-owner", "email": email, "email_verified": True})
            token = auth.issue_session(db, account.id)
        client.headers["Authorization"] = f"Bearer {token}"
        yield client, app.state.engine, config


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
    publisher.publish_feed("/older", "nasa-2.xml")
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

    assert client.post(feed_path + "/older").json() == {
        "history_end": True, "message": "No more articles in this feed.",
    }


def test_initial_import_leaves_older_posts_for_manual_backfill(library_backend, publisher, caplog):
    client, _, _ = library_backend
    caplog.set_level("INFO", logger="feedbasket.feeds")
    publisher.publish_feed("/feed", "nasa.xml")
    status, headers, body = publisher.routes["/feed"]
    tree = ElementTree.fromstring(body)
    today = datetime.now(UTC)
    for index, date in enumerate(tree.findall("./channel/item/pubDate")):
        age = index + 1 if index < 3 else 400 + index
        date.text = format_datetime(today - timedelta(days=age))
    publisher.routes["/feed"] = status, headers, ElementTree.tostring(tree)
    feed_id = client.post("/api/v1/feeds", json={"url": publisher.origin + "/feed"}).json()["id"]
    feed_path = f"/api/v1/feeds/{feed_id}"

    def article_count():
        return len(client.get("/api/v1/articles", params={"feed_id": feed_id}).json()["items"])

    for _ in range(2):
        job = client.post(feed_path + "/refresh").json()
        run_job(library_backend, publisher, job["job_id"], advance=True)
        assert article_count() == 3
    assert "mode=initial found=10 selected=3 imported=3 stop_reason=age_cutoff" in caplog.text
    assert "mode=refresh found=10 selected=0 imported=0 stop_reason=head_checked" in caplog.text
    job = client.post(feed_path + "/older").json()
    run_job(library_backend, publisher, job["job_id"], advance=True)
    assert article_count() == 10


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
