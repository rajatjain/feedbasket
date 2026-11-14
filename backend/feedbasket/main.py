import argparse
import asyncio
import fcntl
import logging
import secrets
from contextlib import asynccontextmanager
from pathlib import Path
from threading import Event
from uuid import uuid4

import uvicorn
from sqlalchemy import select
from alembic import command
from alembic.config import Config as AlembicConfig
from fastapi import FastAPI, Request
from fastapi.responses import RedirectResponse
from starlette.middleware.sessions import SessionMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from . import admin, api, auth, logs, scheduler
from .config import Config
from .db import Account, get_setting, make_engine, set_setting, write
from .updates import SavedUpdates

log = logging.getLogger(__name__)


def migrate(engine):
    directory = Path(__file__).resolve().parent
    migrations = directory / "migrations"
    if not (migrations / "env.py").is_file():
        migrations = directory.parent / "migrations"
    config = AlembicConfig()
    config.set_main_option("script_location", str(migrations))
    with engine.begin() as connection:
        config.attributes["connection"] = connection
        command.upgrade(config, "head")
    with write(engine) as db:
        if get_setting(db, "library_id", None) is None:
            set_setting(db, "library_id", uuid4())


def create_app(config: Config | None = None, *, start_worker=True, configure_logging=False):
    config = config or Config.load()
    config.validate()

    @asynccontextmanager
    async def lifespan(app):
        config.db_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock_path = config.db_path.with_name(config.db_path.name + ".lock")
        with lock_path.open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RuntimeError("Another FeedBasket process is using this database") from error
            if config.backup_folder_managed and not config.backup_uses_r2:
                Path(config.backup_folder).mkdir(mode=0o700, parents=True, exist_ok=True)
            if configure_logging:
                logs.configure(config.logs_path)
            engine = make_engine(config.db_path)
            stop = Event()
            task = None
            try:
                await asyncio.to_thread(migrate, engine)
                app.state.engine = engine
                app.state.saved_updates = SavedUpdates()
                log.info("Backend ready on %s:%d", config.host, config.port)
                if start_worker:
                    task = asyncio.create_task(
                        scheduler.worker_task(engine, config, stop, app.state.saved_updates.publish)
                    )
                yield
            finally:
                stop.set()
                try:
                    if task:
                        await task
                finally:
                    engine.dispose()
                    log.info("Backend stopped")

    app = FastAPI(title="FeedBasket", version="0.1.0", lifespan=lifespan)
    app.state.config = config
    app.state.google = auth.google_client(config)
    app.state.admin_sessions = admin.AdminSessions()
    app.add_middleware(SessionMiddleware, secret_key=config.session_secret or secrets.token_urlsafe(32),
                       session_cookie="feedbasket_browser", max_age=1800, https_only=config.public_url.startswith("https://"))
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=list(config.allowed_hosts), www_redirect=False)

    @app.middleware("http")
    async def response_headers(request: Request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Frame-Options"] = "DENY"
        if request.url.path.startswith(("/admin", "/auth/")):
            response.headers["Content-Security-Policy"] = (
                "default-src 'none'; style-src 'unsafe-inline'; img-src https:; "
                "form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
            )
        return response

    @app.get("/", include_in_schema=False)
    def home():
        return RedirectResponse("/admin")

    @app.get("/health")
    def health():
        return {"status": "ok", "google_configured": bool(config.google_id)}

    app.include_router(auth.router)
    app.include_router(api.router)
    app.include_router(admin.router)
    return app


def create_server_app():
    return create_app(configure_logging=True)


def run():
    parser = argparse.ArgumentParser(prog="feedbasket")
    parser.add_argument("--reload", action="store_true", help="Restart the server when Python source changes")
    commands = parser.add_subparsers(dest="command")
    account_command = commands.add_parser("account", help="Create or manage local usernames")
    account_command.add_argument("username", nargs="?", help="Username for a local account")
    account_command.add_argument("--existing-id", help="Assign the username to an existing local account UUID")
    account_command.add_argument("--list", action="store_true", help="List accounts and their internal UUIDs")
    arguments = parser.parse_args()
    if arguments.command == "account":
        if arguments.reload:
            parser.error("--reload is only available when starting the server")
        if arguments.list == (arguments.username is not None) or (arguments.list and arguments.existing_id):
            account_command.error("Provide a username, optionally with --existing-id, or use --list.")
        manage_accounts(Config.load(), arguments.username, arguments.existing_id, arguments.list)
    else:
        config = Config.load()
        if arguments.reload:
            source = Path(__file__).resolve().parent
            uvicorn.run("feedbasket.main:create_server_app", host=config.host, port=config.port,
                        factory=True, reload=True, reload_dirs=[str(source), str(source.parent / "migrations")],
                        access_log=False, timeout_graceful_shutdown=5)
        else:
            uvicorn.run(create_app(config, configure_logging=True), host=config.host, port=config.port,
                        access_log=False, log_config=None, timeout_graceful_shutdown=5)


def manage_accounts(config, username, existing_id, list_accounts):
    config.db_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = config.db_path.with_name(config.db_path.name + ".lock")
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("Stop the backend before using the account command.") from None
        engine = make_engine(config.db_path)
        try:
            migrate(engine)
            with write(engine) as db:
                if list_accounts:
                    for account in db.scalars(select(Account).order_by(Account.name, Account.id)):
                        print(f"{account.id}  {account.username or account.name or account.email}")
                    return
                if existing_id:
                    account = db.get(Account, existing_id)
                    if not account or not account.google_sub.startswith("local:"):
                        raise SystemExit("Local account not found.")
                    auth.set_username(db, account, username)
                else:
                    account = auth.create_local_account(db, config, username)
                label, account_id = account.username, account.id
        except ValueError as error:
            raise SystemExit(str(error)) from error
        finally:
            engine.dispose()
    print(f"Account: {label} ({account_id})")
