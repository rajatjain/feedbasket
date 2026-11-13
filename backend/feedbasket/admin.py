import logging
import secrets
from datetime import UTC, datetime
from pathlib import Path
from threading import Lock
from time import monotonic
from typing import Annotated, Literal
from urllib.parse import urlencode

from fastapi import APIRouter, Depends, Form, HTTPException, Request
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from . import auth, backups
from .db import Account, AllowedAccount, Feed, Job, LoginAttempt, LoginSession, changed, enqueue, get_setting, now, set_setting, write

router = APIRouter(prefix="/admin", include_in_schema=False)
log = logging.getLogger(__name__)
templates = Jinja2Templates(directory=str(Path(__file__).with_name("templates")))
ADMIN_COOKIE = "feedbasket_admin"
ADMIN_TTL = 1800


class AdminSessions:
    def __init__(self):
        self.sessions: dict[str, float] = {}
        self.lock = Lock()

    def issue(self, previous: str):
        token = secrets.token_urlsafe(32)
        now = monotonic()
        with self.lock:
            self.sessions = {key: expires for key, expires in self.sessions.items()
                             if expires > now and key != previous}
            self.sessions[token] = now + ADMIN_TTL
        return token

    def active(self, token: str):
        with self.lock:
            return self.sessions.get(token, 0) > monotonic()

    def revoke(self, token: str):
        with self.lock:
            self.sessions.pop(token, None)


def signed_in(request: Request):
    return (request.app.state.config.admin_configured
            and request.app.state.admin_sessions.active(request.cookies.get(ADMIN_COOKIE, "")))


def require_admin(request: Request):
    if not signed_in(request):
        raise HTTPException(403, "Sign in to Admin")


Admin = Annotated[None, Depends(require_admin)]


def local_time(value):
    return datetime.fromtimestamp(value, UTC).astimezone().strftime("%d %b %Y, %H:%M %Z") if value else "—"


templates.env.filters["local_time"] = local_time


def redirect(message):
    return RedirectResponse("/admin?" + urlencode({"message": message}), status_code=303)


def csrf(request, value):
    expected = request.session.get("csrf")
    if not expected or not secrets.compare_digest(expected.encode(), value.encode()):
        raise HTTPException(403, "Refresh the admin page and try again")


@router.get("")
def dashboard(request: Request, message: str = ""):
    config = request.app.state.config
    token = request.session.setdefault("csrf", secrets.token_urlsafe(24))
    if not signed_in(request):
        return templates.TemplateResponse(request, "admin.html", {
            "admin_configured": config.admin_configured,
            "csrf": token, "message": message[:240],
        })
    with Session(request.app.state.engine) as db:
        backup = backups.options(db, config)
        jobs = list(db.scalars(select(Job).where(
            (Job.status != "done") | (Job.kind == "backup")
        ).order_by(Job.id.desc()).limit(30)))
        feeds = list(db.scalars(select(Feed).where(Feed.active.is_(True)).order_by(Feed.title)))
        allowed = list(db.scalars(select(AllowedAccount.email).order_by(AllowedAccount.email)))
        accounts = list(db.scalars(select(Account).order_by(Account.name, Account.id)))
        feed_interval = int(get_setting(db, "feed_interval", config.feed_interval))
    wal = config.db_path.with_name(config.db_path.name + "-wal")
    database_bytes = 0
    for path in (config.db_path, wal):
        try:
            database_bytes += path.stat().st_size
        except FileNotFoundError:
            pass
    return templates.TemplateResponse(request, "admin.html", {
        "admin_username": config.admin_username, "csrf": token, "backup": backup, "database": config.db_path,
        "backup_folder_managed": config.backup_folder_managed,
        "database_mb": round(database_bytes / 1_000_000, 2),
        "jobs": jobs, "feeds": feeds, "allowed": allowed, "accounts": accounts, "configured": bool(config.google_id),
        "feed_interval": feed_interval, "message": message[:240],
    })


@router.post("/login")
def login(request: Request, token: Annotated[str, Form()], username: Annotated[str, Form()] = "",
          password: Annotated[str, Form()] = ""):
    csrf(request, token)
    config = request.app.state.config
    if not config.admin_configured:
        raise HTTPException(503, "Set the Admin username and password in the backend environment")
    username_matches = secrets.compare_digest(username.encode(), config.admin_username.encode())
    password_matches = secrets.compare_digest(password.encode(), config.admin_password.encode())
    if not (username_matches and password_matches):
        return redirect("Invalid username or password.")
    session = request.app.state.admin_sessions.issue(request.cookies.get(ADMIN_COOKIE, ""))
    request.session["csrf"] = secrets.token_urlsafe(24)
    response = redirect("Signed in.")
    response.set_cookie(ADMIN_COOKIE, session, max_age=ADMIN_TTL, path="/admin", httponly=True,
                        samesite="strict", secure=auth.cookie_security(request))
    return response


