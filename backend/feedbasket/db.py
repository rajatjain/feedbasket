import os
from contextlib import contextmanager
from datetime import UTC, datetime

from sqlalchemy import BigInteger, Boolean, ForeignKey, ForeignKeyConstraint, Index, Integer, JSON, String, Text, UniqueConstraint, create_engine, event, false, select
from sqlalchemy.engine import URL
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column


def now() -> int:
    return int(datetime.now(UTC).timestamp())


class Base(DeclarativeBase):
    pass


class Account(Base):
    __tablename__ = "accounts"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    google_sub: Mapped[str] = mapped_column(String(255), unique=True)
    email: Mapped[str] = mapped_column(String(320), unique=True)
    username: Mapped[str | None] = mapped_column(String(64), index=True, unique=True)
    name: Mapped[str] = mapped_column(Text, default="")
    picture: Mapped[str] = mapped_column(Text, default="")
    quota: Mapped[int] = mapped_column(BigInteger)
    pdf_quota: Mapped[int] = mapped_column(BigInteger, server_default="5000000000")


class AllowedAccount(Base):
    __tablename__ = "allowed_accounts"
    email: Mapped[str] = mapped_column(String(320), primary_key=True)


class LoginSession(Base):
    __tablename__ = "login_sessions"
    digest: Mapped[str] = mapped_column(String(64), primary_key=True)
    account_id: Mapped[str] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"), index=True)
    expires_at: Mapped[int] = mapped_column(BigInteger, index=True)


class LoginAttempt(Base):
    __tablename__ = "login_attempts"
    digest: Mapped[str] = mapped_column(String(64), primary_key=True)
    expires_at: Mapped[int] = mapped_column(BigInteger, index=True)
    account_id: Mapped[str | None] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"))
    started: Mapped[bool] = mapped_column(Boolean, default=False)


class Article(Base):
    __tablename__ = "articles"
    __table_args__ = (
        Index("ix_articles_account_location_published", "account_id", "location", "published_at"),
        Index("ix_articles_account_pdf_import", "account_id", "pdf_import_id", unique=True),
        Index("ix_articles_account_id_document", "account_id", "id", unique=True),
    )
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    account_id: Mapped[str] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"))
    url: Mapped[str] = mapped_column(Text)
    title: Mapped[str] = mapped_column(Text)
    author: Mapped[str] = mapped_column(Text, default="")
    published_at: Mapped[int | None] = mapped_column(BigInteger)
    created_at: Mapped[int] = mapped_column(BigInteger, default=now)
    saved_at: Mapped[int | None] = mapped_column(BigInteger)
    read: Mapped[bool] = mapped_column(Boolean, default=False)
    starred: Mapped[bool] = mapped_column(Boolean, default=False, server_default=false())
    starred_at: Mapped[int] = mapped_column(BigInteger, default=0, server_default="0")
    location: Mapped[str] = mapped_column(String(16), default="inbox")
    trash_origin: Mapped[str | None] = mapped_column(String(16))
    state_at: Mapped[int] = mapped_column(BigInteger, default=0)
    read_at: Mapped[int] = mapped_column(BigInteger, default=0)
    excerpt: Mapped[str] = mapped_column(Text, default="")
    body: Mapped[str | None] = mapped_column(Text)
    body_bytes: Mapped[int] = mapped_column(BigInteger, default=0)
    word_count: Mapped[int | None] = mapped_column(Integer)
    extractor: Mapped[str | None] = mapped_column(String(32))
    content_status: Mapped[str] = mapped_column(String(24), default="pending")
    document_type: Mapped[str] = mapped_column(String(16), server_default="article")
    pdf_key: Mapped[str | None] = mapped_column(Text)
    pdf_filename: Mapped[str | None] = mapped_column(Text)
    pdf_bytes: Mapped[int] = mapped_column(BigInteger, server_default="0")
    pdf_pages: Mapped[int | None] = mapped_column(Integer)
    pdf_import_id: Mapped[str | None] = mapped_column(String(36))
    pdf_digest: Mapped[str | None] = mapped_column(String(64))
    pdf_expires_at: Mapped[int | None] = mapped_column(BigInteger)
    reading_position: Mapped[dict | None] = mapped_column(JSON(none_as_null=True))
    position_updated_at: Mapped[int] = mapped_column(BigInteger, server_default="0")
    submitted_url: Mapped[str | None] = mapped_column(Text)


class ArticleURL(Base):
    __tablename__ = "article_urls"
    account_id: Mapped[str] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True)
    url: Mapped[str] = mapped_column(Text, primary_key=True)
    article_id: Mapped[str] = mapped_column(ForeignKey("articles.id", ondelete="CASCADE"), index=True)


class ArticleTag(Base):
    __tablename__ = "article_tags"
    article_id: Mapped[str] = mapped_column(ForeignKey("articles.id", ondelete="CASCADE"), primary_key=True)
    tag: Mapped[str] = mapped_column(String(80), primary_key=True, index=True)


