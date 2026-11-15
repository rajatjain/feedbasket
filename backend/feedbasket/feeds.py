import json
import logging
from calendar import timegm
from dataclasses import dataclass
from datetime import UTC, datetime
from hashlib import sha256
from time import monotonic
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit
from uuid import uuid4

import feedparser
from lxml import html
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from . import highlights, publisher
from .db import Article, Feed, FeedEntry, Job, Setting, changed, enqueue, get_setting, now, set_setting, write
from .extraction import FetchError, PublisherHTTPError, clean_text, fetch, normalize_url, parse_html, pdf_url, safe_html, usable
from .library import locate, mark_pdf_link, store_body

FEED_TYPES = {"application/rss+xml": "RSS", "application/atom+xml": "Atom", "application/rdf+xml": "RSS"}
log = logging.getLogger(__name__)


@dataclass
class Entry:
    key: str
    url: str
    title: str
    published: int | None
    author: str
    excerpt: str
    body: str


def link_url(base, value):
    if not value:
        return None
    try:
        return normalize_url(urljoin(base, value))
    except ValueError:
        return None


def read_feed(document):
    feed = feedparser.parse(document.data, response_headers={"content-location": document.url})
    feed.setdefault("version", "")
    return feed


def parse_feed(document):
    feed = read_feed(document)
    return feed_contents(document, feed)


def feed_contents(document, feed):
    if not feed.version:
        return None
    entries = []
    seen = set()
    for item in feed.entries:
        url = link_url(document.url, item.get("link"))
        if not url:
            continue
        key = str(item.get("id") or url)
        if key in seen:
            continue
        seen.add(key)
        published = item.get("published_parsed") or item.get("updated_parsed")
        content = next((element.get("value", "") for element in item.get("content", [])
                        if element.get("type") in {"text/html", "application/xhtml+xml", "text/plain"}), "")
        body = safe_html(content, url) if content else ""
        entries.append(Entry(
            key, url, clean_text(item.get("title", ""))[:500] or url,
            timegm(published) if published else None, clean_text(item.get("author", ""))[:300],
            clean_text(item.get("summary", ""))[:1000], body if body and usable(body) else "",
        ))
    next_url = next((link_url(document.url, link.get("href")) for link in feed.feed.get("links", [])
                     if link.get("rel") == "next"), None)
    if not next_url:
        next_url = next((link_url(document.url, part.split(">", 1)[0].strip().removeprefix("<"))
                         for part in document.link_header.split(",")
                         if 'rel="next"' in part or "rel=next" in part), None)
    return clean_text(feed.feed.get("title", ""))[:500] or document.url, entries, next_url


def discover(url, *, probe=False, fetch_document=fetch):
    document = fetch_document(url)
    feed = read_feed(document)
    candidates = advertised_feeds(parse_html(document.data), document.url) if not feed.version else []
    if probe and not feed.version and not candidates and document.media_type in {"text/html", "application/xhtml+xml"}:
        for path in ("/rss.xml", "/feed.xml"):
            try:
                candidate = fetch_document(urljoin(document.url, path))
            except FetchError:
                continue
            parsed = read_feed(candidate)
            if parsed.version:
                document, feed = candidate, parsed
                break
    if feed.version:
        return [{"url": document.url, "title": clean_text(feed.feed.get("title", ""))[:500] or document.url}]
    return [{"url": item["url"], "title": item["title"]} for item in candidates]


def advertised_feeds(tree, url):
    found = {}
    for node in tree.iter("link"):
        format_name = FEED_TYPES.get(node.get("type", "").lower().strip())
        if "alternate" not in node.get("rel", "").lower().split() or not format_name:
            continue
        target = link_url(url, node.get("href"))
        if target:
            found[target] = {"url": target, "title": node.get("title", "").strip()[:500] or target,
                             "format": format_name}
    def is_comment_feed(item):
        path = urlsplit(item["url"]).path.rstrip("/").lower()
        return path.endswith(("/comments/feed", "/feed/comments")) or "comments feed" in item["title"].casefold()

    return sorted(found.values(), key=is_comment_feed)[:20]


