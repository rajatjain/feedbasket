from dataclasses import replace
from datetime import datetime, timedelta

import pytest
from sqlalchemy import select

from feedbasket import backups, scheduler
from feedbasket.config import Config
from feedbasket.db import Job, get_setting, set_setting, write


@pytest.mark.parametrize("destination", ["local", "r2"])
def test_calendar_backups_rotate_and_retry_sunday_copy(tmp_path, monkeypatch, destination, request, start_backend):
    config = Config(db_path=tmp_path / "library.sqlite", backup_folder=str(tmp_path / "local"),
                    backup_prefix="deployment/snapshots/", r2_endpoint_url="http://127.0.0.1:1",
                    r2_bucket="test-bucket", r2_access_key_id="fixture-access", r2_secret_access_key="fixture-secret")
    root = tmp_path / destination / config.backup_prefix
    if destination == "r2":
        server, object_root = request.getfixturevalue("s3_endpoint")
        config = replace(config, r2_endpoint_url=f"http://127.0.0.1:{server.server_port}")
        check_calendar_workflow(config, object_root / config.backup_prefix, monkeypatch, start_backend, server)
    else:
        check_calendar_workflow(replace(config, backup_destination="local"), root, monkeypatch, start_backend)


def check_calendar_workflow(config, root, monkeypatch, start_backend, server=None):
    saturday = datetime(2026, 11, 14, 23, 59, 59, tzinfo=backups.TIMEZONE)
    moment = saturday

    def clock():
        return int(moment.timestamp())

    monkeypatch.setattr(scheduler, "now", clock)
    daily, weekly = root / "daily", root / "weekly"
    root.mkdir(parents=True)
    unrelated = root / "feedbasket-20200101T000000Z-000000000000.sqlite"
    unrelated.write_text("Legacy snapshot")

    with start_backend(config) as (app, _):
        engine = app.state.engine
        assert not scheduler.tick(engine, config)
        with write(engine) as db:
            assert int(get_setting(db, backups.NEXT_AT, 0)) == clock() + 1

        moment += timedelta(seconds=1)
        assert scheduler.tick(engine, config)
        first = next(weekly.glob("*.sqlite"))
        assert first.read_bytes() == (daily / first.name).read_bytes()
        assert not scheduler.tick(engine, config)

        moment += timedelta(days=1)
        assert scheduler.tick(engine, config)
        assert len(list(daily.glob("*.sqlite"))) == 2
        assert list(weekly.glob("*.sqlite")) == [first]

        moment += timedelta(days=6)
        assert scheduler.tick(engine, config)
        previous_weekly = set(weekly.glob("*.sqlite"))
        assert len(previous_weekly) == 2

        moment += timedelta(days=7)
        if server:
            server.fail_copy = True
        else:
            weekly.rename(root / "saved-weekly")
            weekly.write_text("Prevent creating files under weekly")
        assert scheduler.tick(engine, config)
        name = max(path.name for path in daily.glob("*.sqlite"))
        original = (daily / name).read_bytes()
        assert len(list(daily.glob("*.sqlite"))) == 2
        with write(engine) as db:
            job = db.scalar(select(Job).where(Job.status == "queued", Job.kind == "backup"))
            assert job.attempts == 1 and job.error
            job_id = job.id
            set_setting(db, "modified_after_snapshot", "yes")

    if server:
        assert set(weekly.glob("*.sqlite")) == previous_weekly
        server.fail_copy = False
    else:
        weekly.unlink()
        (root / "saved-weekly").rename(weekly)

    moment += timedelta(days=1)
    with start_backend(config) as (app, _):
        engine = app.state.engine
        with write(engine) as db:
            db.get(Job, job_id).run_at = clock()
        assert scheduler.tick(engine, config)
        assert (daily / name).read_bytes() == (weekly / name).read_bytes() == original
        assert set(weekly.glob("*.sqlite")) == (previous_weekly - {first}) | {weekly / name}
        assert scheduler.tick(engine, config)
        assert not scheduler.tick(engine, config)
        assert len(list(daily.glob("*.sqlite"))) == 2
        assert (weekly / name).read_bytes() == original
        assert unrelated.read_text() == "Legacy snapshot"
