import asyncio
import logging
from hashlib import sha256
from pathlib import PurePosixPath
from tempfile import TemporaryFile
from typing import Annotated, Literal
from urllib.parse import unquote, urlsplit
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field, StringConstraints, model_validator
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool
from starlette.requests import ClientDisconnect

from . import feeds, highlights, library, pdfs, publisher, r2
from .auth import current_account, profile, revoke
from .db import Account, Article, ArticleTag, Change, Feed, Job, changed, enqueue, get_setting, now, write
from .extraction import FetchError, PDFUnsupported, normalize_url, pdf_url
from .logs import publisher_url

router = APIRouter(prefix="/api/v1")
log = logging.getLogger(__name__)
CurrentAccount = Annotated[Account, Depends(current_account)]
Source = Literal["all", "rss", "saved"]
Location = Literal["inbox", "archive", "trash", "starred"]
DocumentType = Literal["article", "pdf"]


class SaveRequest(BaseModel):
    url: str = Field(max_length=4000)
    title: str = Field(default="", max_length=500)
    tags: list[str] = Field(default_factory=list, max_length=30)
    subscribe_url: str | None = Field(default=None, max_length=4000)
    document_type: DocumentType = "article"


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


class FeedPatch(BaseModel):
    interval_minutes: int | None = Field(default=None, ge=5, le=10080)
    custom_title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)] | None = None


class QuotaRequest(BaseModel):
    quota_bytes: int = Field(ge=0, le=10**12)


class RemoveContentRequest(BaseModel):
    before: int | None = Field(default=None, ge=0, le=253402300799)


class ReadingPosition(BaseModel):
    page: int = Field(ge=1, le=10**7)
    offset: float = Field(ge=0, le=1)
    document_revision: str | None = Field(default=None, pattern=r"^[a-f0-9]{64}$")
    updated_at: int | None = Field(default=None, ge=1, le=2**63 - 1, description="Unix time in milliseconds")


class PDFQuad(BaseModel):
    page: int = Field(ge=1, le=10**7)
    # Four points in normalized page coordinates.
    points: tuple[Annotated[float, Field(ge=0, le=1)], ...] = Field(min_length=8, max_length=8)


class PDFAnchor(BaseModel):
    kind: Literal["pdf"]
    quads: list[PDFQuad] = Field(min_length=1, max_length=512)
    document_revision: str | None = Field(default=None, pattern=r"^[a-f0-9]{64}$")


class ArticleAnchor(BaseModel):
    kind: Literal["article"]
    prefix: str = Field(default="", max_length=250)
    suffix: str = Field(default="", max_length=250)


class HighlightRequest(BaseModel):
    id: UUID = Field(default_factory=uuid4)
    style: Literal["highlight", "underline"] = "highlight"
    quote: str = Field(min_length=1, max_length=8000)
    color: str = Field(default="#ffe873", pattern=r"^#[a-fA-F0-9]{6}$")
    anchor: Annotated[PDFAnchor | ArticleAnchor, Field(discriminator="kind")]

    @model_validator(mode="after")
    def validate_style(self):
        if self.anchor.kind == "article" and self.style == "underline":
            raise ValueError("Underlines are available in PDFs")
        if not self.quote.strip():
            raise ValueError("Select text to highlight")
        return self


def checked_url(value, *, allow_pdf=False, keep_query=False):
    try:
        url = normalize_url(value, keep_query=keep_query)
    except ValueError as error:
        raise HTTPException(422, str(error)) from error
    if not allow_pdf and pdf_url(url):
        raise HTTPException(415, {"code": "pdf_not_feed", "message": "A PDF cannot be used as a feed."})
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
    pdf_used = pdfs.used_bytes(db, account.id)
    return {"used_bytes": used, "quota_bytes": account.quota,
            "warning": used >= account.quota * 0.8,
            "at_limit": used >= account.quota,
            "pdf_used_bytes": pdf_used, "pdf_quota_bytes": account.pdf_quota,
            "pdf_at_limit": pdf_used >= account.pdf_quota}


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
    document_type: DocumentType | None = None,
):
    with Session(request.app.state.engine) as db:
        query = library.article_query(account.id, source, location, feed_id, tag, read, document_type)
        rows = list(db.scalars(query.offset(offset).limit(limit + 1)))
        return {
            "items": list(library.article_page_data(db, rows[:limit]).values()),
            "next_offset": offset + limit if len(rows) > limit else None,
        }


