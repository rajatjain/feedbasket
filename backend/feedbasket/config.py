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
    session_secret: str = ""
    feed_interval: int = 30
    quota: int = 1_000_000_000
    r2_endpoint_url: str = ""
    r2_bucket: str = ""
    r2_access_key_id: str = field(default="", repr=False)
    r2_secret_access_key: str = field(default="", repr=False)
    pdf_prefix: str = "pdfs/"
    backup_prefix: str = "backups/"
    backup_destination: str = ""
    backup_folder: str = "~/Library/Application Support/FeedBasket/Backups"
    backup_folder_managed: bool = False
    backup_frequency: str = "daily"
    log_dir: Path | None = None

    @property
    def logs_path(self):
        return self.log_dir if self.log_dir is not None else self.db_path.parent / "logs"

    @property
    def admin_configured(self):
        return bool(self.admin_username and self.admin_password)

    @property
    def r2_configured(self):
        return bool(self.r2_endpoint_url and self.r2_bucket and self.r2_access_key_id and self.r2_secret_access_key)

    @property
    def backup_uses_r2(self):
        return self.backup_destination == "r2" or (not self.backup_destination and self.r2_configured)

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
            session_secret=os.getenv("FEEDBASKET_SESSION_SECRET", ""),
            feed_interval=int(defaults.get("feed_interval_minutes", cls.feed_interval)),
            quota=int(defaults.get("quota_bytes", cls.quota)),
            r2_endpoint_url=os.getenv("R2_ENDPOINT_URL", "").strip().rstrip("/"),
            r2_bucket=os.getenv("R2_BUCKET", "").strip(),
            r2_access_key_id=os.getenv("R2_ACCESS_KEY_ID", ""),
            r2_secret_access_key=os.getenv("R2_SECRET_ACCESS_KEY", ""),
            pdf_prefix=(os.getenv("PDF_PREFIX", "").strip() or cls.pdf_prefix).rstrip("/") + "/",
            backup_prefix=(os.getenv("BACKUP_PREFIX", "").strip() or cls.backup_prefix).rstrip("/") + "/",
            backup_destination=os.getenv("BACKUP_DESTINATION", "").strip().lower(),
            backup_folder=str(backup_path if backup_dir else backup_path.resolve()),
            backup_folder_managed=bool(backup_dir),
            backup_frequency=defaults.get("backup_frequency", cls.backup_frequency),
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
        if self.google_id and (not self.google_secret or len(self.session_secret) < 32):
            raise ValueError("Google sign-in requires a client secret and a session secret of at least 32 characters")
        if not 5 <= self.feed_interval <= 10_080 or not 0 <= self.quota <= 10**12:
            raise ValueError("Invalid feed interval or article quota")
        values = (self.r2_endpoint_url, self.r2_bucket, self.r2_access_key_id, self.r2_secret_access_key)
        if any(values):
            if not self.r2_configured:
                raise ValueError("Set all four R2 connection fields to use Cloudflare R2")
            endpoint = urlsplit(self.r2_endpoint_url)
            if (not endpoint.hostname or endpoint.username is not None or endpoint.query or endpoint.fragment
                or endpoint.path.rstrip("/") not in {"", "/" + self.r2_bucket}
                or (endpoint.scheme != "https" and not (
                    endpoint.scheme == "http" and endpoint.hostname in {"127.0.0.1", "localhost", "::1"}
                ))):
                raise ValueError("R2_ENDPOINT_URL must be the HTTPS S3 endpoint")
        if (not self.pdf_prefix.endswith("/") or len(self.pdf_prefix.encode()) > 512
            or any(part in {"", ".", ".."} for part in self.pdf_prefix[:-1].split("/"))
            or any(ord(char) < 32 or char == "\\" for char in self.pdf_prefix)):
            raise ValueError("PDF_PREFIX must be a nonempty object prefix ending in /")
        if (not self.backup_prefix.endswith("/") or len(self.backup_prefix.encode()) > 512
            or any(part in {"", ".", ".."} for part in self.backup_prefix[:-1].split("/"))
            or any(ord(char) < 32 or char == "\\" for char in self.backup_prefix)):
            raise ValueError("BACKUP_PREFIX must be a relative folder or object prefix")
        if self.backup_destination not in {"", "r2", "local"}:
            raise ValueError("BACKUP_DESTINATION must be r2, local, or empty")
        if self.backup_uses_r2 and not self.r2_configured:
            raise ValueError("R2 backups require all four R2 connection fields")
        if self.backup_frequency not in {"daily", "weekly", "disabled"}:
            raise ValueError("Invalid backup frequency")
