import hashlib
import re
import secrets
from uuid import uuid4

from authlib.integrations.base_client import OAuthError
from authlib.integrations.starlette_client import OAuth
from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel, Field
from sqlalchemy import delete, select
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from .db import Account, AllowedAccount, LoginAttempt, LoginSession, now, write

router = APIRouter()
SESSION_TTL = 30 * 86400
LOCAL_SESSION_EXPIRY = 253402300799
ATTEMPT_TTL = 600


def google_client(config):
    if not config.google_id:
        return None
    oauth = OAuth()
    return oauth.register(
        "google", client_id=config.google_id, client_secret=config.google_secret,
        server_metadata_url="https://accounts.google.com/.well-known/openid-configuration",
        client_kwargs={"scope": "openid email profile", "code_challenge_method": "S256"},
    )


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def cookie_security(request):
    return request.app.state.config.public_url.startswith("https://")


def profile(account):
    return {"id": account.id, "email": "" if account.google_sub.startswith("local:") else account.email, "name": account.name,
            "picture": account.picture, "username": account.username, "admin": account.admin}


def normalized_username(value):
    username = value.strip().lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{0,63}", username):
        raise ValueError("Use 1–64 letters, numbers, dots, hyphens or underscores. Start with a letter or number.")
    return username


def set_username(db, account, value):
    username = normalized_username(value)
    existing = db.scalar(select(Account).where(Account.username == username))
    if existing and existing.id != account.id:
        raise ValueError("That username is already taken.")
    account.username = username


def create_local_account(db, config, username, *, admin=False):
    account_id = str(uuid4())
    account = Account(id=account_id, google_sub="local:" + account_id,
                      email=account_id + "@local.invalid", admin=admin, quota=config.quota)
    set_username(db, account, username)
    account.name = account.username
    db.add(account)
    db.flush()
    return account


def allowed(db, account):
    return account.admin or account.google_sub.startswith("local:") or db.get(AllowedAccount, account.email) is not None


class UsernameLogin(BaseModel):
    username: str = Field(min_length=1, max_length=200)
    temporary_session: bool = False


def local_session(db, account, *, temporary=False):
    token = issue_session(db, account.id, expires_at=None if temporary else LOCAL_SESSION_EXPIRY)
    return {"token": token, "profile": profile(account)}


@router.post("/api/v1/auth/signup", status_code=201)
def signup(request: Request, body: UsernameLogin):
    with write(request.app.state.engine) as db:
        try:
            username = normalized_username(body.username)
        except ValueError as error:
            raise HTTPException(422, str(error)) from error
        if db.scalar(select(Account.id).where(Account.username == username)):
            raise HTTPException(409, "That username is already taken. Choose Sign in to use it.")
        return local_session(db, create_local_account(db, request.app.state.config, username), temporary=body.temporary_session)


@router.post("/api/v1/auth/connect")
def connect(request: Request, body: UsernameLogin):
    try:
        username = normalized_username(body.username)
    except ValueError as error:
        raise HTTPException(422, str(error)) from error
    with write(request.app.state.engine) as db:
        account = db.scalar(select(Account).where(Account.username == username))
        if not account:
            raise HTTPException(401, "Username not found. Choose Create account to get started.")
        return local_session(db, account, temporary=body.temporary_session)


def sign_in(db, config, claims):
    if not claims or not claims.get("sub") or claims.get("email_verified") is not True or not claims.get("email"):
        raise HTTPException(403, "Google account must have a verified email")
    email = claims["email"].strip().lower()
    if not email.endswith(("@gmail.com", "@googlemail.com")) and not claims.get("hd"):
        raise HTTPException(403, "Sign in with a Gmail or Google Workspace account")
    subject = claims["sub"]
    account = db.scalar(select(Account).where(Account.google_sub == subject))
    first = db.scalar(select(Account.id).limit(1)) is None
    if first and email != config.admin_email:
        raise HTTPException(403, "Use the Google account configured for initial setup")
    if not first and not (account and account.admin) and db.get(AllowedAccount, email) is None:
        raise HTTPException(403, "This Google account has not been allowed by the administrator")
    existing_email = db.scalar(select(Account).where(Account.email == email))
    if existing_email and existing_email.google_sub != subject:
        raise HTTPException(403, "This email is already associated with another account")
    if not account:
        account = Account(id=str(uuid4()), google_sub=subject, email=email, admin=first, quota=config.quota)
        db.add(account)
    account.email = email
    account.name = str(claims.get("name", ""))[:200]
    picture = str(claims.get("picture", ""))
    account.picture = picture[:2000] if picture.startswith("https://") else ""
    db.flush()
    return account


