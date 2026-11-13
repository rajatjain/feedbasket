from time import time_ns
from uuid import uuid4

from sqlalchemy import delete, exists, func, select, update

from .db import (
    Account, Article, ArticleRedirect, ArticleTag, ArticleURL, Feed, FeedEntry,
    changed, enqueue, now,
)


def article_for_id(db, account_id, article_id):
    article = db.get(Article, article_id)
    if article and article.account_id == account_id:
        return article
    redirect = db.get(ArticleRedirect, (account_id, article_id))
    return db.get(Article, redirect.article_id) if redirect else None


def locate(db, account_id, url, title="", published_at=None):
    alias = db.get(ArticleURL, (account_id, url))
    if alias:
        return db.get(Article, alias.article_id)
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
        winner.extractor, winner.content_status = loser.extractor, loser.content_status

    for model in (ArticleURL, FeedEntry, ArticleRedirect):
        db.execute(update(model).where(model.article_id == loser.id).values(article_id=winner.id))
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


def save_article(db, account_id, url, title, tags):
    article = locate(db, account_id, url, title)
    first_save = article.saved_at is None
    reopen = article.read or article.location != "inbox"
    tags_changed = set_tags(db, article, tags, replace=False)
    if not first_save and not reopen and not tags_changed:
        return article, False
    if first_save:
        article.saved_at = now()
        # A URL alias may only resolve to an older article during extraction.
        article.read_at = article.state_at = time_ns()
    if (first_save or reopen) and title and article.title == article.url:
        article.title = title
    if (first_save or reopen) and article.body is None and article.content_status in {
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


def stored_bytes(db, account_id):
    return db.scalar(select(func.coalesce(func.sum(Article.body_bytes), 0)).where(Article.account_id == account_id))


def store_body(db, article, body, extractor):
    size = len(body.encode("utf-8"))
    quota = db.get(Account, article.account_id).quota
    if stored_bytes(db, article.account_id) - article.body_bytes + size > quota:
        if not article.body:
            article.content_status = "quota"
    else:
        article.body, article.body_bytes = body, size
        article.extractor, article.content_status = extractor, "ready"
    changed(db, article.account_id, "article", article.id)


def clear_bodies(db, account_id, before=None):
    query = select(Article).where(Article.account_id == account_id, Article.body_bytes > 0)
    if before is not None:
        query = query.where(func.coalesce(Article.published_at, Article.created_at) < before)
    count, freed = 0, 0
    for article in db.scalars(query):
        count += 1
        freed += article.body_bytes
        article.body, article.body_bytes = None, 0
        article.extractor, article.content_status = None, "cleared"
        changed(db, account_id, "article", article.id)
    return {"article_count": count, "bytes_freed": freed}


def feed_ids(db, article_id):
    return list(db.scalars(select(FeedEntry.feed_id).join(Feed).where(
        FeedEntry.article_id == article_id, Feed.active.is_(True)
    ).distinct().order_by(FeedEntry.feed_id)))


def article_data(db, article, *, body=False):
    data = {
        "id": article.id, "url": article.url, "title": article.title, "author": article.author,
        "published_at": article.published_at, "created_at": article.created_at, "saved_at": article.saved_at,
        "read": article.read, "starred": article.starred, "location": article.location, "trash_origin": article.trash_origin,
        "tags": tags_for(db, article.id),
        "feed_ids": feed_ids(db, article.id), "excerpt": article.excerpt,
        "content_status": article.content_status, "extractor": article.extractor, "body_bytes": article.body_bytes,
    }
    if body:
        data["body_html"] = article.body
    return data


def article_query(account_id, source, location, feed_id, tag, read):
    query = select(Article).where(Article.account_id == account_id)
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
    if feed_id:
        query = query.where(exists(select(FeedEntry.feed_id).join(Feed).where(
            FeedEntry.article_id == Article.id, Feed.id == feed_id,
            Feed.account_id == account_id, Feed.active.is_(True)
        )))
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
