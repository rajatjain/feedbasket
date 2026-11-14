"""PDF upload reservations and permanent deletion."""

import re
from threading import Lock
from time import time_ns
from uuid import uuid4

from pypdf import PdfReader
from pypdf.errors import PdfReadError
from sqlalchemy import delete, func, select

from . import highlights, library, r2
from .db import Account, Article, Job, changed, enqueue, now, write

MAX_UPLOAD_BYTES = 100 * 1024 * 1024
RESERVATION_SECONDS = 24 * 60 * 60
# The backend already holds an exclusive database lock for its process lifetime.
OBJECT_LOCKS = tuple(Lock() for _ in range(64))


class InvalidPDF(Exception):
    pass


class PDFConflict(Exception):
    pass


class PDFQuotaExceeded(Exception):
    pass


class CleanupDeferred(Exception):
    def __init__(self, delay):
        super().__init__("PDF upload reservation is still active")
        self.delay = delay


def describe_file(file, filename):
    filename = filename.replace("\\", "/").rsplit("/", 1)[-1]
    filename = "".join(char for char in filename if char.isprintable()).strip()[:255] or "Document.pdf"
    if not re.match(rb"%PDF-[0-9]\.[0-9](?:\r|\n)", file.read(16)):
        raise InvalidPDF("This file couldn’t be read as a PDF. Choose another file.")
    try:
        file.seek(0)
        pdf = PdfReader(file)
        # Encrypted documents can still be opened by a PDF reader with the user's password.
        pages = None if pdf.is_encrypted else len(pdf.pages)
        if pages == 0:
            raise InvalidPDF("This PDF has no pages.")
    except (PdfReadError, ValueError, RecursionError) as error:
        raise InvalidPDF("This file couldn’t be read as a PDF. Choose another file.") from error
    finally:
        file.seek(0)
    return filename, pages


def used_bytes(db, account_id, *, include_reservations=False):
    query = select(func.coalesce(func.sum(Article.pdf_bytes), 0)).where(
        Article.account_id == account_id, Article.pdf_key.is_not(None),
    )
    if not include_reservations:
        query = query.where(Article.saved_at.is_not(None))
    return db.scalar(query)


def reserve(db, config, account_id, import_id, filename, size, digest, pages, tags):
    existing = db.scalar(select(Article).where(Article.account_id == account_id, Article.pdf_import_id == import_id))
    if existing:
        if existing.pdf_digest != digest or existing.content_status == "deleting":
            raise PDFConflict("This upload ID already belongs to a different or deleted PDF.")
        if existing.content_status == "uploading":
            existing.pdf_expires_at = now() + RESERVATION_SECONDS
        return existing
    if used_bytes(db, account_id, include_reservations=True) + size > db.get(Account, account_id).pdf_quota:
        raise PDFQuotaExceeded("The PDF storage limit would be exceeded.")
    article_id = str(uuid4())
    expires_at = now() + RESERVATION_SECONDS
    article = Article(
        id=article_id, account_id=account_id, url="", title=re.sub(r"\.pdf$", "", filename, flags=re.I) or filename,
        document_type="pdf", pdf_key=f"{config.pdf_prefix}{account_id}/{article_id}.pdf",
        pdf_filename=filename, pdf_bytes=size, pdf_import_id=import_id, pdf_digest=digest, pdf_pages=pages,
        pdf_expires_at=expires_at, content_status="uploading",
    )
    db.add(article)
    db.flush()
    library.set_tags(db, article, tags, replace=True)
    enqueue(db, "pdf_cleanup", article_id, run_at=expires_at)
    return article


def object_lock(article_id):
    return OBJECT_LOCKS[hash(article_id) % len(OBJECT_LOCKS)]


def import_file(engine, config, account_id, import_id, file, filename, size, digest, tags):
    if not config.r2_configured:
        raise r2.StorageUnavailable()
    filename, pages = describe_file(file, filename)
    with write(engine) as db:
        article = reserve(db, config, account_id, import_id, filename, size, digest, pages, tags)
        if article.content_status == "ready":
            return library.article_data(db, article), False
        article_id = article.id
    # A retry must not recreate an object while permanent deletion is in progress.
    with object_lock(article_id):
        with write(engine) as db:
            article = db.get(Article, article_id)
            if not article or article.content_status == "deleting":
                raise PDFConflict("This upload expired or was deleted. Add the file again.")
            if article.content_status == "ready":
                return library.article_data(db, article), False
            key = article.pdf_key
        r2.upload(config, key, file, size, digest)
        with write(engine) as db:
            article = db.get(Article, article_id)
            article.saved_at, article.content_status, article.pdf_expires_at = now(), "ready", None
            db.execute(delete(Job).where(Job.kind == "pdf_cleanup", Job.target == article.id, Job.status == "queued"))
            changed(db, account_id, "article", article.id)
            return library.article_data(db, article), True


def remove_entry(db, article):
    highlights.record_deletions(db, article.account_id, select(Article.id).where(Article.id == article.id))
    changed(db, article.account_id, "article", article.id, "delete")
    db.delete(article)


def request_deletion(db, article):
    if article.location != "trash":
        raise PDFConflict("Move the PDF to Trash before permanently deleting it.")
    if not article.pdf_key:
        remove_entry(db, article)
        return None, True
    updated = article.content_status != "deleting"
    article.content_status = "deleting"
    job = enqueue(db, "pdf_delete", article.id)
    job.account_id = article.account_id
    if updated:
        changed(db, article.account_id, "article", article.id)
    return job.id, updated


def save_position(db, article, *, page, offset, document_revision, updated_at):
    if article.content_status == "deleting":
        raise PDFConflict("This PDF is being deleted.")
    revision = highlights.pdf_revision(article, page, document_revision)
    moment = time_ns() // 1_000_000
    timestamp = updated_at or moment
    if timestamp > moment + 300_000:
        raise highlights.InvalidAnchor("The reading position timestamp is too far in the future.")
    current = article.reading_position
    if updated_at is not None and timestamp <= article.position_updated_at:
        return current, False
    position = {"page": page, "offset": offset, "document_revision": revision}
    if current and all(current[key] == value for key, value in position.items()):
        # Accept a newer client clock without creating a redundant sync event.
        if updated_at is not None:
            article.position_updated_at = timestamp
        return current, False
    timestamp = max(timestamp, article.position_updated_at + 1)
    article.position_updated_at = timestamp
    article.reading_position = position | {"updated_at": timestamp}
    changed(db, article.account_id, "article", article.id)
    return article.reading_position, True


def delete_object(engine, config, article_id, *, cleanup=False):
    with object_lock(article_id):
        return delete_locked_object(engine, config, article_id, cleanup=cleanup)


def delete_locked_object(engine, config, article_id, *, cleanup):
    with write(engine) as db:
        article = db.get(Article, article_id)
        if not article or not article.pdf_key:
            return None
        if cleanup:
            if article.saved_at is not None:
                return None
            if article.pdf_expires_at > (moment := now()):
                raise CleanupDeferred(article.pdf_expires_at - moment)
            article.content_status = "deleting"
        elif article.content_status != "deleting":
            return None
        key = article.pdf_key
    r2.delete(config, key)
    with write(engine) as db:
        article = db.get(Article, article_id)
        if article:
            if cleanup:
                db.delete(article)
            else:
                remove_entry(db, article)
                return article.account_id