@router.post("/articles", status_code=202)
def save(request: Request, body: SaveRequest, account: CurrentAccount):
    feed_url = checked_url(body.subscribe_url) if body.subscribe_url else None
    with write(request.app.state.engine) as db:
        try:
            article, updated = library.save_article(
                db, account.id, body.url, body.title.strip(), body.tags,
                document_type=body.document_type, subscribe=feed_url is not None,
            )
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
                 publisher_url(result["article"]["url"]), updated, result["article"]["content_status"],
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
        if article.content_status == "deleting":
            raise HTTPException(409, "This PDF is being deleted.")
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


@router.get("/links/preview")
def preview_link(request: Request, url: Annotated[str, Query(max_length=4000)], account: CurrentAccount):
    checked = checked_url(url, allow_pdf=True, keep_query=True)
    try:
        document = publisher.Budget().preview(checked)
    except FetchError as error:
        raise HTTPException(422, {"code": "preview_unavailable", "message": str(error)}) from error
    if document.media_type == "application/pdf":
        return {"kind": "pdf", "url": url.strip(), "media_type": document.media_type,
                "title": unquote(PurePosixPath(urlsplit(document.url).path).name)[:500] or urlsplit(document.url).hostname}
    parsed_feed = feeds.read_feed(document)
    try:
        result = feeds.preview_document(document, feed=parsed_feed)
    except FetchError:
        return {"kind": "unsupported", "url": url.strip(), "media_type": document.media_type}
    with Session(request.app.state.engine) as db:
        subscribed = feeds.active_subscriptions(db, account.id)
    for candidate in result["feeds"]:
        candidate["already_subscribed"] = subscribed.get(candidate["url"]) == "feed"
    return result | {"kind": "feed" if parsed_feed.version else "article",
                     "url": url.strip(), "media_type": document.media_type}


@router.post("/pdfs/import", status_code=201, openapi_extra={
    "requestBody": {"required": True, "content": {"application/pdf": {"schema": {"type": "string", "format": "binary"}}}},
})
async def import_pdf(request: Request, account: CurrentAccount,
                     import_id: Annotated[UUID, Query()], filename: Annotated[str, Query(min_length=1, max_length=1024)],
                     tags: Annotated[list[str] | None, Query(max_length=30)] = None):
    config = request.app.state.config
    if not config.r2_configured:
        raise HTTPException(503, "PDF uploads are unavailable. Configure R2 on the backend.")
    length = request.headers.get("content-length")
    if length and length.isdigit() and int(length) > pdfs.MAX_UPLOAD_BYTES:
        raise HTTPException(413, "PDF files can be up to 100 MiB.")
    with TemporaryFile() as file:
        size, digest = 0, sha256()
        try:
            async for chunk in request.stream():
                size += len(chunk)
                if size > pdfs.MAX_UPLOAD_BYTES:
                    raise HTTPException(413, "PDF files can be up to 100 MiB.")
                digest.update(chunk)
                await run_in_threadpool(file.write, chunk)
        except ClientDisconnect as error:
            raise HTTPException(400, "The PDF upload was interrupted.") from error
        file.seek(0)
        try:
            article, updated = await run_in_threadpool(
                pdfs.import_file, request.app.state.engine, config, account.id, str(import_id),
                file, filename, size, digest.hexdigest(), tags or [],
            )
        except pdfs.InvalidPDF as error:
            raise HTTPException(415, str(error)) from error
        except (pdfs.PDFConflict, pdfs.PDFQuotaExceeded) as error:
            raise HTTPException(409, str(error)) from error
        except r2.StorageUnavailable as error:
            raise HTTPException(503, str(error)) from error
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
    if updated:
        request.app.state.saved_updates.publish(account.id)
    return article


def get_pdf(db, account, article_id):
    return require_pdf(get_article(db, account, article_id))


def require_pdf(article):
    if article.document_type != "pdf":
        raise HTTPException(404, "PDF not found.")
    return article


