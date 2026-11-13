import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit


@dataclass(frozen=True)
class Config:
    host: str = "127.0.0.1"
    port: int = 8787
    public_url: str = "http://127.0.0.1:8787"
    allowed_hosts: tuple[str, ...] = ("127.0.0.1", "localhost")
    db_path: Path = Path.home() / "Library/Application Support/FeedBasket/feedbasket.sqlite"
    google_id: str = ""
    google_secret: str = ""
    admin_username: str = "admin"
    admin_password: str = field(default="", repr=False)
    admin_email: str = ""
    session_secret: str = ""
    feed_interval: int = 30
    quota: int = 1_000_000_000
    backup_folder: str = "~/Library/Application Support/FeedBasket/Backups"
    backup_folder_managed: bool = False
    backup_frequency: str = "daily"
    backup_retention: int = 7
    log_dir: Path | None = None

    @property
    def logs_path(self):
        return self.log_dir if self.log_dir is not None else self.db_path.parent / "logs"

    @property
    def admin_configured(self):
        return bool(self.admin_username and self.admin_password)

    @classmethod
    def load(cls):
        explicit_path = os.getenv("FEEDBASKET_CONFIG")
        path = Path(explicit_path or "feedbasket.toml").expanduser().resolve()
        if path.exists() or explicit_path:
            with path.open("rb") as file:
                data = tomllib.load(file)
        else:
            data = {}
        server = data.get("server", {})
        database = data.get("database", {})
        google = data.get("google", {})
        defaults = data.get("defaults", {})
        db_dir = os.getenv("DB_DIR")
        db_path = Path(db_dir) / "feedbasket.sqlite" if db_dir else Path(database.get("path", cls.db_path))
        log_dir = os.getenv("LOGS_DIR") or os.getenv("FEEDBASKET_LOG_DIR") or data.get("logging", {}).get("directory")
        backup_dir = os.getenv("BACKUP_DIR")
        backup_folder = backup_dir or defaults.get("backup_folder", cls.backup_folder)
        backup_path = path.parent / Path(backup_folder).expanduser()
        config = cls(
            host=server.get("host", cls.host),
            port=server.get("port", cls.port),
            public_url=server.get("public_url", cls.public_url).rstrip("/"),
            allowed_hosts=tuple(server.get("allowed_hosts", cls.allowed_hosts)),
            db_path=(path.parent / db_path.expanduser()).resolve(),
            google_id=os.getenv("FEEDBASKET_GOOGLE_CLIENT_ID", google.get("client_id", "")).strip(),
            google_secret=os.getenv("FEEDBASKET_GOOGLE_CLIENT_SECRET", ""),
            admin_username=os.getenv("ADMIN_USER", os.getenv("FEEDBASKET_ADMIN_USERNAME", cls.admin_username)),
            admin_password=os.getenv("ADMIN_PASSWORD", os.getenv("FEEDBASKET_ADMIN_PASSWORD", "")),
            admin_email=os.getenv("FEEDBASKET_ADMIN_EMAIL", google.get("admin_email", "")).strip().lower(),
            session_secret=os.getenv("FEEDBASKET_SESSION_SECRET", ""),
            feed_interval=int(defaults.get("feed_interval_minutes", cls.feed_interval)),
            quota=int(defaults.get("quota_bytes", cls.quota)),
            backup_folder=str(backup_path if backup_dir else backup_path.resolve()),
            backup_folder_managed=bool(backup_dir),
            backup_frequency=defaults.get("backup_frequency", cls.backup_frequency),
            backup_retention=int(defaults.get("backup_retention", cls.backup_retention)),
            log_dir=(path.parent / Path(log_dir).expanduser()).resolve() if log_dir else None,
        )
        config.validate()
        return config

    def validate(self):
        public = urlsplit(self.public_url)
        if (
            public.scheme not in {"http", "https"} or not public.hostname
            or public.path or public.query or public.fragment or public.username
        ):
            raise ValueError("server.public_url must be an HTTP(S) origin")
        if public.scheme == "http" and public.hostname not in {"127.0.0.1", "localhost", "::1"}:
            raise ValueError("Use HTTPS for a non-loopback server.public_url")
        if self.google_id and (not self.google_secret or not self.admin_email or len(self.session_secret) < 32):
            raise ValueError("Google sign-in requires a client secret, admin email, and session secret of at least 32 characters")
        if not 5 <= self.feed_interval <= 10_080 or not 0 <= self.quota <= 10**12:
            raise ValueError("Invalid feed interval or article quota")
        if self.backup_frequency not in {"daily", "weekly", "disabled"} or not 1 <= self.backup_retention <= 365:
            raise ValueError("Invalid backup frequency or retention")
