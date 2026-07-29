"""The access log has to measure the whole request, body included.

A Starlette `@app.middleware("http")` stops its timer when the handler returns
the response object — before any of the body has gone out. For a file response
that is the wrong number entirely: the log claimed "200 OK in 6 ms" about a
transfer the client was still waiting on, which made every image investigation
start from a false premise.
"""
import asyncio
import io
import logging
import re

import pytest
from PIL import Image

import accesslog
from tests.conftest import create_cloth


@pytest.fixture()
def captured(monkeypatch):
    """Collect access lines instead of writing them to a file."""
    lines = []

    class _Sink(logging.Handler):
        def emit(self, record):
            lines.append(record.getMessage())

    handler = _Sink()
    accesslog.log.addHandler(handler)
    accesslog.log.setLevel(logging.INFO)
    yield lines
    accesslog.log.removeHandler(handler)


def _find(lines, needle):
    return [line for line in lines if needle in line]


def test_every_request_is_logged(client, auth, captured):
    client.get("/clothes", headers=auth)
    assert _find(captured, "/clothes"), captured


def test_images_are_logged_too(client, auth, captured):
    """They were excluded as noise, which left no way to tell a slow server
    from a slow network."""
    c = create_cloth(client, auth)
    captured.clear()
    client.get(c["images"][0]["thumb_url"])
    assert _find(captured, "/thumb/"), captured


def test_the_line_carries_status_duration_and_size(client, auth, captured):
    client.get("/clothes", headers=auth)
    line = _find(captured, "/clothes")[0]
    assert " 200 " in line
    assert "ms" in line
    assert "B" in line          # 244B / 1.2KB / 3.4MB


def test_errors_are_logged_with_their_status(client, captured):
    client.get("/clothes", headers={"Authorization": "Bearer nope"})
    assert _find(captured, "401"), captured


def test_signatures_are_stripped_but_the_version_is_kept(client, auth,
                                                         captured, monkeypatch):
    monkeypatch.setenv("CLOTHESAPP_SIGN_IMAGE_URLS", "1")
    c = create_cloth(client, auth)
    captured.clear()
    client.get(c["images"][0]["thumb_url"])
    line = _find(captured, "/thumb/")[0]
    assert "s=" not in line, "the signature makes every line unreadable"
    assert "v=" in line, "the version is worth keeping, to spot a stale one"


def test_timing_includes_sending_the_body():
    """The reason this middleware exists.

    Drives the ASGI interface directly with a send() that stalls between the
    response start and its body — a handler-only timer would miss that entirely.
    """
    recorded = []

    class _App:
        async def __call__(self, scope, receive, send):
            await send({"type": "http.response.start", "status": 200,
                        "headers": []})
            await asyncio.sleep(0.3)          # the body takes a while to go out
            await send({"type": "http.response.body", "body": b"x" * 100})

    mw = accesslog.AccessLogMiddleware(_App(), app_log=logging.getLogger("x"))

    class _Sink(logging.Handler):
        def emit(self, record):
            recorded.append(record.getMessage())

    handler = _Sink()
    accesslog.log.addHandler(handler)
    accesslog.log.setLevel(logging.INFO)
    try:
        scope = {"type": "http", "method": "GET", "path": "/slow",
                 "query_string": b"", "client": ("1.2.3.4", 1)}

        async def receive():
            return {"type": "http.request"}

        async def send(_):
            return None

        asyncio.run(mw(scope, receive, send))
    finally:
        accesslog.log.removeHandler(handler)

    assert recorded, "nothing was logged"
    line = recorded[0]
    ms = int(line.split("ms")[0].split()[-1])
    assert ms >= 250, f"the timer stopped before the body was sent: {line}"
    assert "transfer" in line, "the handler/transfer split should be reported"


def test_slow_requests_are_copied_to_the_main_log(monkeypatch):
    """So they are visible without opening a second file."""
    warned = []

    class _Log:
        def warning(self, fmt, *a):
            warned.append(fmt % a)

    monkeypatch.setattr(accesslog, "SLOW_MS", 10)

    class _App:
        async def __call__(self, scope, receive, send):
            await send({"type": "http.response.start", "status": 200,
                        "headers": []})
            await asyncio.sleep(0.05)
            await send({"type": "http.response.body", "body": b"ok"})

    mw = accesslog.AccessLogMiddleware(_App(), app_log=_Log())
    scope = {"type": "http", "method": "GET", "path": "/x",
             "query_string": b"", "client": ("1.2.3.4", 1)}

    async def receive():
        return {"type": "http.request"}

    async def send(_):
        return None

    asyncio.run(mw(scope, receive, send))
    assert any("SLOW" in w for w in warned), warned


def test_a_big_response_reports_its_size(client, auth, captured):
    """Bytes on the wire are what a slow link is measured in."""
    buf = io.BytesIO()
    Image.new("RGB", (1400, 1400), (10, 90, 200)).save(buf, "PNG")
    big = buf.getvalue()
    r = client.post(
        "/clothes", headers=auth,
        data={"name": "big", "category": "tshirt", "cut": "normal"},
        files=[("images", ("f.png", big, "image/png")),
               ("images", ("b.png", big, "image/png"))],
    )
    assert r.status_code == 200, r.text
    captured.clear()
    client.get(r.json()["images"][0]["cutout_url"])
    line = _find(captured, "/images/")[0]
    assert "KB" in line or "MB" in line, line


def test_background_work_is_not_counted_as_transfer(tmp_path, monkeypatch):
    """Starlette runs BackgroundTasks after the body is sent but inside the same
    ASGI call. Timing the call made `POST /enhance` — 145 ms of handler that
    kicks off a 15 s AI generation — log as "2.1KB, transfer 15748ms", which
    reads as a slow network and is nobody's wait."""
    import time as _time

    import accesslog

    accesslog.configure(tmp_path)

    async def app(scope, receive, send):
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"content-type", b"text/plain")]})
        await send({"type": "http.response.body", "body": b"ok"})
        _time.sleep(0.35)          # the background task

    mw = accesslog.AccessLogMiddleware(app)
    scope = {"type": "http", "method": "POST", "path": "/clothes/1/enhance",
             "query_string": b"", "headers": [], "client": ("1.2.3.4", 1)}

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    sent = []
    asyncio.get_event_loop_policy().new_event_loop().run_until_complete(
        mw(scope, receive, lambda m: _noop(sent, m)))

    line = (tmp_path / "access.log").read_text().strip().splitlines()[-1]
    ms = int(re.search(r"\s(\d+)ms", line).group(1))
    assert ms < 200, f"background time charged to the request: {line}"
    assert "background, client not waiting" in line, line
    assert "transfer" not in line, f"background work reported as transfer: {line}"


async def _noop(sent, message):
    sent.append(message)