@router.get("/pdfs/{article_id}/download")
def open_pdf(request: Request, article_id: str, account: CurrentAccount):
    with Session(request.app.state.engine) as db:
        article = get_pdf(db, account, article_id)
        if article.content_status == "deleting":
            raise HTTPException(409, "This PDF is being deleted.")
        if not article.pdf_key:
            return {"url": article.url, "expires_in": None}
        try:
            return {"url": r2.download_url(request.app.state.config, article.pdf_key), "expires_in": r2.DOWNLOAD_SECONDS}
        except r2.StorageUnavailable as error:
            raise HTTPException(503, str(error)) from error


@router.delete("/pdfs/{article_id}/permanent", status_code=202)
def delete_pdf(request: Request, article_id: str, account: CurrentAccount):
    with write(request.app.state.engine) as db:
        article = library.article_for_id(db, account.id, article_id)
        if article is None:
            return Response(status_code=204)
        require_pdf(article)
        try:
            job_id, updated = pdfs.request_deletion(db, article)
        except pdfs.PDFConflict as error:
            raise HTTPException(409, str(error)) from error
    if updated:
        request.app.state.saved_updates.publish(account.id)
    if job_id is None:
        return Response(status_code=204)
    return {"job_id": job_id, "deletion_pending": True}


@router.put("/pdfs/{article_id}/position")
def update_pdf_position(request: Request, article_id: str, body: ReadingPosition, account: CurrentAccount):
    with write(request.app.state.engine) as db:
        article = get_pdf(db, account, article_id)
        try:
            result, updated = pdfs.save_position(db, article, **body.model_dump())
        except highlights.InvalidAnchor as error:
            raise HTTPException(422, str(error)) from error
        except (highlights.HighlightConflict, pdfs.PDFConflict) as error:
            raise HTTPException(409, str(error)) from error
    if updated:
        request.app.state.saved_updates.publish(account.id)
    return result


@router.get("/highlights")
def list_highlights(
    request: Request, account: CurrentAccount, article_id: UUID | None = None,
    document_type: DocumentType | None = None,
    tag: Annotated[str | None, Query(max_length=80)] = None,
    search: Annotated[str | None, Query(max_length=200)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
):
    with Session(request.app.state.engine) as db:
        article_id = get_article(db, account, str(article_id)).id if article_id else None
        query = highlights.query(account.id, article_id, document_type, tag, search)
        rows = list(db.scalars(query.offset(offset).limit(limit + 1)))
        return {"items": [highlights.data(highlight) for highlight in rows[:limit]],
                "next_offset": offset + limit if len(rows) > limit else None}


@router.post("/articles/{article_id}/highlights", status_code=201)
def save_highlight(request: Request, article_id: str, body: HighlightRequest, account: CurrentAccount):
    with write(request.app.state.engine) as db:
        article = get_article(db, account, article_id)
        try:
            highlight, updated = highlights.save(
                db, article, str(body.id), **body.model_dump(mode="json", exclude={"id"}),
            )
        except highlights.InvalidAnchor as error:
            raise HTTPException(422, str(error)) from error
        except highlights.HighlightConflict as error:
            raise HTTPException(409, str(error)) from error
        result = highlights.data(highlight)
    if updated:
        request.app.state.saved_updates.publish(account.id)
    return result


@router.delete("/highlights/{highlight_id}", status_code=204)
def delete_highlight(request: Request, highlight_id: UUID, account: CurrentAccount):
    with write(request.app.state.engine) as db:
        highlight = highlights.get(db, account.id, str(highlight_id))
        if not highlight:
            raise HTTPException(404, "Highlight not found.")
        highlights.remove(db, highlight)
    request.app.state.saved_updates.publish(account.id)


@router.post("/articles/{article_id}/extract", status_code=202)
def extract_article(request: Request, article_id: str, account: CurrentAccount):
    return queue_reader_extraction(request, article_id, account)


@router.post("/articles/{article_id}/refresh-reader", status_code=202)
def refresh_reader(request: Request, article_id: str, account: CurrentAccount):
    return queue_reader_extraction(request, article_id, account, refresh=True)


def queue_reader_extraction(request, article_id, account, *, refresh=False):
    with write(request.app.state.engine) as db:
        article = get_article(db, account, article_id)
        if article.location == "trash":
            raise HTTPException(409, "Restore the article before requesting its reader content")
        if article.document_type == "pdf":
            raise HTTPException(415, "PDFs open in the PDF reader.")
        if article.extractor == "website":
            raise HTTPException(409, "Website snapshots cannot be re-extracted")
        if not article.body:
            article.content_status = "pending"
            changed(db, account.id, "article", article.id)
        job = enqueue(db, "reader_refresh" if refresh else "extract", article.id)
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
                Article.account_id == account.id, Article.location != "trash", library.library_visible(),
            ).group_by(ArticleTag.tag).order_by(count.desc(), ArticleTag.tag))
            return [{"name": name, "count": total} for name, total in rows]
        return list(db.scalars(select(ArticleTag.tag).join(Article).where(
            Article.account_id == account.id, Article.location == "inbox", Article.saved_at.is_not(None), library.library_visible(),
        ).distinct().order_by(ArticleTag.tag)))


