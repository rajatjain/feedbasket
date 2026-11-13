import asyncio
import logging
from typing import Annotated, Literal
from urllib.parse import urlsplit

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from . import feeds, library
from .auth import current_account, profile, revoke
from .db import Account, Article, ArticleTag, Change, Feed, Job, changed, enqueue, get_setting, now, write
from .extraction import FetchError, PDFUnsupported, normalize_url
from .logs import publisher_url

router = APIRouter(prefix="/api/v1")
log = logging.getLogger(__name__)
CurrentAccount = Annotated[Account, Depends(current_account)]
Source = Literal["all", "rss", "saved"]
Location = Literal["inbox", "archive", "trash", "starred"]


class SaveRequest(BaseModel):
    url: str = Field(max_length=4000)
    title: str = Field(default="", max_length=500)
    tags: list[str] = Field(default_factory=list, max_length=30)
    subscribe_url: str | None = Field(default=None, max_length=4000)


class ArticlePatch(BaseModel):
    read: bool | None = None
    starred: bool | None = None
    action: Literal["archive", "trash", "restore", "restore_archive", "restore_inbox"] | None = None
    tags: list[str] | None = Field(default=None, max_length=30)


class SubscriptionRequest(BaseModel):
    url: str = Field(max_length=4000)
    title: str = Field(default="", max_length=500)
    interval_minutes: int | None = Field(default=None, ge=5, le=10080)
    kind: Literal["feed", "website"] = "feed"


class FeedSchedule(BaseModel):
    interval_minutes: int | None = Field(default=None, ge=5, le=10080)


class QuotaRequest(BaseModel):
    quota_bytes: int = Field(ge=0, le=10**12)


class RemoveContentRequest(BaseModel):
    before: int | None = Field(default=None, ge=0, le=253402300799)


def checked_url(value):
    try:
        url = normalize_url(value)
    except ValueError as error:
        raise HTTPException(422, str(error)) from error
    if urlsplit(url).path.lower().endswith(".pdf"):
        raise HTTPException(415, {"code": "pdf_unsupported", "message": "PDF support coming soon."})
    return url


def get_article(db, account, article_id):
    article = library.article_for_id(db, account.id, article_id)
    if article is None:
        raise HTTPException(404, "Article not found")
    return article


def get_feed(db, account, feed_id):
    feed = db.get(Feed, feed_id)
    if feed is None or feed.account_id != account.id or not feed.active:
        raise HTTPException(404, "Subscription not found")
    return feed


def storage_data(db, account):
    used = library.stored_bytes(db, account.id)
    return {"used_bytes": used, "quota_bytes": account.quota,
            "warning": used >= account.quota * 0.8,
            "at_limit": used >= account.quota}


@router.get("/me")
def me(account: CurrentAccount):
    return profile(account)


@router.post("/auth/logout", status_code=204)
def logout(request: Request, account: CurrentAccount):
    revoke(request)


@router.get("/articles")
def articles(
    request: Request, account: CurrentAccount, source: Source = "all", location: Location = "inbox",
    feed_id: Annotated[str | None, Query(max_length=36)] = None,
    tag: Annotated[str | None, Query(max_length=80)] = None,
    read: bool | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
):
    with Session(request.app.state.engine) as db:
        query = library.article_query(account.id, source, location, feed_id, tag, read)
        rows = list(db.scalars(query.offset(offset).limit(limit + 1)))
        return {
            "items": [library.article_data(db, row) for row in rows[:limit]],
            "next_offset": offset + limit if len(rows) > limit else None,
        }


@router.post("/articles", status_code=202)
def save(request: Request, body: SaveRequest, account: CurrentAccount):
    url = checked_url(body.url)
    feed_url = checked_url(body.subscribe_url) if body.subscribe_url else None
    with write(request.app.state.engine) as db:
        try:
            article, updated = library.save_article(db, account.id, url, body.title.strip(), body.tags)
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        try:
            feed = feeds.subscribe(db, account.id, feed_url, "") if feed_url else None
        except ValueError as error:
            raise HTTPException(409, str(error)) from error
        result = {"article": library.article_data(db, article), "feed": feeds.feed_data(feed) if feed else None}
    if updated or feed:
        request.app.state.saved_updates.publish(account.id)
        log.info("Article saved article_id=%s url=%r updated=%s reader_status=%s feed_id=%s", result["article"]["id"],
                 publisher_url(url), updated, result["article"]["content_status"],
                 result["feed"]["id"] if result["feed"] else None)
    return result


