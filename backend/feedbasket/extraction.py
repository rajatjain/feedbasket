import http.client
import ipaddress
import os
import re
import shutil
import socket
import subprocess
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote, unquote, unquote_plus, urljoin, urlsplit, urlunsplit

import nh3
import trafilatura
from lxml import etree, html

TRACKERS = {"fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid"}
MAX_RESPONSE = 5_000_000
ARTICLE_TAGS = {
    "article", "section", "div", "span", "p", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6",
    "strong", "em", "b", "i", "s", "u", "sup", "sub", "a", "ul", "ol", "li", "dl", "dt",
    "dd", "blockquote", "pre", "code", "table", "thead", "tbody", "tr", "th", "td", "figure",
    "figcaption", "img", "time",
}


class FetchError(Exception):
    pass


class PublisherHTTPError(FetchError):
    def __init__(self, status):
        self.status = status
        super().__init__(f"Publisher returned HTTP {status}")


class PDFUnsupported(FetchError):
    def __init__(self):
        super().__init__("The publisher returned a PDF.")


def normalize_url(value, *, keep_query=False):
    value = value.strip()
    if len(value) > 4000 or re.search(r"[\x00-\x20\x7f\\]", value):
        raise ValueError("Invalid URL")
    try:
        parts = urlsplit(value)
        if parts.scheme not in ("http", "https") or not parts.hostname or parts.username is not None:
            raise ValueError
        hostname = parts.hostname.encode("idna").decode("ascii").lower().rstrip(".")
        if not hostname or "%" in hostname:
            raise ValueError
        port = parts.port
        if port == 0:
            raise ValueError
        netloc = f"[{hostname}]" if ":" in hostname else hostname
        if port and port != {"http": 80, "https": 443}[parts.scheme]:
            netloc += f":{port}"
    except (ValueError, UnicodeError) as error:
        raise ValueError("Enter a valid HTTP or HTTPS URL without credentials") from error

    def keep(field):
        key = unquote_plus(field.partition("=")[0]).lower()
        return not key.startswith("utm_") and key not in TRACKERS

    query = parts.query if keep_query else "&".join(field for field in parts.query.split("&") if keep(field))
    return urlunsplit((
        parts.scheme, netloc, quote(parts.path or "/", safe="/%:@!$&'()*+,;="),
        quote(query, safe="%/:@!$&'()*+,;=?[]"), "",
    ))


def public_address(host, port):
    addresses = list(dict.fromkeys(record[4][0] for record in socket.getaddrinfo(
        host, port, type=socket.SOCK_STREAM
    )))
    for address in addresses:
        ip = ipaddress.ip_address(address)
        if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
            ip = ip.ipv4_mapped
        if not ip.is_global or ip.is_multicast:
            raise FetchError("Only public publisher URLs are supported")
    if not addresses:
        raise FetchError("Publisher hostname could not be resolved")
    return addresses[0]


@dataclass
class Document:
    url: str
    data: bytes
    media_type: str
    link_header: str = ""


def pdf_url(url):
    return unquote(urlsplit(url).path).lower().endswith(".pdf")


def fetch(url, *, resolve_address=public_address, preview=False):
    current = normalize_url(url, keep_query=preview)
    try:
        for _ in range(6):
            parts = urlsplit(current)
            port = parts.port or (443 if parts.scheme == "https" else 80)
            address = resolve_address(parts.hostname, port)
            connection_type = http.client.HTTPSConnection if parts.scheme == "https" else http.client.HTTPConnection
            connection = connection_type(parts.hostname, port, timeout=10)
            # Keep the publisher hostname for Host and TLS while connecting to the checked address.
            connection._create_connection = lambda _, timeout, source: socket.create_connection(
                (address, port), timeout, source
            )
            try:
                resource = urlunsplit(("", "", parts.path, parts.query, ""))
                connection.request("GET", resource, headers={
                    "User-Agent": "FeedBasket/0.1",
                    "Accept": "text/html, application/rss+xml, application/atom+xml, application/xml, text/xml, application/pdf, */*;q=0.1",
                    "Accept-Encoding": "identity",
                })
                result = connection.getresponse()
                if result.status in (301, 302, 303, 307, 308):
                    destination = result.getheader("Location")
                    if not destination:
                        raise FetchError("Publisher redirect has no destination")
                    current = normalize_url(urljoin(current, destination), keep_query=preview)
                    continue
                if result.status != 200:
                    raise PublisherHTTPError(result.status)
                media_type = result.headers.get_content_type()
                link = result.getheader("Link", "")
                if media_type == "application/pdf":
                    if preview:
                        return Document(current, b"", media_type, link)
                    raise PDFUnsupported()
                prefix = result.read(1024)
                if prefix.startswith(b"%PDF-") or (
                    media_type == "application/octet-stream" and b"%PDF-" in prefix
                ):
                    if preview:
                        return Document(current, b"", "application/pdf", link)
                    raise PDFUnsupported()
                if preview and media_type not in {
                    "text/html", "application/xhtml+xml", "application/xml", "text/xml", "text/plain",
                    "application/rss+xml", "application/atom+xml", "application/rdf+xml",
                } and not (media_type == "application/octet-stream" and prefix.lstrip().startswith(b"<")):
                    return Document(current, b"", media_type, link)
                data = prefix + result.read(MAX_RESPONSE + 1 - len(prefix))
                if len(data) > MAX_RESPONSE:
                    raise FetchError("Publisher response exceeds 5 MB")
                return Document(current, data, media_type, link)
            finally:
                connection.close()
    except (OSError, http.client.HTTPException, ValueError) as error:
        raise FetchError("Publisher request failed") from error
    raise FetchError("Publisher redirected too many times")


