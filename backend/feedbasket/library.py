from collections import defaultdict
from time import time_ns
from uuid import uuid4

from sqlalchemy import delete, exists, func, insert, select, update
from sqlalchemy.orm import load_only

from . import highlights
from .db import (
    Account, Article, ArticleRedirect, ArticleTag, ArticleURL, Feed, FeedEntry, PurgedFeedEntry,
    changed, enqueue, now,
)
from .extraction import clean_text, normalize_url, pdf_url

WORD_COUNT_BLOCKS = {
    "article", "section", "div", "p", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6",
    "ul", "ol", "li", "dl", "dt", "dd", "blockquote", "pre", "table", "tr", "th", "td",
    "figure", "figcaption",
}

TRASH_RETENTION_SECONDS = 30 * 86400

def library_visible():
    return (Article.pdf_key.is_(None)) | (Article.saved_at.is_not(None))


def article_for_id(db, account_id, article_id):
    query = select(Article).where(Article.account_id == account_id, library_visible())
    if article := db.scalar(query.where(Article.id == article_id)):
        return article
    redirect = db.get(ArticleRedirect, (account_id, article_id))
    if redirect:
        return db.scalar(query.where(Article.id == redirect.article_id))


def article_for_url(db, account_id, url):
    alias = db.get(ArticleURL, (account_id, url))
    return db.get(Article, alias.article_id) if alias else None


def locate(db, account_id, url, title="", published_at=None):
    if article := article_for_url(db, account_id, url):
        return article
    article = Article(
        id=str(uuid4()), account_id=account_id, url=url, title=title or url,
        published_at=published_at,
    )
    db.add(article)
    db.flush()
    db.add(ArticleURL(account_id=account_id, url=url, article_id=article.id))
    db.flush()
    return article


def merge_alias(db, article, url):
    account_id = article.account_id
    alias = db.get(ArticleURL, (account_id, url))
    if not alias:
        db.add(ArticleURL(account_id=account_id, url=url, article_id=article.id))
        db.flush()
        return article
    if alias.article_id == article.id:
        return article

    duplicate = db.get(Article, alias.article_id)
    winner, loser = sorted((article, duplicate), key=lambda item: (item.created_at, item.id))
    if (loser.state_at, loser.location != "inbox") > (winner.state_at, winner.location != "inbox"):
        winner.location, winner.trash_origin, winner.state_at = loser.location, loser.trash_origin, loser.state_at
    if loser.read_at > winner.read_at:
        winner.read, winner.read_at = loser.read, loser.read_at
    if loser.starred_at > winner.starred_at:
        winner.starred, winner.starred_at = loser.starred, loser.starred_at
    saved = [value for value in (winner.saved_at, loser.saved_at) if value is not None]
    winner.saved_at = max(saved) if saved else None
    winner.published_at = winner.published_at or loser.published_at
    winner.excerpt = winner.excerpt or loser.excerpt
    winner.author = winner.author or loser.author
    if winner.title == winner.url and loser.title != loser.url:
        winner.title = loser.title
    if winner.content_status in {"pending", "failed", "unavailable", "quota"} and loser.body:
        winner.body, winner.body_bytes = loser.body, loser.body_bytes
        winner.word_count = loser.word_count
        winner.extractor, winner.content_status = loser.extractor, loser.content_status

    for model in (ArticleURL, FeedEntry, ArticleRedirect):
        db.execute(update(model).where(model.article_id == loser.id).values(article_id=winner.id))
    if loser.document_type == "pdf" and winner.document_type != "pdf":
        mark_pdf_link(db, winner, loser.url)
    if loser.position_updated_at > winner.position_updated_at:
        winner.reading_position, winner.position_updated_at = loser.reading_position, loser.position_updated_at
    highlights.move(db, loser, winner)
    winner.submitted_url = winner.submitted_url or loser.submitted_url
    tags = set(db.scalars(select(ArticleTag.tag).where(ArticleTag.article_id == winner.id)))
    for tag in db.scalars(select(ArticleTag.tag).where(ArticleTag.article_id == loser.id)):
        if tag not in tags:
            db.add(ArticleTag(article_id=winner.id, tag=tag))
    db.add(ArticleRedirect(account_id=account_id, old_id=loser.id, article_id=winner.id))
    changed(db, account_id, "article", loser.id, "redirect", winner.id)
    changed(db, account_id, "article", winner.id)
    db.delete(loser)
    db.flush()
    return winner


