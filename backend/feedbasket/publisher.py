"""Bound blocking publisher work without leaving stalled threads behind."""

import json
import os
import signal
import subprocess
import sys
from time import monotonic

from . import extraction

JOB_TIMEOUT = 60


class DeadlineExceeded(extraction.FetchError):
    def __init__(self):
        super().__init__("Publisher job reached its 60-second time limit")


class Budget:
    def __init__(self):
        self.deadline = monotonic() + JOB_TIMEOUT

    def run(self, operation, *args):
        if self.deadline <= monotonic():
            raise DeadlineExceeded()
        request = json.dumps((operation, args)).encode()
        with subprocess.Popen(
            [sys.executable, "-m", "feedbasket.publisher"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, start_new_session=True,
        ) as worker:
            try:
                output, _ = worker.communicate(request, timeout=self.deadline - monotonic())
            except subprocess.TimeoutExpired as error:
                try:
                    os.killpg(worker.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                worker.communicate()
                raise DeadlineExceeded() from error
        if worker.returncode != 0:
            raise extraction.FetchError("Publisher processing failed")
        header, _, data = output.partition(b"\n")
        status, result = json.loads(header)
        if status == "http":
            raise extraction.PublisherHTTPError(result)
        if status == "pdf":
            raise extraction.PDFUnsupported()
        if status == "error":
            raise extraction.FetchError(result)
        if operation in {"fetch", "preview"}:
            url, media_type, link_header = result
            return extraction.Document(url, data, media_type, link_header)
        return result

    def fetch(self, url):
        return self.run("fetch", url)

    def preview(self, url):
        return self.run("preview", url)


def work(operation, args):
    try:
        if operation == "article":
            return ("ok", extraction.load_article(*args)), b""
        if operation not in {"fetch", "preview"}:
            raise ValueError("Unknown publisher operation")
        document = extraction.fetch(*args, preview=operation == "preview")
        return ("ok", (document.url, document.media_type, document.link_header)), document.data
    except extraction.PublisherHTTPError as error:
        return ("http", error.status), b""
    except extraction.PDFUnsupported:
        return ("pdf", None), b""
    except (extraction.FetchError, ValueError) as error:
        return ("error", str(error)), b""


if __name__ == "__main__":
    operation, args = json.load(sys.stdin.buffer)
    header, data = work(operation, args)
    sys.stdout.buffer.write(json.dumps(header).encode() + b"\n")
    sys.stdout.buffer.write(data)
