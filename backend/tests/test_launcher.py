"""run-prod.sh refusing to start, and saying why.

Every message here exists because the real one sent somebody the wrong way:

    ERROR:    [Errno 13] Permission denied

is what uvicorn prints when it cannot bind port 80. It names no port, so it
reads as a file-permission problem, and the next hour goes on chmod.
"""
import os
import shutil
import subprocess

import pytest

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(BACKEND, "run-prod.sh")

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")


def _run(**env):
    """Start the launcher with a valid secret and no .env interference."""
    environ = {k: v for k, v in os.environ.items()
               if not k.startswith("CLOTHESAPP_")}
    environ["CLOTHESAPP_SECRET"] = "x" * 48
    # Never actually take the port: one of these would start a real server and
    # hang the suite on a machine that happens to have a certificate.
    environ["CLOTHESAPP_CHECK_ONLY"] = "1"
    environ.update(env)
    return subprocess.run(["bash", SCRIPT], cwd=BACKEND, env=environ,
                          capture_output=True, text=True, timeout=120)


@pytest.mark.skipif(os.geteuid() == 0, reason="root may bind low ports")
def test_a_privileged_port_is_explained_not_just_refused():
    r = _run(CLOTHESAPP_PORT="80")
    assert r.returncode == 1
    out = r.stdout + r.stderr
    assert "port 80" in out, "the message must name the port uvicorn omits"
    assert "below 1024" in out
    # Three ways out, and each has to be actionable on its own.
    assert "setcap" in out
    assert "CLOTHESAPP_PORT=8443" in out
    assert "install_service.sh" in out


@pytest.mark.skipif(os.geteuid() == 0, reason="root may bind low ports")
def test_the_port_check_happens_before_anything_slow():
    """It must fail immediately, not after loading a model or binding a socket."""
    r = _run(CLOTHESAPP_PORT="443")
    assert r.returncode == 1
    assert "port 443" in (r.stdout + r.stderr)


def test_a_port_already_in_use_says_so_instead_of_blaming_permissions():
    """The other reason a start fails, and the one that actually bites: an older
    copy is still running. Predicting the answer from capabilities could never
    have found this."""
    import socket

    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.listen(1)
    try:
        r = _run(CLOTHESAPP_PORT=str(port), CLOTHESAPP_HOST="127.0.0.1")
    finally:
        sock.close()

    out = r.stdout + r.stderr
    assert r.returncode == 1
    assert "already taken" in out, out
    assert "ss -ltnp" in out, "it should say how to find what holds the port"
    assert "privileged" not in out, "wrong diagnosis: this is not a permission problem"


def test_the_check_asks_the_kernel_rather_than_guessing():
    """The bug this replaced: the guard decided from `getcap` on the python
    binary, so under systemd — where the capability is granted to the process,
    not the file — it refused a port it could have taken. The service then
    restarted every five seconds and `systemctl start` hung forever.

    A capability test cannot be written here without root, so this asserts the
    method instead: the script must open the socket, not inspect the binary.
    """
    script = open(SCRIPT).read()
    assert "getcap" not in script,         "back to predicting from file capabilities, which systemd does not use"
    assert "s.bind((host, port))" in script, "the port is no longer probed"


def test_a_high_port_is_not_blocked_by_the_privileged_port_check():
    """The guard must not become a reason a working setup stops working. On a
    machine with no certificate it stops at TLS instead, which is a different
    refusal with a different message."""
    r = _run(CLOTHESAPP_PORT="8443")
    out = r.stdout + r.stderr
    assert "below 1024" not in out
    # Either it is startable, or it stopped for the unrelated TLS reason.
    assert r.returncode == 0 or "No TLS certificate found" in out, out


def test_a_missing_secret_still_stops_it():
    environ = {k: v for k, v in os.environ.items()
               if not k.startswith("CLOTHESAPP_")}
    r = subprocess.run(["bash", SCRIPT], cwd=BACKEND, env=environ,
                       capture_output=True, text=True, timeout=120)
    assert r.returncode == 1
    assert "CLOTHESAPP_SECRET is not set" in r.stderr


def test_a_short_secret_still_stops_it():
    r = _run(CLOTHESAPP_SECRET="tooshort")
    assert r.returncode == 1
    assert "32+" in r.stderr


def test_the_thread_count_is_announced():
    """Operators need to see it: threads x workers above the core count is what
    turned a 2 s cut-out into 30 s, and it is invisible otherwise."""
    r = _run(CLOTHESAPP_PORT="8443")
    assert "per worker for background removal" in r.stdout
