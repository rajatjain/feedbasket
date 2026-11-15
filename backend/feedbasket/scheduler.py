import asyncio
import logging
from threading import Event
from time import monotonic

from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session

from . import backups, extraction, feeds, library, pdfs, publisher
from .db import Article, Feed, Job, LoginAttempt, LoginSession, changed, enqueue, get_setting, now, set_setting, write
from .logs import publisher_url

log = logging.getLogger(__name__)


def process_article(engine, article_id, *, fetch_document=None, job_id=None, refresh=False):
    started = monotonic()
    with Session(engine) as db:
        article = db.get(Article, article_id)
        if not article or article.document_type != "article" or article.location == "trash" or article.content_status == "cleared":
            if refresh:
                raise extraction.FetchError("The article is no longer available to refresh")
            return
        url, rss_body = article.url, article.extractor == "rss" and not refresh

    try:
        if fetch_document is None:
            final_url, canonical, title, body, extractor = publisher.Budget().run("article", url, rss_body)
        else:
            final_url, canonical, title, body, extractor = extraction.load_article(
                url, rss_body, fetch_document=fetch_document,
            )
    except extraction.PDFUnsupported:
        if refresh:
            raise extraction.FetchError("The publisher now serves a PDF instead of an article") from None
        saved_account = None
        with write(engine) as db:
            article = db.get(Article, article_id)
            if article and article.document_type == "article" and article.content_status != "cleared":
                article = library.promote_saved_pdf(db, article)
                changed(db, article.account_id, "article", article.id)
                saved_account = article.account_id if article.saved_at is not None else None
        log.info("Reader extraction job_id=%s article_id=%s url=%r outcome=pdf_link elapsed_ms=%d",
                 job_id, article_id, publisher_url(url), (monotonic() - started) * 1000)
        return saved_account
    except extraction.FetchError:
        if rss_body:
            log.info("Reader extraction job_id=%s article_id=%s url=%r outcome=kept_rss_body elapsed_ms=%d",
                     job_id, article_id, publisher_url(url), (monotonic() - started) * 1000)
            return
        raise

    if refresh and not body:
        raise extraction.FetchError("The publisher page has no readable article content")
    with write(engine) as db:
        article = db.get(Article, article_id)
        if not article or article.document_type != "article" or article.content_status == "cleared":
            if refresh:
                raise extraction.FetchError("The article is no longer available to refresh")
            return
        article = library.merge_alias(db, article, final_url)
        article = library.merge_alias(db, article, canonical)
        if article.document_type == "article":
            article.url = canonical
        if title and (not article.title or article.title in {url, final_url}):
            article.title = title
        available = article.document_type == "article" and article.location != "trash" and article.content_status != "cleared"
        if refresh and not available:
            raise extraction.FetchError("The article is no longer available to refresh")
        if available:
            if body and (refresh or article.extractor != "rss"):
                stored = library.store_body(db, article, body, extractor)
                if refresh and not stored:
                    raise extraction.FetchError("The replacement exceeds your storage quota")
            elif not article.body:
                article.content_status = "unavailable"
        changed(db, article.account_id, "article", article.id)
        saved_account = article.account_id if article.saved_at is not None else None
        result_id, status, stored_extractor = article.id, article.content_status, article.extractor
    log.info("Reader extraction job_id=%s article_id=%s result_article_id=%s url=%r extractor=%s "
             "reader_status=%s elapsed_ms=%d", job_id, article_id, result_id, publisher_url(url),
             stored_extractor or extractor, status, (monotonic() - started) * 1000)
    return saved_account


def recover_jobs(engine):
    with write(engine) as db:
        db.execute(update(Job).where(Job.status == "running").values(status="queued", run_at=now()))


