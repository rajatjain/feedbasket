import asyncio
import logging
from threading import Event
from time import monotonic

from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session

from . import backups, extraction, feeds, library
from .db import Article, Feed, Job, LoginAttempt, LoginSession, changed, enqueue, get_setting, now, set_setting, write
from .logs import publisher_url

log = logging.getLogger(__name__)


def process_article(engine, article_id, *, fetch_document=extraction.fetch, job_id=None):
    started = monotonic()
    with Session(engine) as db:
        article = db.get(Article, article_id)
        if not article or article.location == "trash" or article.content_status == "cleared":
            return
        url, rss_body = article.url, article.extractor == "rss"

    try:
        document = fetch_document(url)
    except extraction.PDFUnsupported:
        saved_account = None
        with write(engine) as db:
            article = db.get(Article, article_id)
            if article and not article.body and article.content_status != "cleared":
                article.content_status = "pdf_unsupported"
                changed(db, article.account_id, "article", article.id)
                saved_account = article.account_id if article.saved_at is not None else None
        log.info("Reader extraction job_id=%s article_id=%s url=%r outcome=pdf_unsupported elapsed_ms=%d",
                 job_id, article_id, publisher_url(url), (monotonic() - started) * 1000)
        return saved_account
    except extraction.FetchError:
        if rss_body:
            log.info("Reader extraction job_id=%s article_id=%s url=%r outcome=kept_rss_body elapsed_ms=%d",
                     job_id, article_id, publisher_url(url), (monotonic() - started) * 1000)
            return
        raise

    if rss_body:
        canonical = extraction.canonical_url(extraction.parse_html(document.data), document.url)
        title, body, extractor = "", None, None
    else:
        canonical, title, body, extractor = extraction.extract(document)
    with write(engine) as db:
        article = db.get(Article, article_id)
        if not article or article.content_status == "cleared":
            return
        article = library.merge_alias(db, article, document.url)
        article = library.merge_alias(db, article, canonical)
        article.url = canonical
        if title and (not article.title or article.title in {url, document.url}):
            article.title = title
        if article.location != "trash" and article.content_status != "cleared":
            if body and article.extractor != "rss":
                library.store_body(db, article, body, extractor)
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


def tick(engine, config, *, fetch_document=extraction.fetch, publish_saved=None):
    with write(engine) as db:
        moment = now()
        for feed_id in db.scalars(select(Feed.id).where(Feed.active.is_(True), Feed.next_check <= moment)):
            enqueue(db, "refresh", feed_id)
        backup = backups.options(db, config)
        interval = backups.INTERVALS.get(backup["frequency"])
        if interval:
            if not backup["next_at"]:
                set_setting(db, "backup_next_at", (backup["last_at"] or moment) + interval)
            elif backup["next_at"] <= moment:
                enqueue(db, "backup")
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
            saved_account = feeds.refresh(engine, config, target, older=(kind == "older"),
                                          fetch_document=fetch_document, job_id=job_id)
        elif kind == "extract":
            saved_account = process_article(engine, target, fetch_document=fetch_document, job_id=job_id)
        elif kind == "backup":
            backups.run_backup(engine, config, job_id=job_id)
        else:
            raise ValueError("Unknown job kind")
    except Exception as error:
        error_type = type(error).__name__
        detail = str(error)[:1000] or error_type
        access_refused = (kind == "extract" and isinstance(error, extraction.PublisherHTTPError)
                          and error.status in {401, 403})
        retry_in = 60 * attempt if attempt < 3 and not access_refused else 0
        url = None
        with write(engine) as db:
            job = db.get(Job, job_id)
            job.error = detail
            article = db.get(Article, target) if kind == "extract" else None
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
                    if article and not article.body and article.content_status != "cleared":
                        article.content_status = "failed"
                        changed(db, article.account_id, "article", article.id)
                        if article.saved_at is not None:
                            saved_account = article.account_id
                elif kind == "backup":
                    set_setting(db, "backup_next_at", now() + 3600)
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


def run_worker(engine, config, stop: Event, publish_saved=None):
    recover_jobs(engine)
    cleaned_at = 0
    while not stop.is_set():
        try:
            if now() - cleaned_at >= 3600:
                with write(engine) as db:
                    db.execute(delete(LoginAttempt).where(LoginAttempt.expires_at <= now()))
                    db.execute(delete(LoginSession).where(LoginSession.expires_at <= now()))
                    db.execute(delete(Job).where(Job.finished_at < now() - 30 * 86400))
                cleaned_at = now()
            if tick(engine, config, publish_saved=publish_saved):
                continue
        except Exception as error:
            log.error("Scheduler iteration failed (%s)", type(error).__name__)
        stop.wait(2)


async def worker_task(engine, config, stop, publish_saved=None):
    await asyncio.to_thread(run_worker, engine, config, stop, publish_saved)