def promote_saved_pdf(db, article):
    url = article.submitted_url or article.url
    exact = normalize_url(url, keep_query=True)
    return mark_pdf_link(db, merge_alias(db, article, exact), url)


def tags_for(db, article_id):
    return list(db.scalars(select(ArticleTag.tag).where(ArticleTag.article_id == article_id).order_by(ArticleTag.tag)))


def set_tags(db, article, tags, *, replace):
    clean = {tag.strip().casefold() for tag in tags if tag.strip()}
    if len(clean) > 30 or any(len(tag) > 80 for tag in clean):
        raise ValueError("Use up to 30 tags of at most 80 characters each")
    existing = set(tags_for(db, article.id))
    if not replace and len(clean | existing) > 30:
        raise ValueError("Use up to 30 tags per article")
    if replace:
        db.execute(delete(ArticleTag).where(ArticleTag.article_id == article.id, ArticleTag.tag.in_(existing - clean)))
    for tag in clean - existing:
        db.add(ArticleTag(article_id=article.id, tag=tag))
    return clean != existing if replace else bool(clean - existing)


def mark_pdf_link(db, article, url):
    if article.document_type == "pdf":
        return article
    exact = normalize_url(url, keep_query=True)
    ordinary = normalize_url(url)
    if not db.get(ArticleURL, (article.account_id, exact)):
        db.add(ArticleURL(account_id=article.account_id, url=exact, article_id=article.id))
    if exact != ordinary:
        alias = db.get(ArticleURL, (article.account_id, ordinary))
        if alias and alias.article_id == article.id:
            db.delete(alias)
    if article.title == article.url:
        article.title = url
    article.document_type = "pdf"
    article.url = url
    article.content_status = "ready"
    article.body, article.body_bytes, article.extractor = None, 0, None
    article.word_count = None
    return article


def locate_saved_link(db, account_id, exact, ordinary, *, is_pdf):
    if article := article_for_url(db, account_id, exact):
        if is_pdf and article.document_type == "article" and article.submitted_url:
            submitted = normalize_url(article.submitted_url, keep_query=True)
            if submitted != exact:
                # An article alias can omit tracking parameters that a PDF's signature uses.
                db.delete(db.get(ArticleURL, (account_id, exact)))
                db.flush()
                if not article_for_url(db, account_id, submitted):
                    db.add(ArticleURL(account_id=account_id, url=submitted, article_id=article.id))
                return locate(db, account_id, exact)
        return article
    candidate = article_for_url(db, account_id, ordinary) if ordinary != exact else None
    if candidate and candidate.document_type == "article":
        if not is_pdf or (candidate.submitted_url and normalize_url(candidate.submitted_url, keep_query=True) == exact):
            return candidate
    return locate(db, account_id, exact if is_pdf or candidate else ordinary)


def save_article(db, account_id, url, title, tags, *, document_type="article", subscribe=False):
    exact = normalize_url(url, keep_query=True)
    is_pdf = document_type == "pdf" or pdf_url(exact)
    article = locate_saved_link(db, account_id, exact, normalize_url(url), is_pdf=is_pdf)
    if subscribe and (is_pdf or article.document_type == "pdf"):
        raise ValueError("PDF links cannot be saved with a subscription.")
    if article.content_status == "deleting":
        raise ValueError("This PDF is being deleted")
    converted = is_pdf and article.document_type != "pdf"
    if converted:
        article = mark_pdf_link(db, article, url.strip())
    first_save = article.saved_at is None
    reopen = article.read or article.location != "inbox"
    tags_changed = set_tags(db, article, tags, replace=False)
    if not first_save and not reopen and not tags_changed and not converted:
        return article, False
    if first_save:
        article.saved_at = now()
        article.submitted_url = url.strip()
        # A URL alias may only resolve to an older article during extraction.
        article.read_at = article.state_at = time_ns()
    if (first_save or reopen or converted) and title and article.title == article.url:
        article.title = title
    if article.document_type == "article" and (first_save or reopen) and article.body is None and article.content_status in {
        "pending", "failed", "unavailable", "quota",
    }:
        enqueue(db, "extract", article.id)
    update_article(db, article, read=False, action="restore_inbox")
    return article, True


