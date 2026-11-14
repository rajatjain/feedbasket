import logging
import os
import re
import shutil
import sqlite3
import tempfile
from contextlib import closing, contextmanager
from datetime import UTC, datetime, time, timedelta
from pathlib import Path
from time import monotonic
from uuid import uuid4
from zoneinfo import ZoneInfo

from boto3.exceptions import S3UploadFailedError
from botocore.exceptions import BotoCoreError, ClientError
from sqlalchemy import select

from . import r2
from .db import Job, enqueue, get_setting, now, set_setting, write

TIMEZONE = ZoneInfo("Asia/Kolkata")
RETENTION = 2
NEXT_AT = "backup_calendar_next_at"
SNAPSHOT = re.compile(r"feedbasket-(\d{8}T\d{6})(\d{6})?Z-[a-f0-9]{12}\.sqlite")
log = logging.getLogger(__name__)


def local_time(value):
    return datetime.fromtimestamp(value, TIMEZONE).strftime("%d %b %Y, %H:%M %Z") if value else "—"


def options(db, config):
    folder = config.backup_folder if config.backup_folder_managed else get_setting(db, "backup_folder", config.backup_folder)
    enabled = get_setting(db, "backup_frequency", config.backup_frequency) != "disabled"
    destination = (f"s3://{config.r2_bucket}/{config.backup_prefix}" if config.backup_uses_r2
                   else str(Path(folder).expanduser() / config.backup_prefix))
    return {
        "folder": folder,
        "enabled": enabled,
        "destination": destination,
        "last_at": int(get_setting(db, "backup_last_at", 0)),
        "last_path": get_setting(db, "backup_last_path", ""),
        "next_at": int(get_setting(db, NEXT_AT, 0)) if enabled else 0,
    }


def backup_target(kind, moment):
    stamp = moment.astimezone(UTC).strftime("%Y%m%dT%H%M%S%fZ")
    return f"{kind}{stamp}{uuid4().hex[:12]}"


def queue_manual(db):
    pending = db.scalar(select(Job).where(
        Job.kind == "backup", Job.status.in_(("queued", "running")),
        (Job.target == "") | Job.target.startswith("m"),
    ).limit(1))
    return pending or enqueue(db, "backup", backup_target("m", datetime.now(UTC)))


def schedule(db, config, moment):
    if get_setting(db, "backup_frequency", config.backup_frequency) == "disabled":
        return
    today = datetime.fromtimestamp(moment, TIMEZONE)
    tomorrow = int(datetime.combine(today.date() + timedelta(days=1), time(), TIMEZONE).timestamp())
    next_at = int(get_setting(db, NEXT_AT, 0))
    if not next_at:
        set_setting(db, NEXT_AT, tomorrow)
    elif next_at <= moment:
        pending = db.scalar(select(Job.id).where(
            Job.kind == "backup", Job.status.in_(("queued", "running")),
            Job.target.startswith("d") | Job.target.startswith("w"),
        ).limit(1))
        # A Sunday copy can still be retrying when the next calendar day starts.
        if pending is None:
            enqueue(db, "backup", backup_target("w" if today.weekday() == 6 else "d", today), run_at=moment)
            set_setting(db, NEXT_AT, tomorrow)


@contextmanager
def atomic_file(destination):
    folder = destination.parent
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, staging = tempfile.mkstemp(prefix=".feedbasket-", suffix=".tmp", dir=folder)
    os.close(fd)
    try:
        yield Path(staging)
        with open(staging, "rb") as file:
            os.fsync(file.fileno())
        os.replace(staging, destination)
    finally:
        Path(staging).unlink(missing_ok=True)


def snapshot(source, destination):
    with atomic_file(destination) as staging:
        with (
            closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True, timeout=10)) as origin,
            closing(sqlite3.connect(staging)) as output,
        ):
            origin.backup(output, pages=256)
            output.execute("PRAGMA journal_mode=DELETE")
            output.execute("DELETE FROM login_sessions")
            output.execute("DELETE FROM login_attempts")
            # Each restore gets a fresh sync identity, even when reusing a backup.
            output.execute("DELETE FROM settings WHERE key IN ('library_id', ?)", (NEXT_AT,))
            output.execute("DELETE FROM jobs WHERE kind = 'backup' AND status IN ('queued', 'running')")
            output.commit()
            if output.execute("PRAGMA quick_check").fetchone() != ("ok",):
                raise OSError("SQLite snapshot failed its integrity check")


class LocalStorage:
    def __init__(self, root):
        self.root = root

    def location(self, key):
        return self.root / key

    def exists(self, key):
        return self.location(key).is_file()

    def save(self, source, key):
        with atomic_file(self.location(key)) as staging:
            shutil.copyfile(source, staging)

    def copy(self, source, key):
        self.save(self.location(source), key)

    def keys(self, tier):
        return (f"{tier}/{path.name}" for path in self.location(tier).iterdir() if path.is_file())

    def delete(self, key):
        self.location(key).unlink(missing_ok=True)