def issue_session(db, account_id, *, expires_at=None):
    token = secrets.token_urlsafe(32)
    db.add(LoginSession(digest=digest(token), account_id=account_id, expires_at=expires_at if expires_at is not None else now() + SESSION_TTL))
    return token


def token_for_request(request):
    scheme, _, value = request.headers.get("Authorization", "").partition(" ")
    return value if scheme.lower() == "bearer" else ""


def current_account(request: Request):
    token = token_for_request(request)
    if token:
        with Session(request.app.state.engine) as db:
            session = db.get(LoginSession, digest(token))
            if session and session.expires_at > now():
                account = db.get(Account, session.account_id)
                if account and allowed(db, account):
                    return account
    raise HTTPException(401, "Connect your FeedBasket account")


def google(request):
    client = request.app.state.google
    if not client:
        raise HTTPException(503, "Configure Google sign-in in feedbasket.toml and the environment")
    return client


def claim_attempt(request, attempt):
    with write(request.app.state.engine) as db:
        row = db.get(LoginAttempt, attempt)
        if not row or row.expires_at <= now() or row.started:
            raise HTTPException(400, "Sign-in request expired")
        row.started = True


@router.get("/auth/google/start")
async def start_google(request: Request, attempt: str | None = Query(default=None, max_length=100)):
    client = google(request)
    if not attempt or not 32 <= len(attempt) <= 100:
        raise HTTPException(400, "Start Google sign-in from the reader app")
    await run_in_threadpool(claim_attempt, request, attempt)
    request.session.clear()
    request.session["attempt"] = attempt
    uri = request.app.state.config.public_url + "/auth/google/callback"
    return await client.authorize_redirect(request, uri, prompt="select_account")


def finish_google(request, claims, attempt):
    with write(request.app.state.engine) as db:
        row = db.get(LoginAttempt, attempt)
        if not row or row.expires_at <= now() or row.account_id:
            raise HTTPException(400, "Sign-in request expired")
        account = sign_in(db, request.app.state.config, claims)
        row.account_id = account.id


@router.get("/auth/google/callback")
async def callback(request: Request):
    client = google(request)
    try:
        token = await client.authorize_access_token(request)
    except (OAuthError, ValueError) as error:
        raise HTTPException(400, "Google sign-in could not be verified") from error
    attempt = request.session.pop("attempt", None)
    request.session.clear()
    if not attempt:
        raise HTTPException(400, "Sign-in request expired")
    await run_in_threadpool(finish_google, request, token.get("userinfo"), attempt)
    return RedirectResponse("/auth/done", status_code=303)


@router.get("/auth/done")
def done():
    return HTMLResponse("<!doctype html><html lang=en><title>FeedBasket</title>"
                        "<h1>Signed in to FeedBasket</h1><p>You can return to the app.</p></html>")


class LoginPoll(BaseModel):
    secret: str = Field(min_length=32, max_length=100)


@router.post("/api/v1/auth/start", status_code=201)
def start_app_login(request: Request):
    google(request)
    secret = secrets.token_urlsafe(32)
    key = digest(secret)
    with write(request.app.state.engine) as db:
        db.execute(delete(LoginAttempt).where(LoginAttempt.expires_at <= now()))
        db.add(LoginAttempt(digest=key, expires_at=now() + ATTEMPT_TTL))
    return {"secret": secret, "authorization_url": request.app.state.config.public_url
            + "/auth/google/start?attempt=" + key, "expires_in": ATTEMPT_TTL, "poll_interval": 2}


@router.post("/api/v1/auth/poll")
def poll(request: Request, body: LoginPoll):
    with write(request.app.state.engine) as db:
        row = db.get(LoginAttempt, digest(body.secret))
        if not row or row.expires_at <= now():
            raise HTTPException(410, "Sign-in request expired")
        if not row.account_id:
            return {"status": "pending"}
        account = db.get(Account, row.account_id)
        if not account or not allowed(db, account):
            raise HTTPException(403, "Account access revoked")
        db.delete(row)
        return {"status": "complete", "token": issue_session(db, account.id), "profile": profile(account), "expires_in": SESSION_TTL}


def revoke(request):
    token = token_for_request(request)
    if token:
        with write(request.app.state.engine) as db:
            db.execute(delete(LoginSession).where(LoginSession.digest == digest(token)))