def update_article(db, article, *, read=None, starred=None, action=None, tags=None):
    if read is not None and read != article.read:
        article.read, article.read_at = read, time_ns()
    if starred is not None and starred != article.starred:
        article.starred, article.starred_at = starred, time_ns()
    if action == "trash_if_read":
        if (article.document_type == "article" and article.location == "inbox"
                and article.read and not article.starred):
            action = "trash"
        elif read is None and starred is None and tags is None:
            return
    if action == "trash" and article.location != "trash":
        article.trash_origin = article.location
        article.location, article.state_at = "trash", time_ns()
    elif action == "archive" and article.location == "inbox":
        article.location, article.state_at = "archive", time_ns()
    elif action == "restore_archive" and article.location == "trash":
        article.location, article.trash_origin, article.state_at = "archive", None, time_ns()
    elif action == "restore_inbox" and article.location != "inbox":
        article.location, article.trash_origin, article.state_at = "inbox", None, time_ns()
    elif action == "restore" and article.location != "inbox":
        article.location = (article.trash_origin or "inbox") if article.location == "trash" else "inbox"
        article.trash_origin, article.state_at = None, time_ns()
    if tags is not None:
        set_tags(db, article, tags, replace=True)
    changed(db, article.account_id, "article", article.id)


def remove_entry(db, article):
    highlights.record_deletions(db, article.account_id, select(Article.id).where(Article.id == article.id))
    changed(db, article.account_id, "article", article.id, "delete")
    db.delete(article)


def purge_expired_trash(db, moment):
    cutoff = (moment - TRASH_RETENTION_SECONDS) * 1_000_000_000
    accounts = set()
    expired = select(Article).options(load_only(Article.id, Article.account_id)).where(
        Article.document_type == "article", Article.location == "trash", Article.state_at <= cutoff,
    )
    for article in db.scalars(expired):
        # Preserve subscription deduplication after deleting the article and its body.
        db.execute(insert(PurgedFeedEntry).from_select(
            ["feed_id", "key"], select(FeedEntry.feed_id, FeedEntry.key).join(Feed).where(
                FeedEntry.article_id == article.id, Feed.kind == "feed",
            ),
        ))
        remove_entry(db, article)
        accounts.add(article.account_id)
    return accounts


def stored_bytes(db, account_id):
    return db.scalar(select(func.coalesce(func.sum(Article.body_bytes), 0)).where(Article.account_id == account_id))


def count_words(body):
    text = clean_text(body, block_tags=WORD_COUNT_BLOCKS)
    return sum(any(char.isalnum() for char in token) for token in text.split())


def backfill_word_counts(db, *, limit=100):
    articles = db.scalars(select(Article).where(
        Article.document_type == "article", Article.body.is_not(None), Article.word_count.is_(None),
    ).order_by(Article.id).limit(limit)).all()
    for article in articles:
        article.word_count = count_words(article.body)
        changed(db, article.account_id, "article", article.id)
    return {article.account_id for article in articles}


def store_body(db, article, body, extractor):
    size = len(body.encode("utf-8"))
    quota = db.get(Account, article.account_id).quota
    fits_quota = stored_bytes(db, article.account_id) - article.body_bytes + size <= quota
    if not fits_quota:
        if not article.body:
            article.content_status = "quota"
    else:
        article.body, article.body_bytes = body, size
        article.word_count = count_words(body)
        article.extractor, article.content_status = extractor, "ready"
    changed(db, article.account_id, "article", article.id)
    return fits_quota


def clear_bodies(db, account_id, before=None):
    query = select(Article).where(Article.account_id == account_id, Article.body_bytes > 0)
    if before is not None:
        query = query.where(func.coalesce(Article.published_at, Article.created_at) < before)
    count, freed = 0, 0
    for article in db.scalars(query):
        count += 1
        freed += article.body_bytes
        article.body, article.body_bytes = None, 0
        article.word_count = None
        article.extractor, article.content_status = None, "cleared"
        changed(db, account_id, "article", article.id)
    return {"article_count": count, "bytes_freed": freed}