def website_tree(document):
    if document.media_type not in {"text/html", "application/xhtml+xml"}:
        raise FetchError("The URL does not contain a web page or feed")
    return parse_html(document.data)


def website_metadata(tree, url):
    metadata = {(node.get("property") or node.get("name") or "").lower(): node.get("content", "")
                for node in tree.iter("meta")}
    title = metadata.get("og:title") or tree.findtext(".//title", "")
    description = metadata.get("description") or metadata.get("og:description", "")
    return {"url": url, "title": " ".join(title.split())[:500] or urlsplit(url).netloc,
            "description": " ".join(description.split())[:1000]}


def preview(url, *, fetch_document=fetch):
    return preview_document(fetch_document(url))


def preview_document(document, *, feed=None):
    feed = read_feed(document) if feed is None else feed
    if feed.version:
        title = clean_text(feed.feed.get("title", ""))[:500] or urlsplit(document.url).netloc
        site_url = link_url(document.url, feed.feed.get("link")) or document.url
        return {"url": site_url, "title": title, "description": clean_text(feed.feed.get("subtitle", ""))[:1000],
                "feeds": [{"url": document.url, "title": title,
                           "format": "Atom" if feed.version.startswith("atom") else "RSS"}]}
    tree = website_tree(document)
    return website_metadata(tree, document.url) | {"feeds": advertised_feeds(tree, document.url)}


def active_subscriptions(db, account_id):
    return dict(db.execute(select(Feed.url, Feed.kind).where(
        Feed.account_id == account_id, Feed.active.is_(True)
    )).all())


def linked_feeds(body, article_url, *, fetch_document=fetch):
    links = {}
    for node in parse_html(body).iter("a"):
        href = node.get("href", "").strip()
        if not href or href.startswith("#"):
            continue
        url = link_url(article_url, href)
        if url and url != article_url and not urlsplit(url).path.lower().endswith(".pdf"):
            parts = urlsplit(url)
            path = parts.path.rstrip("/").lower()
            direct = path.endswith(("/feed", "/rss", "/atom", ".rss", ".xml", ".atom"))
            links.setdefault(url, not direct)
    candidates = {}
    for url in sorted(links, key=links.__getitem__)[:4]:
        try:
            result = preview(url, fetch_document=fetch_document)
        except FetchError:
            continue
        for candidate in result["feeds"]:
            candidates.setdefault(candidate["url"], candidate)
    return list(candidates.values())


def publisher_archive(url, *, fetch_document=fetch):
    document = fetch_document(url)
    feed = read_feed(document)
    if not feed.version:
        raise FetchError("Publisher URL does not contain an RSS or Atom feed")
    site_url = link_url(document.url, feed.feed.get("link"))
    if not site_url or site_url in (url, document.url):
        site_url = urljoin(document.url, "/")
    try:
        site = fetch_document(site_url)
        tree = website_tree(site)
    except FetchError:
        return site_url

    host = urlsplit(site.url).hostname.removeprefix("www.")
    for node in tree.iter("link", "a"):
        relations = node.get("rel", "").lower().split()
        label = " ".join(" ".join(node.itertext()).split()).casefold()
        if "archives" in relations or (node.tag == "a" and label in {"archive", "archives"}):
            target = link_url(site.url, node.get("href"))
            if target and urlsplit(target).hostname.removeprefix("www.") == host:
                return target
    return site.url