class Highlight(Base):
    __tablename__ = "highlights"
    __table_args__ = (
        ForeignKeyConstraint(("account_id", "article_id"), ("articles.account_id", "articles.id"), ondelete="CASCADE"),
    )
    account_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    article_id: Mapped[str] = mapped_column(String(36), index=True)
    style: Mapped[str] = mapped_column(String(16))
    quote: Mapped[str] = mapped_column(Text)
    color: Mapped[str] = mapped_column(String(16))
    anchor: Mapped[dict] = mapped_column(JSON)
    created_at: Mapped[int] = mapped_column(BigInteger, default=now)


class Feed(Base):
    __tablename__ = "feeds"
    __table_args__ = (UniqueConstraint("account_id", "url", name="uq_feed_account_url"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    account_id: Mapped[str] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"), index=True)
    url: Mapped[str] = mapped_column(Text)
    title: Mapped[str] = mapped_column(Text)
    custom_title: Mapped[str | None] = mapped_column(Text)
    kind: Mapped[str] = mapped_column(String(16), default="feed", server_default="feed")
    page_digest: Mapped[str | None] = mapped_column(String(64))
    interval_minutes: Mapped[int | None] = mapped_column(Integer)
    last_checked: Mapped[int | None] = mapped_column(BigInteger)
    next_check: Mapped[int] = mapped_column(BigInteger, default=now)
    history_end: Mapped[bool] = mapped_column(Boolean, default=False)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    error: Mapped[str | None] = mapped_column(Text)
    initial_done: Mapped[bool] = mapped_column(Boolean, default=False)
    newest_at: Mapped[int | None] = mapped_column(BigInteger)


class FeedEntry(Base):
    __tablename__ = "feed_entries"
    feed_id: Mapped[str] = mapped_column(ForeignKey("feeds.id", ondelete="CASCADE"), primary_key=True)
    key: Mapped[str] = mapped_column(Text, primary_key=True)
    article_id: Mapped[str] = mapped_column(ForeignKey("articles.id", ondelete="CASCADE"), index=True)


class Change(Base):
    __tablename__ = "changes"
    __table_args__ = (Index("ix_changes_account_id_id", "account_id", "id"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    account_id: Mapped[str] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(String(16))
    object_id: Mapped[str] = mapped_column(String(36))
    operation: Mapped[str] = mapped_column(String(16), default="upsert")
    replacement_id: Mapped[str | None] = mapped_column(String(36))


class ArticleRedirect(Base):
    __tablename__ = "article_redirects"
    account_id: Mapped[str] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True)
    old_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    article_id: Mapped[str] = mapped_column(ForeignKey("articles.id", ondelete="CASCADE"), index=True)


class Job(Base):
    __tablename__ = "jobs"
    __table_args__ = (Index("ix_jobs_status_run_at", "status", "run_at"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    kind: Mapped[str] = mapped_column(String(20))
    target: Mapped[str] = mapped_column(String(36), default="")
    account_id: Mapped[str | None] = mapped_column(String(36))
    status: Mapped[str] = mapped_column(String(16), default="queued")
    run_at: Mapped[int] = mapped_column(BigInteger, default=now)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    error: Mapped[str | None] = mapped_column(Text)
    finished_at: Mapped[int | None] = mapped_column(BigInteger)


class Setting(Base):
    __tablename__ = "settings"
    key: Mapped[str] = mapped_column(String(40), primary_key=True)
    value: Mapped[str] = mapped_column(Text)


def make_engine(path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    os.close(fd)
    engine = create_engine(URL.create("sqlite+pysqlite", database=str(path)), connect_args={"timeout": 10})

    @event.listens_for(engine, "connect")
    def configure(connection, _):
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("PRAGMA busy_timeout=10000")
        connection.execute("PRAGMA journal_mode=WAL").close()

    return engine


@contextmanager
def write(engine):
    with Session(engine) as session:
        with session.begin():
            session.connection().exec_driver_sql("BEGIN IMMEDIATE")
            yield session


def get_setting(db, key, default):
    row = db.get(Setting, key)
    return row.value if row else default


def set_setting(db, key, value):
    db.merge(Setting(key=key, value=str(value)))


def changed(db, account_id, kind, object_id, operation="upsert", replacement_id=None):
    db.add(Change(account_id=account_id, kind=kind, object_id=object_id, operation=operation, replacement_id=replacement_id))


def enqueue(db, kind, target="", run_at=None):
    with db.no_autoflush:
        for job in db.new:
            if isinstance(job, Job) and job.kind == kind and job.target == target:
                return job
    existing = db.scalar(select(Job).where(Job.kind == kind, Job.target == target, Job.status.in_(("queued", "running"))))
    if existing:
        return existing
    job = Job(kind=kind, target=target, run_at=now() if run_at is None else run_at)
    db.add(job)
    db.flush()
    return job