class R2Storage:
    def __init__(self, config):
        self.bucket = config.r2_bucket
        self.prefix = config.backup_prefix
        self.client = r2.client(config)

    def location(self, key):
        return f"s3://{self.bucket}/{self.prefix}{key}"

    def exists(self, key):
        try:
            self.client.head_object(Bucket=self.bucket, Key=self.prefix + key)
        except ClientError as error:
            if error.response["ResponseMetadata"]["HTTPStatusCode"] == 404:
                return False
            raise
        return True

    def save(self, source, key):
        self.client.upload_file(str(source), self.bucket, self.prefix + key,
                                ExtraArgs={"ContentType": "application/vnd.sqlite3"})

    def copy(self, source, key):
        self.client.copy({"Bucket": self.bucket, "Key": self.prefix + source}, self.bucket, self.prefix + key)

    def keys(self, tier):
        pages = self.client.get_paginator("list_objects_v2").paginate(
            Bucket=self.bucket, Prefix=f"{self.prefix}{tier}/", Delimiter="/")
        for page in pages:
            for item in page.get("Contents", ()):
                yield item["Key"][len(self.prefix):]

    def delete(self, key):
        self.client.delete_object(Bucket=self.bucket, Key=self.prefix + key)


def prune(storage, tier):
    snapshots = []
    for key in storage.keys(tier):
        if match := SNAPSHOT.fullmatch(key.removeprefix(f"{tier}/")):
            snapshots.append((match[1] + (match[2] or "000000"), key))
    for _, key in sorted(snapshots, reverse=True)[RETENTION:]:
        storage.delete(key)


def snapshot_name(target):
    return f"feedbasket-{target[1:-12]}-{target[-12:]}.sqlite"


def staging_path(db_path, name):
    return db_path.with_name(f".{db_path.name}.{name}.pending")


def clean_staging(db, db_path):
    retryable = db.scalars(select(Job.target).where(
        Job.kind == "backup", Job.target.startswith("w"), Job.status.in_(("queued", "running", "failed")),
    ))
    keep = {staging_path(db_path, snapshot_name(target)).name for target in retryable}
    prefix = f".{db_path.name}."
    suffix = ".pending"
    try:
        paths = list(db_path.parent.iterdir())
    except OSError as error:
        log.warning("Could not list backup staging files (%s)", type(error).__name__)
        return
    for path in paths:
        if path.name in keep or not path.name.startswith(prefix) or not path.name.endswith(suffix):
            continue
        if SNAPSHOT.fullmatch(path.name[len(prefix):-len(suffix)]):
            try:
                path.unlink(missing_ok=True)
            except OSError as error:
                log.warning("Could not remove expired backup staging file %s (%s)", path.name, type(error).__name__)


def run_backup(engine, config, *, job_id):
    started = monotonic()
    with write(engine) as db:
        current = options(db, config)
        job = db.get(Job, job_id)
        if not job.target:
            # A manual job may have been queued before this backup policy was installed.
            job.target = backup_target("m", datetime.now(UTC))
        kind, name = job.target[0], snapshot_name(job.target)
    daily = f"daily/{name}"
    weekly = f"weekly/{name}"
    # Keep the validated Sunday file on disk until both copies are stored, even across a restart.
    staged = staging_path(config.db_path, name) if kind == "w" else None
    try:
        storage = R2Storage(config) if config.backup_uses_r2 else LocalStorage(Path(current["destination"]))
        if not storage.exists(daily):
            if staged is not None:
                if not staged.exists():
                    snapshot(config.db_path, staged)
                storage.save(staged, daily)
            else:
                with tempfile.TemporaryDirectory(prefix="feedbasket-backup-") as directory:
                    source = Path(directory) / name
                    snapshot(config.db_path, source)
                    storage.save(source, daily)
        try:
            if kind == "w":
                if not storage.exists(weekly):
                    storage.copy(daily, weekly)
                prune(storage, "weekly")
        finally:
            prune(storage, "daily")
    except (BotoCoreError, ClientError, S3UploadFailedError) as error:
        response = getattr(error, "response", {})
        code = response.get("Error", {}).get("Code", type(error).__name__)
        raise OSError(f"Cloudflare R2 backup operation failed ({code})") from error
    if staged is not None:
        staged.unlink(missing_ok=True)
    target = str(storage.location(daily))
    with write(engine) as db:
        set_setting(db, "backup_last_at", now())
        set_setting(db, "backup_last_path", target)
    log.info("Backup saved job_id=%s snapshot=%s retention=%d elapsed_ms=%d",
             job_id, name, RETENTION, (monotonic() - started) * 1000)
