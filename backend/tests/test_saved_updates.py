import socket
from contextlib import contextmanager
from threading import Thread
from time import monotonic, sleep

import httpx
import uvicorn

from feedbasket import auth
from feedbasket.config import Config
from feedbasket.db import make_engine, write
from feedbasket.main import create_app, migrate


@contextmanager
def serve(config):
    with socket.create_server(("127.0.0.1", 0)) as listener:
        port = listener.getsockname()[1]
        server = uvicorn.Server(uvicorn.Config(
            create_app(config, start_worker=False), log_config=None, timeout_graceful_shutdown=1,
        ))
        thread = Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
        thread.start()
        try:
            deadline = monotonic() + 5
            while not server.started and thread.is_alive() and monotonic() < deadline:
                sleep(0.01)
            assert server.started
            with httpx.Client(base_url=f"http://127.0.0.1:{port}", timeout=3) as client:
                yield client
        finally:
            server.should_exit = True
            thread.join(timeout=5)
            assert not thread.is_alive()


def test_saved_update_and_cursor_catchup_after_backend_restart(tmp_path):
    config = Config(db_path=tmp_path / "updates.sqlite")
    engine = make_engine(config.db_path)
    try:
        migrate(engine)
        with write(engine) as db:
            owner = auth.create_local_account(db, config, "Reader", admin=True)
            other = auth.create_local_account(db, config, "other-reader")
            owner_headers = {"Authorization": f"Bearer {auth.issue_session(db, owner.id)}"}
            other_headers = {"Authorization": f"Bearer {auth.issue_session(db, other.id)}"}
    finally:
        engine.dispose()

    first_url = "https://www.nasa.gov/missions/artemis/i-am-artemis-katie-spicer/"
    second_url = "https://science.nasa.gov/earth/earth-observatory/a-global-rebound-for-mangroves/"
    with serve(config) as client:
        assert client.get("/api/v1/updates").status_code == 401
        with client.stream("GET", "/api/v1/updates", headers=owner_headers) as stream:
            assert stream.headers["content-type"].startswith("text/event-stream")
            events = stream.iter_lines()
            assert next(events) == "data: sync"
            assert next(events) == ""
            saved = client.post("/api/v1/articles", json={"url": first_url}, headers=owner_headers)
            assert saved.status_code == 202
            assert next(events) == "data: sync"
            first = client.get("/api/v1/sync", headers=owner_headers).json()
            assert first["items"][0]["data"]["url"] == first_url

    with serve(config) as client:
        assert client.post("/api/v1/articles", json={"url": second_url}, headers=owner_headers).status_code == 202
        with client.stream("GET", "/api/v1/updates", headers=owner_headers) as stream:
            assert next(stream.iter_lines()) == "data: sync"
            resumed = client.get("/api/v1/sync", params={"after": first["cursor"]}, headers=owner_headers).json()
            assert [change["data"]["url"] for change in resumed["items"]] == [second_url]
        assert client.get("/api/v1/sync", headers=other_headers).json()["items"] == []