@router.get("/articles/{article_id}")
def article_detail(request: Request, article_id: str, account: CurrentAccount):
    with Session(request.app.state.engine) as db:
        article = get_article(db, account, article_id)
        result = library.article_data(db, article, body=True)
        if article.content_status == "failed":
            result["content_error"] = db.scalar(select(Job.error).where(
                Job.kind == "extract", Job.target == article.id, Job.status.in_(("failed", "retried")),
            ).order_by(Job.id.desc()).limit(1))
        return result


def persist_article_update(request, article_id, account, **changes):
    with write(request.app.state.engine) as db:
        article = get_article(db, account, article_id)
        before = {"read": article.read, "starred": article.starred, "location": article.location}
        try:
            library.update_article(db, article, **changes)
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        result = library.article_data(db, article)
    transitions = [f"{key}={value}->{result[key]}" for key, value in before.items() if value != result[key]]
    if changes.get("tags") is not None:
        transitions.append(f"tags_set={len(result['tags'])}")
    if transitions:
        log.info("Article updated article_id=%s %s", result["id"], " ".join(transitions))
    return result


@router.patch("/articles/{article_id}")
def patch_article(request: Request, article_id: str, body: ArticlePatch, account: CurrentAccount):
    return persist_article_update(request, article_id, account, **body.model_dump())


@router.delete("/articles/{article_id}")
def trash_article(request: Request, article_id: str, account: CurrentAccount):
    return persist_article_update(request, article_id, account, action="trash")


@router.post("/articles/{article_id}/extract", status_code=202)
def extract_article(request: Request, article_id: str, account: CurrentAccount):
    with write(request.app.state.engine) as db:
        article = get_article(db, account, article_id)
        if article.location == "trash":
            raise HTTPException(409, "Restore the article before requesting its reader content")
        if article.content_status == "pdf_unsupported":
            raise HTTPException(415, "PDF support coming soon.")
        if article.extractor == "website":
            raise HTTPException(409, "Website snapshots cannot be re-extracted")
        if not article.body:
            article.content_status = "pending"
            changed(db, account.id, "article", article.id)
        job = enqueue(db, "extract", article.id)
        result = {"job_id": job.id, "status": job.status}
        saved = article.saved_at is not None
    if saved:
        request.app.state.saved_updates.publish(account.id)
    log.info("Extraction requested job_id=%s article_id=%s status=%s", result["job_id"], article_id, result["status"])
    return result


@router.get("/tags")
def tags(request: Request, account: CurrentAccount, ranked: bool = False):
    with Session(request.app.state.engine) as db:
        if ranked:
            count = func.count(ArticleTag.article_id)
            rows = db.execute(select(ArticleTag.tag, count).join(Article).where(
                Article.account_id == account.id, Article.location != "trash"
            ).group_by(ArticleTag.tag).order_by(count.desc(), ArticleTag.tag))
            return [{"name": name, "count": total} for name, total in rows]
        return list(db.scalars(select(ArticleTag.tag).join(Article).where(
            Article.account_id == account.id, Article.location == "inbox", Article.saved_at.is_not(None)
        ).distinct().order_by(ArticleTag.tag)))


@router.get("/feeds")
def subscriptions(request: Request, account: CurrentAccount):
    with Session(request.app.state.engine) as db:
        return [feeds.feed_data(feed) for feed in db.scalars(select(Feed).where(
            Feed.account_id == account.id, Feed.active.is_(True)
        ).order_by(Feed.title, Feed.id))]