def parse_html(data):
    try:
        return html.fromstring(data, parser=html.HTMLParser(no_network=True))
    except (ValueError, etree.ParserError):
        return html.Element("div")


def safe_html(markup, url):
    tree = parse_html(markup)
    for element in tree.iter():
        for attr in ("href", "src"):
            if value := element.get(attr):
                element.set(attr, urljoin(url, value))
    return nh3.clean(
        html.tostring(tree, encoding="unicode"),
        tags=ARTICLE_TAGS,
        attributes={"a": {"href", "title"}, "img": {"src", "alt", "width", "height"}, "td": {"colspan", "rowspan"}, "th": {"colspan", "rowspan"}},
        url_schemes={"https", "http"},
        clean_content_tags={"script", "style", "iframe", "template", "noscript"},
        link_rel="noopener noreferrer",
    )


def clean_text(markup):
    tree = parse_html(nh3.clean(markup, tags={"p", "div", "br"}, clean_content_tags={"script", "style"}))
    return " ".join(" ".join(tree.itertext()).split())


def usable(markup):
    tree = parse_html(markup)
    text = clean_text(markup)
    linked = sum(len(" ".join(link.itertext()).strip()) for link in tree.iter("a"))
    return len(text) >= 120 and linked < len(text) * 0.65


def canonical_url(tree, url):
    final_host = urlsplit(url).hostname.removeprefix("www.")
    for link in tree.iter("link"):
        if "canonical" not in link.get("rel", "").lower().split():
            continue
        try:
            target = normalize_url(urljoin(url, link.get("href", "")))
        except ValueError:
            continue
        parts = urlsplit(target)
        original = urlsplit(url)
        if (parts.hostname.removeprefix("www.") == final_host and parts.port == original.port
                and (parts.path != "/" or original.path == "/")):
            return target
    return url


def mozilla(data, url):
    node = shutil.which("node")
    if not node:
        return None
    worker = Path(__file__).with_name("readability.cjs")
    source_directory = worker.parent.parent
    node_directory = os.getenv("FEEDBASKET_NODE_DIR")
    if not node_directory and (source_directory / "package.json").is_file():
        node_directory = source_directory
    try:
        result = subprocess.run(
            [node, str(worker), url], input=data, capture_output=True, timeout=8, check=False,
            cwd=node_directory,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.decode("utf-8") if result.returncode == 0 else None


def extract(document):
    tree = parse_html(document.data)
    canonical = canonical_url(tree, document.url)
    title = clean_text(tree.findtext(".//title", ""))[:500]
    try:
        primary = trafilatura.extract(document.data, url=document.url, output_format="html",
                                      include_links=True, include_images=True, include_comments=False)
    except (ValueError, etree.LxmlError):
        primary = None
    for name, candidate in (("trafilatura", primary), ("mozilla", None)):
        if name == "mozilla":
            candidate = mozilla(document.data, document.url)
        if candidate:
            body = safe_html(candidate, document.url)
            if usable(body):
                return canonical, title, body, name
    return canonical, title, None, None


def load_article(url, rss_body, *, fetch_document=fetch):
    document = fetch_document(url)
    if rss_body:
        canonical = canonical_url(parse_html(document.data), document.url)
        return document.url, canonical, "", None, None
    return document.url, *extract(document)
