import os
from time import monotonic, sleep

import pytest
from fastapi.testclient import TestClient

from feedbasket import auth
from feedbasket.config import Config
from feedbasket.db import write
from feedbasket.main import create_app

pytestmark = pytest.mark.skipif(
    os.getenv("FEEDBASKET_LIVE_TESTS") != "1",
    reason="Set FEEDBASKET_LIVE_TESTS=1 to fetch from NASA",
)


def wait_for(read_status, completed, *, timeout=30):
    deadline = monotonic() + timeout
    result = read_status()
    while not completed(result) and monotonic() < deadline:
        sleep(0.2)
        result = read_status()
    assert completed(result), result
    return result


def test_live_save_and_feed_refresh(tmp_path):
    config = Config(db_path=tmp_path / "live.sqlite", backup_frequency="disabled")
    app = create_app(config)
    with TestClient(app, base_url=config.public_url) as client:
        with write(app.state.engine) as db:
            owner = auth.create_local_account(db, config, "owner")
            token = auth.issue_session(db, owner.id)
        client.headers["Authorization"] = f"Bearer {token}"

        article_url = "https://www.nasa.gov/missions/artemis/i-am-artemis-katie-spicer/"
        saved = client.post("/api/v1/articles", json={"url": article_url, "tags": ["artemis"]})
        assert saved.status_code == 202
        article_id = saved.json()["article"]["id"]
        detail = wait_for(
            lambda: client.get(f"/api/v1/articles/{article_id}").json(),
            lambda article: article["content_status"] in {"ready", "failed", "unavailable"},
        )
        assert detail["content_status"] == "ready", detail["content_status"]
        assert "Blue Moon" in detail["body_html"] and detail["tags"] == ["artemis"]

        subscription = client.post("/api/v1/feeds", json={"url": "https://www.nasa.gov/feed/"})
        assert subscription.status_code == 202
        feed_id = subscription.json()["id"]
        feed = wait_for(
            lambda: client.get("/api/v1/feeds").json()[0],
            lambda feed: feed["initial_done"] or feed["error"],
        )
        assert feed["id"] == feed_id and feed["initial_done"] and not feed["error"]
        items = client.get("/api/v1/articles", params={"source": "rss", "feed_id": feed_id}).json()["items"]
        assert items and all(feed_id in item["feed_ids"] for item in items)