@router.get("/feeds/discover")
def discover_feed(request: Request, url: Annotated[str, Query(max_length=4000)], account: CurrentAccount,
                  preview: bool = False, check_subscriptions: bool = False, probe: bool = False):
    url = checked_url(url)
    try:
        if not preview:
            return feeds.discover(url, probe=probe, fetch_document=feeds.fetch)
        result = feeds.preview(url, fetch_document=feeds.fetch)
        if check_subscriptions:
            with Session(request.app.state.engine) as db:
                subscribed = feeds.active_subscriptions(db, account.id)
            result["already_subscribed"] = "website" in (subscribed.get(result["url"]), subscribed.get(url))
            for candidate in result["feeds"]:
                candidate["already_subscribed"] = subscribed.get(candidate["url"]) == "feed" or (
                    len(result["feeds"]) == 1 and subscribed.get(url) == "feed"
                )
        return result
    except PDFUnsupported as error:
        raise HTTPException(415, str(error)) from error
    except FetchError as error:
        raise HTTPException(422, str(error)) from error


@router.get("/articles/{article_id}/linked-feeds")
def linked_feeds(request: Request, article_id: str, account: CurrentAccount):
    engine = request.app.state.engine
    with Session(engine) as db:
        article = get_article(db, account, article_id)
        body, url = article.body, article.url
    if not body:
        return []
    candidates = feeds.linked_feeds(body, url, fetch_document=feeds.fetch)
    with Session(engine) as db:
        get_article(db, account, article_id)
        subscribed = feeds.active_subscriptions(db, account.id)
    return [item for item in candidates if item["url"] not in subscribed][:10]


@router.post("/feeds", status_code=202)
def subscribe(request: Request, body: SubscriptionRequest, account: CurrentAccount):
    url = checked_url(body.url)
    with write(request.app.state.engine) as db:
        try:
            feed = feeds.subscribe(db, account.id, url, body.title, body.interval_minutes, kind=body.kind)
        except ValueError as error:
            raise HTTPException(409, str(error)) from error
        result = feeds.feed_data(feed)
    request.app.state.saved_updates.publish(account.id)
    log.info("Subscription active feed_id=%s kind=%s host=%s", result["id"], result["kind"], urlsplit(url).hostname)
    return result


@router.patch("/feeds/{feed_id}")
def update_schedule(request: Request, feed_id: str, body: FeedSchedule, account: CurrentAccount):
    with write(request.app.state.engine) as db:
        feed = get_feed(db, account, feed_id)
        default = int(get_setting(db, "feed_interval", request.app.state.config.feed_interval))
        feed.interval_minutes = body.interval_minutes
        feed.next_check = (feed.last_checked + (body.interval_minutes or default) * 60
                           if feed.last_checked else now())
        changed(db, account.id, "feed", feed.id)
        result = feeds.feed_data(feed)
    log.info("Feed schedule updated feed_id=%s interval_minutes=%s next_check=%s",
             feed_id, body.interval_minutes or default, result["next_check"])
    return result


@router.delete("/feeds/{feed_id}", status_code=204)
def unsubscribe(request: Request, feed_id: str, account: CurrentAccount):
    with write(request.app.state.engine) as db:
        removed, kept = feeds.unsubscribe(db, get_feed(db, account, feed_id))
    request.app.state.saved_updates.publish(account.id)
    log.info("Feed unsubscribed feed_id=%s removed=%d starred_kept=%d", feed_id, removed, kept)


@router.post("/feeds/{feed_id}/refresh", status_code=202)
def refresh(request: Request, feed_id: str, account: CurrentAccount):
    with write(request.app.state.engine) as db:
        feed = get_feed(db, account, feed_id)
        job = enqueue(db, "refresh", feed.id)
        return {"job_id": job.id, "status": job.status}


@router.post("/feeds/{feed_id}/older", status_code=202)
def fetch_older(request: Request, feed_id: str, account: CurrentAccount, recheck: bool = False):
    with write(request.app.state.engine) as db:
        feed = get_feed(db, account, feed_id)
        if feed.kind == "website":
            return {"history_end": True, "message": "Website subscriptions track future changes"}
        if not feed.initial_done:
            raise HTTPException(409, "The initial feed import is still pending")
        if feed.history_end and not recheck:
            return {"history_end": True, "message": "No more articles in this feed."}
        job = enqueue(db, "older", feed.id)
        return {"history_end": False, "job_id": job.id, "status": job.status}