@router.get("/feeds")
def subscriptions(request: Request, account: CurrentAccount):
    with Session(request.app.state.engine) as db:
        return [feeds.feed_data(feed) for feed in db.scalars(select(Feed).where(
            Feed.account_id == account.id, Feed.active.is_(True)
        ).order_by(func.coalesce(Feed.custom_title, Feed.title), Feed.id))]


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
def update_feed(request: Request, feed_id: str, body: FeedPatch, account: CurrentAccount):
    fields = body.model_fields_set
    with write(request.app.state.engine) as db:
        feed = get_feed(db, account, feed_id)
        if "interval_minutes" in fields:
            default = int(get_setting(db, "feed_interval", request.app.state.config.feed_interval))
            feed.interval_minutes = body.interval_minutes
            feed.next_check = (feed.last_checked + (body.interval_minutes or default) * 60
                               if feed.last_checked else now())
        if "custom_title" in fields:
            feed.custom_title = body.custom_title
        if fields:
            changed(db, account.id, "feed", feed.id)
        result = feeds.feed_data(feed)
    if fields:
        request.app.state.saved_updates.publish(account.id)
    if "interval_minutes" in fields:
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
        elif job.kind in {"extract", "reader_refresh"}:
            target = library.article_for_id(db, account.id, job.target)
        else:
            target = None
        owner_id = job.account_id if job.kind == "pdf_delete" else target.account_id if target else None
        if owner_id != account.id:
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


@router.patch("/storage/pdfs")
def update_pdf_storage(request: Request, body: QuotaRequest, account: CurrentAccount):
    with write(request.app.state.engine) as db:
        current = db.get(Account, account.id)
        current.pdf_quota = body.quota_bytes
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
    library_id: Annotated[str | None, Query(max_length=36)] = None,
):
    with Session(request.app.state.engine) as db:
        # Capture rows and their current objects from the same SQLite read snapshot.
        db.connection().exec_driver_sql("BEGIN")
        cursor = db.scalar(select(func.max(Change.id)).where(Change.account_id == account.id)) or 0
        current_library = get_setting(db, "library_id", None)
        if after > cursor or (library_id is not None and library_id != current_library):
            return {"reset_required": True, "items": [], "cursor": 0, "has_more": False,
                    "library_id": current_library}
        rows = list(db.scalars(select(Change).where(
            Change.account_id == account.id, Change.id > after
        ).order_by(Change.id).limit(limit + 1)))
        article_ids = {row.object_id for row in rows[:limit] if row.kind == "article" and row.operation == "upsert"}
        articles = library.article_page_data(db, list(db.scalars(select(Article).where(
            Article.account_id == account.id, Article.id.in_(article_ids), library.library_visible(),
        )))) if article_ids else {}
        items = []
        for row in rows[:limit]:
            payload = None
            if row.operation == "upsert":
                if row.kind == "article":
                    payload = articles.get(row.object_id)
                elif row.kind == "feed" and (feed := db.get(Feed, row.object_id)) and feed.account_id == account.id:
                    payload = feeds.feed_data(feed)
                elif row.kind == "highlight" and (highlight := highlights.get(db, account.id, row.object_id)):
                    payload = highlights.data(highlight)
            if row.operation == "upsert" and payload is None:
                continue
            items.append({"sequence": row.id, "kind": row.kind, "id": row.object_id,
                          "operation": row.operation, "replacement_id": row.replacement_id, "data": payload})
        return {"items": items, "cursor": rows[min(len(rows), limit) - 1].id if rows else after,
                "has_more": len(rows) > limit, "reset_required": False, "library_id": current_library}
