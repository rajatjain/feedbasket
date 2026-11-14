from contextlib import contextmanager
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from socket import SHUT_RDWR
from threading import Event, Thread
from urllib.parse import parse_qs, unquote, urlsplit
from xml.etree import ElementTree

import pytest
from fastapi.testclient import TestClient
from pypdf import PdfWriter

from feedbasket import auth
from feedbasket.config import Config
from feedbasket.db import write
from feedbasket.main import create_app


@contextmanager
def loopback_server(handler, *, server_class=ThreadingHTTPServer):
    with server_class(("127.0.0.1", 0), handler) as server:
        worker = Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
        worker.start()
        try:
            yield server
        finally:
            server.shutdown()
            worker.join()


@pytest.fixture
def http_server():
    return loopback_server


@pytest.fixture
def backend_config(tmp_path):
    return Config(db_path=tmp_path / "library.sqlite", backup_frequency="disabled")


@pytest.fixture
def start_backend():
    @contextmanager
    def start(config, **client_options):
        app = create_app(config, start_worker=False)
        with TestClient(app, base_url=config.public_url, **client_options) as client:
            yield app, client

    return start


@pytest.fixture
def account_headers():
    def create(app, *names):
        with write(app.state.engine) as db:
            accounts = [auth.create_local_account(db, app.state.config, name) for name in names]
            return tuple({"Authorization": f"Bearer {auth.issue_session(db, account.id)}"} for account in accounts)

    return create


@pytest.fixture
def pdf_bytes():
    def make(pages=2):
        writer = PdfWriter()
        for _ in range(pages):
            writer.add_blank_page(width=612, height=792)
        stream = BytesIO()
        writer.write(stream)
        return stream.getvalue()

    return make


class ObjectServer(ThreadingHTTPServer):
    def __init__(self, address, handler):
        self.fail_copy = False
        self.fail_delete = False
        self.drop_delete_response = False
        self.drop_upload_response = False
        self.block_upload = False
        self.upload_started = Event()
        self.release_upload = Event()
        super().__init__(address, handler)


@pytest.fixture
def s3_endpoint(tmp_path):
    root = tmp_path / "objects"

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def object_path(self, request_path):
            key = unquote(urlsplit(request_path).path).removeprefix("/test-bucket/")
            return root / key

        def reply(self, status, body=b"", **headers):
            self.send_response(status)
            self.send_header("Content-Length", headers.pop("Content_Length", str(len(body))))
            for key, value in headers.items():
                self.send_header(key.replace("_", "-"), value)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_HEAD(self):
            if self.server.drop_upload_response:
                self.connection.shutdown(SHUT_RDWR)
                return
            path = self.object_path(self.path)
            if not path.is_file():
                self.reply(404)
                return
            self.reply(200, Content_Length=str(path.stat().st_size),
                       x_amz_meta_sha256=sha256(path.read_bytes()).hexdigest())

        def do_PUT(self):
            assert self.headers["Authorization"].startswith("AWS4-HMAC-SHA256 Credential=fixture-access/")
            path = self.object_path(self.path)
            if source := self.headers.get("x-amz-copy-source"):
                if self.server.fail_copy:
                    self.reply(403, b"<Error><Code>AccessDenied</Code></Error>")
                    return
                data = self.object_path("/" + source.lstrip("/")).read_bytes()
                result = b'<CopyObjectResult><ETag>"copied"</ETag></CopyObjectResult>'
            else:
                data = self.rfile.read(int(self.headers["Content-Length"]))
                result = b""
                if self.headers.get("Content-Type") == "application/pdf":
                    self.server.upload_started.set()
                    if self.server.block_upload and not self.server.release_upload.wait(timeout=10):
                        self.reply(500)
                        return
                    assert self.headers["If-None-Match"] == "*"
                    if path.exists():
                        self.reply(412, b"<Error><Code>PreconditionFailed</Code></Error>")
                        return
                    assert self.headers["x-amz-meta-sha256"] == sha256(data).hexdigest()
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            if self.server.drop_upload_response:
                self.connection.shutdown(SHUT_RDWR)
                return
            self.reply(200, result, Content_Type="application/xml")

        def do_GET(self):
            query = parse_qs(urlsplit(self.path).query)
            if "list-type" in query:
                prefix = query["prefix"][0]
                listing = ElementTree.Element("ListBucketResult")
                ElementTree.SubElement(listing, "IsTruncated").text = "false"
                for path in (root / prefix).glob("*"):
                    if path.is_file():
                        item = ElementTree.SubElement(listing, "Contents")
                        ElementTree.SubElement(item, "Key").text = prefix + path.name
                self.reply(200, ElementTree.tostring(listing), Content_Type="application/xml")
                return
            assert query["X-Amz-Expires"] == ["300"]
            assert query["X-Amz-Credential"][0].startswith("fixture-access/")
            assert len(query["X-Amz-Signature"][0]) == 64
            self.reply(200, self.object_path(self.path).read_bytes(), Content_Type="application/pdf")

        def do_DELETE(self):
            assert self.headers["Authorization"].startswith("AWS4-HMAC-SHA256 Credential=fixture-access/")
            if self.server.fail_delete:
                self.reply(403, b"<Error><Code>AccessDenied</Code></Error>")
                return
            self.object_path(self.path).unlink(missing_ok=True)
            if self.server.drop_delete_response:
                self.connection.shutdown(SHUT_RDWR)
                return
            self.reply(204)

    with loopback_server(Handler, server_class=ObjectServer) as server:
        try:
            yield server, root
        finally:
            server.release_upload.set()
