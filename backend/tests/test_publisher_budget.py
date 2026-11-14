import subprocess
import sys
from time import monotonic

import pytest

from feedbasket import extraction, publisher


def test_budget_runs_in_a_separate_process():
    with pytest.raises(extraction.FetchError, match="valid HTTP or HTTPS URL"):
        publisher.Budget().run("article", "invalid", False)


def test_deadline_stops_and_reaps_worker(monkeypatch):
    popen = subprocess.Popen
    workers = []

    def delayed_worker(_, **kwargs):
        worker = popen([sys.executable, "-c", "import time; time.sleep(10)"], **kwargs)
        workers.append(worker)
        return worker

    monkeypatch.setattr(publisher.subprocess, "Popen", delayed_worker)
    budget = publisher.Budget()
    budget.deadline = monotonic() + 0.2
    with pytest.raises(publisher.DeadlineExceeded):
        budget.run("article", "https://example.com", False)
    assert workers[0].poll() is not None