def subscribe(db, account_id, url, title, interval=None, *, kind="feed"):
    existing = db.scalar(select(Feed).where(Feed.account_id == account_id, Feed.url == url))
    if existing:
        if existing.kind != kind:
            raise ValueError("This URL is already used by a different subscription type")
        if not existing.active:
            existing.active, existing.next_check = True, now()
            changed(db, account_id, "feed", existing.id)
            for article_id in db.scalars(select(FeedEntry.article_id).where(FeedEntry.feed_id == existing.id).distinct()):
                changed(db, account_id, "article", article_id)
            enqueue(db, "refresh", existing.id)
        return existing
    feed = Feed(id=str(uuid4()), account_id=account_id, url=url, title=title or url, interval_minutes=interval,
                kind=kind, history_end=kind == "website")
    db.add(feed)
    db.flush()
    changed(db, account_id, "feed", feed.id)
    enqueue(db, "refresh", feed.id)
    return feed


def feed_data(feed):
    data = {key: getattr(feed, key) for key in (
        "id", "url", "custom_title", "interval_minutes", "last_checked", "next_check",
        "history_end", "active", "error", "initial_done", "kind",
    )}
    return data | {"title": feed.custom_title or feed.title}


def unsubscribe(db, feed):
    linked_ids = select(FeedEntry.article_id).where(FeedEntry.feed_id == feed.id)
    articles = select(Article).where(Article.account_id == feed.account_id, Article.id.in_(linked_ids))
    deleted_ids = articles.with_only_columns(Article.id).where(Article.starred.is_(False))
    # In-flight workers recheck their target before writing. Keep their job IDs reserved until they finish.
    db.execute(delete(Job).where(Job.status != "running", Job.kind.in_(("refresh", "older")), Job.target == feed.id))
    db.execute(delete(Job).where(Job.status != "running", Job.kind.in_(("extract", "reader_refresh")), Job.target.in_(deleted_ids)))
    kept = removed = 0
    for article_id, starred in db.execute(articles.with_only_columns(Article.id, Article.starred)):
        changed(db, feed.account_id, "article", article_id, "upsert" if starred else "delete")
        kept += starred
        removed += not starred
    highlights.record_deletions(db, feed.account_id, deleted_ids)
    db.execute(delete(Article).where(Article.id.in_(deleted_ids)))
    changed(db, feed.account_id, "feed", feed.id, "delete")
    db.execute(delete(Setting).where(Setting.key == "older:" + feed.id))
    db.delete(feed)
    return removed, kept


def import_entry(db, feed, entry):
    item = db.get(FeedEntry, (feed.id, entry.key))
    if item:
        return False
    article = locate(db, feed.account_id, entry.url, entry.title, entry.published)
    if pdf_url(entry.url) and article.document_type != "pdf":
        article = mark_pdf_link(db, article, entry.url)
    db.add(FeedEntry(feed_id=feed.id, key=entry.key, article_id=article.id))
    article.published_at = article.published_at or entry.published
    article.excerpt = article.excerpt or entry.excerpt
    article.author = article.author or entry.author
    if article.title == article.url:
        article.title = entry.title
    if article.document_type != "pdf" and article.location != "trash" and article.content_status != "cleared":
        if entry.body and (not article.body or article.extractor != "rss"):
            store_body(db, article, entry.body, "rss")
            # Resolve aliases even when a feed supplies the reader body.
            enqueue(db, "extract", article.id)
        elif article.body is None and article.content_status == "pending":
            enqueue(db, "extract", article.id)
    changed(db, feed.account_id, "article", article.id)
    return True


def wordpress_page(url, page):
    parts = urlsplit(url)
    query = [(key, value) for key, value in parse_qsl(parts.query, keep_blank_values=True) if key != "paged"]
    return urlunsplit(parts._replace(query=urlencode([*query, ("paged", page)])))