@router.get("/feeds/{feed_id}/archive")
def publisher_archive(request: Request, feed_id: str, account: CurrentAccount):
    with Session(request.app.state.engine) as db:
        feed = get_feed(db, account, feed_id)
        url = feed.url
    try:
        return {"url": feeds.publisher_archive(url, fetch_document=feeds.fetch)}
    except FetchError as error:
        raise HTTPException(422, str(error)) from error


@router.get("/jobs/{job_id}")
def job_status(request: Request, job_id: int, account: CurrentAccount):
    with Session(request.app.state.engine) as db:
        job = db.get(Job, job_id)
        if job is None:
            raise HTTPException(404, "Job not found")
        if job.kind in {"refresh", "older"}:
            target = db.get(Feed, job.target)
        elif job.kind == "extract":
            target = library.article_for_id(db, account.id, job.target)
        else:
            target = None
        if not target or target.account_id != account.id:
            raise HTTPException(404, "Job not found")
        return {"id": job.id, "kind": job.kind, "status": job.status,
                "attempts": job.attempts, "error": job.error, "finished_at": job.finished_at}


@router.get("/storage")
def storage(request: Request, account: CurrentAccount):
    with Session(request.app.state.engine) as db:
        return storage_data(db, account)


@router.patch("/storage")
def update_storage(request: Request, body: QuotaRequest, account: CurrentAccount):
    with write(request.app.state.engine) as db:
        current = db.get(Account, account.id)
        current.quota = body.quota_bytes
        return storage_data(db, current)


@router.post("/storage/remove-content")
def remove_content(request: Request, body: RemoveContentRequest, account: CurrentAccount):
    with write(request.app.state.engine) as db:
        result = library.clear_bodies(db, account.id, body.before)
        return result | storage_data(db, db.get(Account, account.id))


@router.get("/updates", response_class=StreamingResponse)
async def saved_updates(request: Request, account: CurrentAccount):
    async def events():
        # Reopen periodically to revalidate the session, including revoked access.
        loop = asyncio.get_running_loop()
        deadline = loop.time() + 60
        async with request.app.state.saved_updates.subscribe(account.id) as wakeup:
            yield "data: sync\n\n"
            while (remaining := deadline - loop.time()) > 0:
                try:
                    await asyncio.wait_for(wakeup.wait(), timeout=min(15, remaining))
                except TimeoutError:
                    yield ": keep-alive\n\n"
                else:
                    wakeup.clear()
                    yield "data: sync\n\n"

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"X-Accel-Buffering": "no"})


@router.get("/sync")
def sync(
    request: Request, account: CurrentAccount,
    after: Annotated[int, Query(ge=0, le=2**63 - 1)] = 0,
    limit: Annotated[int, Query(ge=1, le=200)] = 100,
):
    with Session(request.app.state.engine) as db:
        # Capture rows and their current objects from the same SQLite read snapshot.
        db.connection().exec_driver_sql("BEGIN")
        cursor = db.scalar(select(func.max(Change.id)).where(Change.account_id == account.id)) or 0
        if after > cursor:
            return {"reset_required": True, "items": [], "cursor": 0, "has_more": False}
        rows = list(db.scalars(select(Change).where(
            Change.account_id == account.id, Change.id > after
        ).order_by(Change.id).limit(limit + 1)))
        items = []
        for row in rows[:limit]:
            payload = None
            if row.operation == "upsert":
                if row.kind == "article" and (article := db.get(Article, row.object_id)):
                    payload = library.article_data(db, article)
                elif row.kind == "feed" and (feed := db.get(Feed, row.object_id)):
                    payload = feeds.feed_data(feed)
            if row.operation == "upsert" and payload is None:
                continue
            items.append({"sequence": row.id, "kind": row.kind, "id": row.object_id,
                          "operation": row.operation, "replacement_id": row.replacement_id, "data": payload})
        return {"items": items, "cursor": rows[min(len(rows), limit) - 1].id if rows else after,
                "has_more": len(rows) > limit, "reset_required": False}