def tick(engine, config, *, fetch_document=None, publish_saved=None):
    with write(engine) as db:
        moment = now()
        for feed_id in db.scalars(select(Feed.id).where(Feed.active.is_(True), Feed.next_check <= moment)):
            enqueue(db, "refresh", feed_id)
        backups.schedule(db, config, moment)
        job = db.scalar(select(Job).where(Job.status == "queued", Job.run_at <= moment).order_by(Job.run_at, Job.id).limit(1))
        if not job:
            return False
        job.status = "running"
        job.attempts += 1
        job_id, kind, target, attempt = job.id, job.kind, job.target, job.attempts

    saved_account = None
    started = monotonic()
    try:
        if kind in {"refresh", "older"}:
            if fetch_document is None:
                fetch_document = publisher.Budget().fetch
            saved_account = feeds.refresh(engine, config, target, older=(kind == "older"),
                                          fetch_document=fetch_document, job_id=job_id)
        elif kind in {"extract", "reader_refresh"}:
            saved_account = process_article(engine, target, fetch_document=fetch_document, job_id=job_id,
                                            refresh=kind == "reader_refresh")
        elif kind == "backup":
            backups.run_backup(engine, config, job_id=job_id)
        elif kind in {"pdf_delete", "pdf_cleanup"}:
            saved_account = pdfs.delete_object(engine, config, target, cleanup=kind == "pdf_cleanup")
        else:
            raise ValueError("Unknown job kind")
    except Exception as error:
        error_type = type(error).__name__
        detail = str(error)[:1000] or error_type
        access_refused = (kind == "extract" and isinstance(error, extraction.PublisherHTTPError)
                          and error.status in {401, 403})
        if kind in {"pdf_delete", "pdf_cleanup"}:
            retry_in = error.delay if isinstance(error, pdfs.CleanupDeferred) else min(60 * attempt, 3600)
        else:
            retry_in = 60 * attempt if attempt < 3 and not access_refused and kind != "reader_refresh" else 0
        url = None
        with write(engine) as db:
            job = db.get(Job, job_id)
            job.error = detail
            article = db.get(Article, target) if kind in {"extract", "reader_refresh"} else None
            if article:
                url = publisher_url(article.url)
            if retry_in:
                job.status, job.run_at = "queued", now() + retry_in
            else:
                job.status, job.finished_at = "failed", now()
                if kind in {"refresh", "older"}:
                    feed = db.get(Feed, target)
                    if feed:
                        feed.error = job.error
                        if kind == "refresh":
                            default = int(get_setting(db, "feed_interval", config.feed_interval))
                            feed.last_checked = now()
                            feed.next_check = now() + (feed.interval_minutes or default) * 60
                        changed(db, feed.account_id, "feed", feed.id)
                elif kind == "extract":
                    if article and article.document_type == "article" and not article.body and article.content_status != "cleared":
                        article.content_status = "failed"
                        changed(db, article.account_id, "article", article.id)
                        if article.saved_at is not None:
                            saved_account = article.account_id
        log.warning("Job failed job_id=%s kind=%s target_id=%s url=%r attempt=%d status=%s retry_in_seconds=%d "
                    "elapsed_ms=%d reason=%r", job_id, kind, target, url, attempt,
                    "queued" if retry_in else "failed", retry_in, (monotonic() - started) * 1000,
                    detail if isinstance(error, extraction.FetchError) else error_type)
    else:
        with write(engine) as db:
            job = db.get(Job, job_id)
            job.status, job.error, job.finished_at = "done", None, now()
        log.debug("Job completed job_id=%s kind=%s target_id=%s", job_id, kind, target)
    if saved_account and publish_saved:
        publish_saved(saved_account)
    return True


def clean_expired(engine, config, moment):
    with write(engine) as db:
        db.execute(delete(LoginAttempt).where(LoginAttempt.expires_at <= moment))
        db.execute(delete(LoginSession).where(LoginSession.expires_at <= moment))
        db.execute(delete(Job).where(Job.finished_at < moment - 30 * 86400))
        backups.clean_staging(db, config.db_path)


def run_worker(engine, config, stop: Event, publish_saved=None):
    recover_jobs(engine)
    cleaned_at = 0
    backfilling_word_counts = True
    while not stop.is_set():
        try:
            moment = now()
            if moment - cleaned_at >= 3600:
                clean_expired(engine, config, moment)
                cleaned_at = moment
            if backfilling_word_counts:
                with write(engine) as db:
                    accounts = library.backfill_word_counts(db)
                backfilling_word_counts = bool(accounts)
                if publish_saved:
                    for account in accounts:
                        publish_saved(account)
            if tick(engine, config, publish_saved=publish_saved) or backfilling_word_counts:
                continue
        except Exception as error:
            log.error("Scheduler iteration failed (%s)", type(error).__name__)
        stop.wait(2)


async def worker_task(engine, config, stop, publish_saved=None):
    await asyncio.to_thread(run_worker, engine, config, stop, publish_saved)