def feed_pages(url, fetch_document=fetch, *, older=False, continuation=None, pause=None):
    visited = set()
    seen_keys = set()
    wordpress_url = None
    page = 1
    previous_keys = set()
    if continuation:
        url, wordpress_url, page, previous_keys = continuation
        seen_keys.update(previous_keys)
    while url and url not in visited:
        if len(visited) >= 50:
            raise FetchError("Feed history exceeded 50 pages in one scan")
        visited.add(url)
        try:
            document = fetch_document(url)
        except publisher.DeadlineExceeded:
            if pause is not None and len(visited) > 1:
                pause(url, wordpress_url, page, previous_keys)
                yield None, []
                return
            raise
        except PublisherHTTPError as error:
            if wordpress_url and error.status in {404, 410}:
                return
            raise
        feed = read_feed(document)
        parsed = feed_contents(document, feed)
        if not parsed:
            if wordpress_url:
                return
            raise FetchError("Publisher URL does not contain an RSS or Atom feed")
        title, entries, next_url = parsed
        if len(visited) == 1 and not continuation and older and not next_url:
            generator = str(feed.feed.get("generator", "")).lower()
            if "wordpress.org" in generator or generator.startswith("wordpress"):
                wordpress_url = document.url
        keys = {entry.key for entry in entries}
        if wordpress_url and page > 1 and not keys - seen_keys:
            return
        seen_keys.update(keys)
        previous_keys = keys
        yield title, entries
        if wordpress_url:
            page += 1
            url = wordpress_page(wordpress_url, page)
        else:
            url = next_url


def select_entries(pages, mode, known, *, today):
    candidates = []
    seen = set(known)
    title = ""
    cutoff = today
    try:
        cutoff = cutoff.replace(year=cutoff.year - 1)
    except ValueError:  # February 29
        cutoff = cutoff.replace(year=cutoff.year - 1, day=28)
    recent_since = int(cutoff.timestamp())
    skipped_history = False
    found = 0
    head = []
    for index, (page_title, entries) in enumerate(pages):
        if page_title is None:
            return title, candidates, False, head, found, "time_limit"
        found += len(entries)
        if index == 0:
            title, head = page_title, entries
        entries.sort(key=lambda item: item.published or 0, reverse=True)
        for entry in entries:
            if entry.key in seen:
                continue
            seen.add(entry.key)
            if mode in {"initial", "older"} and len(candidates) >= 10:
                return title, candidates, False, head, found, "batch_limit"
            if mode == "initial":
                if entry.published is None:
                    skipped_history = True
                    continue
                if entry.published < recent_since:
                    return title, candidates, False, head, found, "age_cutoff"
            candidates.append(entry)
        if mode == "refresh":
            return title, candidates, None, head, found, "head_checked"
    return title, candidates, not skipped_history, head, found, "undated_entries" if skipped_history else "end_of_feed"


def refresh_website(engine, config, feed_id, document, *, job_id, started, mode):
    tree = website_tree(document)
    title = website_metadata(tree, document.url)["title"]
    content = tree.find(".//main")
    if content is None:
        content = tree.find(".//body")
    if content is None:
        content = tree
    for element in reversed(list(content.iterdescendants("script", "style", "template", "noscript", "nav", "footer"))):
        element.drop_tree()
    body = safe_html(html.tostring(content, encoding="unicode"), document.url)
    text = clean_text(body)
    links = [url for element in parse_html(body).iter("a", "img")
             if (url := element.get("href") or element.get("src"))]
    if not text and not links:
        raise FetchError("No readable website content was found")
    digest = sha256(json.dumps([title, text, links], ensure_ascii=False).encode("utf-8")).hexdigest()

    with write(engine) as db:
        feed = db.get(Feed, feed_id)
        if not feed or not feed.active:
            return
        checked = now()
        updated = digest != feed.page_digest
        if updated:
            # Each version has its own reader and read state, even though it links to the same page.
            article = Article(id=str(uuid4()), account_id=feed.account_id, url=document.url, title=title,
                              published_at=checked, excerpt=text[:1000], extractor="website")
            db.add(article)
            db.flush()
            db.add(FeedEntry(feed_id=feed.id, key=article.id, article_id=article.id))
            store_body(db, article, body, "website")
            feed.page_digest = digest
        default = int(get_setting(db, "feed_interval", config.feed_interval))
        feed.last_checked, feed.next_check = checked, checked + (feed.interval_minutes or default) * 60
        feed.title, feed.error, feed.initial_done = title, None, True
        changed(db, feed.account_id, "feed", feed.id)
        account_id = feed.account_id
    log.info("Website checked job_id=%s feed_id=%s host=%s mode=%s snapshot_created=%s elapsed_ms=%d",
             job_id, feed_id, urlsplit(document.url).hostname, mode, updated, (monotonic() - started) * 1000)
    return account_id