@router.post("/accounts")
def create_account(request: Request, admin: Admin, token: Annotated[str, Form()],
                   username: Annotated[str, Form(max_length=200)]):
    csrf(request, token)
    with write(request.app.state.engine) as db:
        try:
            account = auth.create_local_account(db, request.app.state.config, username)
        except ValueError as error:
            return redirect(str(error))
        label = account.username
    return redirect(f"Created account {label}.")


@router.post("/backup/settings")
def backup_settings(
    request: Request, admin: Admin, token: Annotated[str, Form()],
    frequency: Annotated[Literal["daily", "weekly", "disabled"], Form()],
    retention: Annotated[int, Form(ge=1, le=365)],
    folder: Annotated[str, Form(max_length=4096)] = "",
):
    csrf(request, token)
    config = request.app.state.config
    target = Path(config.backup_folder)
    if not config.backup_folder_managed:
        try:
            target = Path(folder.strip()).expanduser()
            if not target.is_absolute():
                raise ValueError("Use an absolute folder path")
            target = target.resolve()
            if target.exists() and not target.is_dir():
                raise ValueError("Backup destination must be a folder")
        except (OSError, RuntimeError, ValueError) as error:
            return redirect(str(error))
    with write(request.app.state.engine) as db:
        previous = backups.options(db, config)
        if not config.backup_folder_managed:
            set_setting(db, "backup_folder", target)
        set_setting(db, "backup_frequency", frequency)
        set_setting(db, "backup_retention", retention)
        if previous["frequency"] != frequency or previous["folder"] != str(target):
            next_at = now() + backups.INTERVALS[frequency] if frequency in backups.INTERVALS else 0
            set_setting(db, "backup_next_at", next_at)
    log.info("Backup settings saved frequency=%s retention=%d destination_changed=%s",
             frequency, retention, previous["folder"] != str(target))
    return redirect("Backup settings saved")


@router.post("/backup/run")
def backup_now(request: Request, admin: Admin, token: Annotated[str, Form()]):
    csrf(request, token)
    with write(request.app.state.engine) as db:
        job_id = enqueue(db, "backup").id
    log.info("Manual backup requested job_id=%s", job_id)
    return redirect("Backup queued")


@router.post("/feeds/settings")
def feed_settings(
    request: Request, admin: Admin, token: Annotated[str, Form()],
    interval: Annotated[int, Form(ge=5, le=10080)],
):
    csrf(request, token)
    with write(request.app.state.engine) as db:
        set_setting(db, "feed_interval", interval)
        for feed in db.scalars(select(Feed).where(Feed.active.is_(True), Feed.interval_minutes.is_(None))):
            feed.next_check = (feed.last_checked + interval * 60) if feed.last_checked else now()
            changed(db, feed.account_id, "feed", feed.id)
    log.info("Default feed schedule saved interval_minutes=%d", interval)
    return redirect("Default refresh interval saved")


@router.post("/feeds/refresh")
def refresh_all(request: Request, admin: Admin, token: Annotated[str, Form()]):
    csrf(request, token)
    with write(request.app.state.engine) as db:
        for feed in db.scalars(select(Feed).where(Feed.active.is_(True))):
            enqueue(db, "refresh", feed.id)
    return redirect("Feed refresh queued")


@router.post("/jobs/{job_id}/retry")
def retry(request: Request, job_id: int, admin: Admin, token: Annotated[str, Form()]):
    csrf(request, token)
    with write(request.app.state.engine) as db:
        job = db.get(Job, job_id)
        if not job or job.status != "failed":
            raise HTTPException(404, "Failed job not found")
        queued = enqueue(db, job.kind, job.target)
        if queued.status == "queued":
            queued.run_at = now()
        # Retain the failed attempt without continuing to offer duplicate retries.
        job.status = "retried"
    return redirect("Retry queued")


@router.post("/access")
def access(
    request: Request, admin: Admin, token: Annotated[str, Form()],
    email: Annotated[str, Form(min_length=3, max_length=320)],
    action: Annotated[Literal["allow", "remove"], Form()],
):
    csrf(request, token)
    email = email.strip().lower()
    if email.count("@") != 1 or not all(email.split("@")) or any(char.isspace() for char in email):
        return redirect("Enter a valid Google account email")
    with write(request.app.state.engine) as db:
        if action == "allow":
            db.merge(AllowedAccount(email=email))
        else:
            db.execute(delete(AllowedAccount).where(AllowedAccount.email == email))
            account = db.scalar(select(Account).where(Account.email == email, Account.admin.is_(False)))
            if account:
                db.execute(delete(LoginSession).where(LoginSession.account_id == account.id))
                db.execute(delete(LoginAttempt).where(LoginAttempt.account_id == account.id))
    return redirect("Allowed accounts updated")


@router.post("/logout")
def logout(request: Request, admin: Admin, token: Annotated[str, Form()]):
    csrf(request, token)
    request.app.state.admin_sessions.revoke(request.cookies.get(ADMIN_COOKIE, ""))
    request.session.pop("csrf", None)
    response = RedirectResponse("/admin", status_code=303)
    response.delete_cookie(ADMIN_COOKIE, path="/admin", secure=auth.cookie_security(request),
                           httponly=True, samesite="strict")
    return response
