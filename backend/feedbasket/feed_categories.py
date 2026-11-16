from uuid import uuid4

from sqlalchemy import func, select

from .db import Feed, FeedCategory, changed

MAX_NAME_LENGTH = 40


def list_for_account(db, account_id):
    return list(db.scalars(select(FeedCategory).where(FeedCategory.account_id == account_id)
                           .order_by(FeedCategory.position, FeedCategory.name_key, FeedCategory.id)))


def get(db, account_id, category_id):
    row = db.get(FeedCategory, category_id)
    return row if row and row.account_id == account_id else None


def data(category):
    return {"id": category.id, "name": category.name, "position": category.position}


def save(db, account_id, name, category=None):
    name = " ".join(name.split())
    key = name.casefold()
    if not name or len(name) > MAX_NAME_LENGTH or key == "uncategorized":
        raise ValueError("Use a category name of 1–40 characters other than Uncategorized.")
    existing = db.scalar(select(FeedCategory).where(
        FeedCategory.account_id == account_id, FeedCategory.name_key == key,
    ))
    if existing is not None and existing is not category:
        raise ValueError("A category with that name already exists.")
    if category is None:
        last = db.scalar(select(func.max(FeedCategory.position)).where(FeedCategory.account_id == account_id))
        category = FeedCategory(id=str(uuid4()), account_id=account_id, position=0 if last is None else last + 1)
        db.add(category)
    category.name, category.name_key = name, key
    changed(db, account_id, "feed_category", category.id)
    return category


def move(db, category, direction, anchor=None):
    ordered = list_for_account(db, category.account_id)
    if anchor is category:
        return False
    if anchor is None:
        target = ordered.index(category) + (-1 if direction == "up" else 1)
        if not 0 <= target < len(ordered):
            return False
        anchor = ordered[target]

    positions = [item.position for item in ordered]
    ordered.remove(category)
    target = ordered.index(anchor) + (1 if direction == "down" else 0)
    ordered.insert(target, category)
    moved = False
    for item, position in zip(ordered, positions, strict=True):
        if item.position != position:
            item.position = position
            changed(db, category.account_id, "feed_category", item.id)
            moved = True
    return moved


def assign(db, feed, category_id):
    if feed.category_id != category_id:
        feed.category_id = category_id
        changed(db, feed.account_id, "feed", feed.id)


def remove(db, category):
    for feed in db.scalars(select(Feed).where(Feed.category_id == category.id, Feed.account_id == category.account_id)):
        assign(db, feed, None)
    changed(db, category.account_id, "feed_category", category.id, "delete")
    db.delete(category)