def refresh(engine, config, feed_id, *, older=False, fetch_document=fetch, job_id=None):
    started = monotonic()
    with Session(engine) as db:
        feed = db.get(Feed, feed_id)
        if not feed or not feed.active:
            return
        website = feed.kind == "website"
        if older and website:
            return
        if older and not feed.initial_done:
            raise FetchError("Refresh the subscription before fetching older articles")
        known = set() if website else set(db.scalars(select(FeedEntry.key).where(FeedEntry.feed_id == feed.id)))
        mode = "older" if older else "refresh" if feed.initial_done else "initial"
        url, previous_newest, last_checked = feed.url, feed.newest_at, feed.last_checked
        history_key = "older:" + feed_id
        position = get_setting(db, history_key, None) if older else None
    if website:
        return refresh_website(engine, config, feed_id, fetch_document(url), job_id=job_id, started=started, mode=mode)

    def pause(next_url, wordpress_url, page, seen_keys):
        nonlocal position
        position = json.dumps([next_url, wordpress_url, page, sorted(seen_keys) if wordpress_url else []])

    continuing = position is not None
    title, entries, history_end, head, found, stop_reason = select_entries(
        feed_pages(url, fetch_document, older=older, continuation=json.loads(position) if position else None,
                   pause=pause if older else None),
        mode, known, today=datetime.now(UTC),
    )
    if mode == "refresh":
        first_known = next((index for index, item in enumerate(head) if item.key in known), 0)
        new_keys = {entry.key for entry in head[:first_known]}
        # An empty initial import can leave a head full of deliberately skipped history.
        date_floor = previous_newest if known else max(previous_newest or 0, last_checked or 0)
        entries = [
            item for item in entries if item.key in new_keys
            or (item.published is not None and date_floor is not None
                and (item.published >= date_floor if known else item.published > date_floor))
        ]
    with write(engine) as db:
        feed = db.get(Feed, feed_id)
        if not feed or not feed.active:
            return
        imported = sum(import_entry(db, feed, entry) for entry in entries)
        if not older:
            default = int(get_setting(db, "feed_interval", config.feed_interval))
            feed.last_checked, feed.next_check = now(), now() + (feed.interval_minutes or default) * 60
            dates = [item.published for item in head if item.published is not None]
            if dates:
                feed.newest_at = max(dates + ([feed.newest_at] if feed.newest_at is not None else []))
        if history_end is not None:
            feed.history_end = history_end
        elif any(item.key not in known and item not in entries for item in head):
            feed.history_end = False
        if older:
            if history_end and position:
                db.execute(delete(Setting).where(Setting.key == history_key))
            elif stop_reason == "time_limit":
                set_setting(db, history_key, position)
        if not continuing:
            feed.title = title
        feed.error, feed.initial_done = None, True
        changed(db, feed.account_id, "feed", feed.id)
        exhausted = feed.history_end
        account_id = feed.account_id
    log.info("Feed checked job_id=%s feed_id=%s host=%s mode=%s found=%d selected=%d imported=%d "
             "stop_reason=%s history_exhausted=%s elapsed_ms=%d", job_id, feed_id, urlsplit(url).hostname, mode,
             found, len(entries), imported, stop_reason, exhausted, (monotonic() - started) * 1000)
    return account_id
