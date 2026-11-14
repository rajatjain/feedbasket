"""Account-scoped highlights and shared document anchor validation."""

from sqlalchemy import select

from .db import Article, ArticleTag, Highlight, changed


class InvalidAnchor(ValueError):
    pass


class HighlightConflict(Exception):
    pass


def pdf_revision(article, page, revision):
    if article.pdf_pages is not None and page > article.pdf_pages:
        raise InvalidAnchor("That page is outside the PDF.")
    if revision and article.pdf_digest and revision != article.pdf_digest:
        raise HighlightConflict("This position belongs to a different version of the PDF.")
    return article.pdf_digest or revision


def data(highlight):
    return {key: getattr(highlight, key) for key in ("id", "article_id", "style", "quote", "color", "anchor", "created_at")}


def get(db, account_id, highlight_id):
    return db.get(Highlight, (account_id, highlight_id))


def query(account_id, article_id=None, document_type=None, tag=None, search=None):
    result = select(Highlight).join(Article).where(Highlight.account_id == account_id, Article.location != "trash")
    if article_id:
        result = result.where(Highlight.article_id == article_id)
    if document_type:
        result = result.where(Article.document_type == document_type)
    if tag:
        result = result.join(ArticleTag, ArticleTag.article_id == Article.id).where(ArticleTag.tag == tag.strip().casefold())
    if search:
        result = result.where(Highlight.quote.icontains(search, autoescape=True))
    return result.order_by(Highlight.created_at.desc(), Highlight.id)


def save(db, article, highlight_id, *, style, quote, color, anchor):
    if article.location == "trash":
        raise HighlightConflict("Restore the item before adding a highlight.")
    if article.document_type != anchor["kind"]:
        raise InvalidAnchor("The highlight location must match the document type.")
    if anchor["kind"] == "pdf":
        anchor["document_revision"] = pdf_revision(
            article, max(quad["page"] for quad in anchor["quads"]), anchor["document_revision"],
        )
    record = {"article_id": article.id, "style": style, "quote": quote, "color": color.lower(), "anchor": anchor}
    if existing := get(db, article.account_id, highlight_id):
        if any(getattr(existing, field) != value for field, value in record.items()):
            raise HighlightConflict("That highlight ID is already in use.")
        return existing, False
    highlight = Highlight(account_id=article.account_id, id=highlight_id, **record)
    db.add(highlight)
    db.flush()
    changed(db, article.account_id, "highlight", highlight.id)
    return highlight, True


def remove(db, highlight):
    changed(db, highlight.account_id, "highlight", highlight.id, "delete")
    db.delete(highlight)


def record_deletions(db, account_id, article_ids):
    for highlight_id in db.scalars(select(Highlight.id).where(
        Highlight.account_id == account_id, Highlight.article_id.in_(article_ids),
    )):
        changed(db, account_id, "highlight", highlight_id, "delete")


def move(db, old, new):
    for highlight in db.scalars(select(Highlight).where(
        Highlight.account_id == old.account_id, Highlight.article_id == old.id,
    )):
        highlight.article_id = new.id
        changed(db, old.account_id, "highlight", highlight.id)
