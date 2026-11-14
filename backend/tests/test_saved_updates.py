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
            owner = auth.create_local_account(db, config, "Reader")
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
            resumed = client.get("/api/v1/sync", params={
                "after": first["cursor"], "library_id": first["library_id"],
            }, headers=owner_headers).json()
            assert resumed["library_id"] == first["library_id"]
            assert not resumed["reset_required"]
            assert [change["data"]["url"] for change in resumed["items"]] == [second_url]
        assert client.get("/api/v1/sync", headers=other_headers).json()["items"] == []


def test_pdf_position_and_highlight_wake_stream_and_reconnect(tmp_path):
    config = Config(db_path=tmp_path / "pdf-updates.sqlite")
    with serve(config) as client:
        signup = client.post("/api/v1/auth/signup", json={"username": "pdf-reader"})
        assert signup.status_code == 201
        owner = {"Authorization": f"Bearer {signup.json()['token']}"}
        saved = client.post("/api/v1/articles", headers=owner, json={"url": "https://example.test/guide.pdf"})
        article_id = saved.json()["article"]["id"]
        before = client.get("/api/v1/sync", headers=owner).json()
        position_path = f"/api/v1/pdfs/{article_id}/position"
        with client.stream("GET", "/api/v1/updates", headers=owner) as stream:
            events = (line for line in stream.iter_lines() if line)
            assert next(events) == "data: sync"
            position = client.put(position_path, headers=owner, json={"page": 3, "offset": 0.5})
            assert position.status_code == 200 and next(events) == "data: sync"
            page = client.get("/api/v1/sync", headers=owner, params={"after": before["cursor"]}).json()
            change, = page["items"]
            assert change["kind"] == "article" and change["data"]["reading_position"] == position.json()
            after_position = page["cursor"]
            assert client.put(position_path, headers=owner, json={"page": 3, "offset": 0.5}).json() == position.json()
            assert client.get("/api/v1/sync", headers=owner).json()["cursor"] == after_position
            mark = client.post(f"/api/v1/articles/{article_id}/highlights", headers=owner, json={
                "quote": "A river needs room to move.", "anchor": {
                    "kind": "pdf", "quads": [{"page": 3, "points": [0.1, 0.2, 0.6, 0.2, 0.1, 0.3, 0.6, 0.3]}],
                },
            })
            assert mark.status_code == 201 and next(events) == "data: sync"
            page = client.get("/api/v1/sync", headers=owner, params={"after": after_position}).json()
            change, = page["items"]
            assert change["kind"] == "highlight" and change["data"] == mark.json()

    with serve(config) as client:
        with client.stream("GET", "/api/v1/updates", headers=owner) as stream:
            assert next(stream.iter_lines()) == "data: sync"
            resumed = client.get("/api/v1/sync", headers=owner, params={
                "after": before["cursor"], "library_id": before["library_id"],
            }).json()
        assert not resumed["reset_required"]
        position_change, highlight_change = resumed["items"]
        assert position_change["data"]["reading_position"] == position.json()
        assert highlight_change["data"] == mark.json()


def test_sync_cursor_advances_past_deleted_highlight_with_limit_one(backend_config, start_backend, account_headers):
    with start_backend(backend_config) as (app, client):
        owner, = account_headers(app, "pagination-reader")
        client.headers.update(owner)
        saved = client.post("/api/v1/articles", json={"url": "https://example.test/guide.pdf"})
        assert saved.status_code == 202
        article_id = saved.json()["article"]["id"]
        before = client.get("/api/v1/sync").json()["cursor"]
        mark = client.post(f"/api/v1/articles/{article_id}/highlights", json={
            "quote": "Saved passage", "anchor": {
                "kind": "pdf", "quads": [{"page": 1, "points": [0.1, 0.2, 0.6, 0.2, 0.1, 0.3, 0.6, 0.3]}],
            },
        })
        assert mark.status_code == 201
        mark_id = mark.json()["id"]
        assert client.delete(f"/api/v1/highlights/{mark_id}").status_code == 204
        assert client.put(f"/api/v1/pdfs/{article_id}/position", json={"page": 2, "offset": 0.5}).status_code == 200

        empty = client.get("/api/v1/sync", params={"after": before, "limit": 1}).json()
        assert empty["items"] == [] and empty["has_more"] and empty["cursor"] > before
        deleted = client.get("/api/v1/sync", params={"after": empty["cursor"], "limit": 1}).json()
        item, = deleted["items"]
        assert (item["kind"], item["operation"], item["id"]) == ("highlight", "delete", mark_id)
        assert deleted["has_more"] and deleted["cursor"] > empty["cursor"]
        last = client.get("/api/v1/sync", params={"after": deleted["cursor"], "limit": 1}).json()
        item, = last["items"]
        assert item["id"] == article_id and item["data"]["reading_position"]["page"] == 2
        assert not last["has_more"] and last["cursor"] > deleted["cursor"]