def feed_ids(db, article_id):
    return list(db.scalars(select(FeedEntry.feed_id).join(Feed).where(
        FeedEntry.article_id == article_id, Feed.active.is_(True)
    ).distinct().order_by(FeedEntry.feed_id)))


def article_data(db, article, *, body=False):
    return serialize_article(article, tags_for(db, article.id), feed_ids(db, article.id), body=body)


def article_page_data(db, articles):
    ids = [article.id for article in articles]
    if not ids:
        return {}
    tags, feeds = defaultdict(list), defaultdict(list)
    for article_id, tag in db.execute(select(ArticleTag.article_id, ArticleTag.tag).where(
        ArticleTag.article_id.in_(ids),
    ).order_by(ArticleTag.tag)):
        tags[article_id].append(tag)
    for article_id, feed_id in db.execute(select(FeedEntry.article_id, FeedEntry.feed_id).join(Feed).where(
        FeedEntry.article_id.in_(ids), Feed.active.is_(True),
    ).distinct().order_by(FeedEntry.feed_id)):
        feeds[article_id].append(feed_id)
    return {article.id: serialize_article(article, tags[article.id], feeds[article.id]) for article in articles}


def serialize_article(article, tags, feeds, *, body=False):
    data = {
        "id": article.id, "url": article.url, "title": article.title, "author": article.author,
        "published_at": article.published_at, "created_at": article.created_at, "saved_at": article.saved_at,
        "read": article.read, "starred": article.starred, "location": article.location, "trash_origin": article.trash_origin,
        "tags": tags, "feed_ids": feeds, "excerpt": article.excerpt,
        "content_status": article.content_status, "extractor": article.extractor, "body_bytes": article.body_bytes,
        "word_count": article.word_count,
    }
    data["document_type"] = article.document_type
    if article.document_type == "pdf":
        data["pdf"] = {
            "source": "upload" if article.pdf_key else "link",
            "filename": article.pdf_filename,
            "size_bytes": article.pdf_bytes,
            "page_count": article.pdf_pages,
            "document_revision": article.pdf_digest,
            "deletion_pending": article.content_status == "deleting",
        }
        data["reading_position"] = article.reading_position
    if body:
        data["body_html"] = article.body
    return data


def article_query(account_id, source, location, feed_id, tag, read, document_type=None, *,
                  category_id=None, uncategorized=False):
    query = select(Article).where(Article.account_id == account_id, library_visible())
    if document_type is not None:
        query = query.where(Article.document_type == document_type)
    if location == "starred":
        query = query.where(Article.starred.is_(True), Article.location != "trash")
    else:
        query = query.where(Article.location == location)
    feed_exists = exists(select(FeedEntry.feed_id).join(Feed).where(
        FeedEntry.article_id == Article.id, Feed.active.is_(True), Feed.account_id == account_id
    ))
    if source == "rss":
        query = query.where(feed_exists)
    elif source == "saved":
        query = query.where(Article.saved_at.is_not(None))
    elif location == "inbox":
        query = query.where((Article.saved_at.is_not(None)) | feed_exists)
    if feed_id or category_id or uncategorized:
        linked_feeds = select(FeedEntry.feed_id).join(Feed).where(
            FeedEntry.article_id == Article.id, Feed.account_id == account_id, Feed.active.is_(True)
        )
        if feed_id:
            linked_feeds = linked_feeds.where(Feed.id == feed_id)
        if category_id or uncategorized:
            linked_feeds = linked_feeds.where(Feed.category_id == category_id)
        query = query.where(exists(linked_feeds))
    if tag:
        query = query.where(exists(select(ArticleTag.tag).where(
            ArticleTag.article_id == Article.id, ArticleTag.tag == tag.strip().casefold()
        )))
    if read is not None:
        query = query.where(Article.read == read)
    sort = func.coalesce(Article.published_at, Article.created_at)
    if source == "saved" and location == "inbox":
        sort = Article.saved_at
    elif location in {"archive", "trash"}:
        sort = Article.state_at
    return query.order_by(sort.desc(), Article.id)
