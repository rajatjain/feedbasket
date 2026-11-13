import logging
from logging.handlers import RotatingFileHandler
from urllib.parse import urlsplit


def publisher_url(url):
    try:
        parts = urlsplit(url)
    except ValueError:
        return "<invalid publisher URL>"
    return parts._replace(netloc=parts.netloc.rsplit("@", 1)[-1], query="", fragment="").geturl()


def configure(directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    formatter = logging.Formatter(
        "%(asctime)s %(levelname)s %(filename)s:%(lineno)d] %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
    )
    file = RotatingFileHandler(
        directory / "feedbasket.log", maxBytes=5 * 1024 * 1024, backupCount=3, encoding="utf-8"
    )
    console = logging.StreamHandler()
    for handler in (file, console):
        handler.setFormatter(formatter)
    logging.basicConfig(level=logging.INFO, handlers=[file, console], force=True)
