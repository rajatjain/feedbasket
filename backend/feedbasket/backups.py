import logging
import os
import re
import sqlite3
import tempfile
from contextlib import closing
from datetime import UTC, datetime
from pathlib import Path
from time import monotonic
from uuid import uuid4

from .db import get_setting, now, set_setting, write

INTERVALS = {"daily": 86400, "weekly": 7 * 86400}
SNAPSHOT = re.compile(r"feedbasket-\d{8}T\d{6}Z-[a-f0-9]{12}\.sqlite")
log = logging.getLogger(__name__)


def options(db, config):
    return {
        "folder": config.backup_folder if config.backup_folder_managed else get_setting(db, "backup_folder", config.backup_folder),
        "frequency": get_setting(db, "backup_frequency", config.backup_frequency),
        "retention": int(get_setting(db, "backup_retention", config.backup_retention)),
        "last_at": int(get_setting(db, "backup_last_at", 0)),
        "last_path": get_setting(db, "backup_last_path", ""),
        "next_at": int(get_setting(db, "backup_next_at", 0)),
    }


def snapshot(source: Path, folder: Path, retention: int):
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    destination = folder / f"feedbasket-{timestamp}-{uuid4().hex[:12]}.sqlite"
    fd, staging = tempfile.mkstemp(prefix=".feedbasket-", suffix=".tmp", dir=folder)
    os.close(fd)
    try:
        with (
            closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True, timeout=10)) as origin,
            closing(sqlite3.connect(staging)) as output,
        ):
            origin.backup(output, pages=256)
            output.execute("PRAGMA journal_mode=DELETE")
            # A restored library should require fresh sign-in.
            output.execute("DELETE FROM login_sessions")
            output.execute("DELETE FROM login_attempts")
            output.commit()
            if output.execute("PRAGMA quick_check").fetchone() != ("ok",):
                raise OSError("SQLite snapshot failed its integrity check")
        with open(staging, "rb") as file:
            os.fsync(file.fileno())
        os.replace(staging, destination)
    finally:
        Path(staging).unlink(missing_ok=True)

    others = sorted((item for item in folder.iterdir()
                     if item != destination and SNAPSHOT.fullmatch(item.name) and item.is_file()),
                    key=lambda item: item.name, reverse=True)
    for obsolete in others[retention - 1:]:
        obsolete.unlink(missing_ok=True)
    return destination


def run_backup(engine, config, *, job_id=None):
    started = monotonic()
    with write(engine) as db:
        current = options(db, config)
    folder = Path(current["folder"]).expanduser()
    target = snapshot(config.db_path, folder, current["retention"])
    with write(engine) as db:
        interval = INTERVALS.get(options(db, config)["frequency"], 0)
        set_setting(db, "backup_last_at", now())
        set_setting(db, "backup_last_path", str(target))
        set_setting(db, "backup_next_at", now() + interval if interval else 0)
    log.info("Backup saved job_id=%s snapshot=%s retention=%d elapsed_ms=%d",
             job_id, target.name, current["retention"], (monotonic() - started) * 1000)
