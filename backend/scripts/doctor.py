#!/usr/bin/env python3
"""Check a deployment and say what is wrong, in order.

Written after a restart came back on plain HTTP because its certificate was
missing. The app, which speaks HTTPS, reported "Handshake error in client
(wrong version number)" — an error that describes the symptom on the far side
of the connection and says nothing about the cause.

Run it on the server, from the install directory:

    python scripts/doctor.py
"""
import os
import socket
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BACKEND))

OK, WARN, FAIL = "  ok  ", " warn ", " FAIL "
_problems = []


def report(level, title, detail=""):
    print(f"[{level}] {title}")
    if detail:
        for line in detail.splitlines():
            print(f"         {line}")
    if level == FAIL:
        _problems.append(title)


def check_env():
    env = os.environ.get("CLOTHESAPP_ENV", "dev")
    secret = os.environ.get("CLOTHESAPP_SECRET", "")
    if not secret and (BACKEND / ".env").is_file():
        for line in (BACKEND / ".env").read_text().splitlines():
            if line.strip().startswith("CLOTHESAPP_SECRET="):
                secret = line.split("=", 1)[1].strip().strip('"').strip("'")

    if env == "dev":
        report(WARN, "CLOTHESAPP_ENV is 'dev'",
               "Image URLs are unsigned and the config guard is off.\n"
               "Set CLOTHESAPP_ENV=prod in .env for a real deployment.")
    else:
        report(OK, f"CLOTHESAPP_ENV = {env}")

    if not secret:
        report(FAIL, "CLOTHESAPP_SECRET is not set",
               "Neither exported nor present in .env. The server will refuse "
               "to start.\n"
               "  python -c 'import secrets; print(secrets.token_urlsafe(48))'")
    elif len(secret) < 32:
        report(FAIL, f"CLOTHESAPP_SECRET is only {len(secret)} characters",
               "It needs 32 or more.")
    else:
        report(OK, "CLOTHESAPP_SECRET looks usable")
        if not (BACKEND / ".env").is_file() or "CLOTHESAPP_SECRET=" not in \
                (BACKEND / ".env").read_text():
            report(WARN, "the secret is not in .env",
                   "If it only lives in the shell, the next restart loses it "
                   "and every user is signed out.")


def check_tls():
    crt, key = BACKEND / "certs/server.crt", BACKEND / "certs/server.key"
    if not crt.is_file() or not key.is_file():
        report(FAIL, "no TLS certificate in certs/",
               "run-prod.sh will refuse to start. The app connects over "
               "HTTPS, so serving plain HTTP shows up as\n"
               "'Handshake error in client (wrong version number)'.\n"
               "  python scripts/make_cert.py --host <this server's IP>")
        return
    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes

        cert = x509.load_pem_x509_certificate(crt.read_bytes())
        fp = cert.fingerprint(hashes.SHA256()).hex()
        import datetime
        left = cert.not_valid_after_utc - datetime.datetime.now(
            datetime.timezone.utc)
        names = []
        try:
            ext = cert.extensions.get_extension_for_class(
                x509.SubjectAlternativeName).value
            names = [str(g.value) for g in ext]
        except Exception:
            pass
        if left.days < 0:
            report(FAIL, "the certificate has expired")
        elif left.days < 30:
            report(WARN, f"the certificate expires in {left.days} days")
        else:
            report(OK, f"certificate valid for {left.days} more days")
        report(OK, f"valid for: {', '.join(names) or 'unknown'}")
        print(f"         pin (apiCertSha256): {fp}")
    except Exception as e:
        report(WARN, f"could not read the certificate: {e}")

    mode = oct(key.stat().st_mode)[-3:]
    if mode != "600":
        report(WARN, f"certs/server.key is mode {mode}",
               "A private key should be 600.  chmod 600 certs/server.key")


def check_data():
    try:
        from config import IMAGES_DIR, THUMBS_DIR
        from db import get_conn
    except Exception as e:
        report(FAIL, f"the app does not import: {e}")
        return

    try:
        with get_conn() as conn:
            n = conn.execute("SELECT COUNT(*) c FROM clothes").fetchone()["c"]
            rows = conn.execute(
                "SELECT original_path, cutout_path FROM cloth_images").fetchall()
    except Exception as e:
        report(FAIL, f"the database is unreadable: {e}")
        return
    report(OK, f"database reachable ({n} clothes)")

    missing = outside = 0
    for r in rows:
        for col in ("original_path", "cutout_path"):
            p = Path(r[col])
            try:
                p.relative_to(IMAGES_DIR)
            except ValueError:
                outside += 1
                continue
            if not p.is_file():
                missing += 1
    if outside:
        report(FAIL, f"{outside} image paths point outside {IMAGES_DIR}",
               "The database was copied from another machine. Every image "
               "will 404.\n  python scripts/relocate_paths.py --apply")
    elif missing:
        report(WARN, f"{missing} image files are missing on disk")
    else:
        report(OK, "every image path resolves")

    thumbs = len(list(THUMBS_DIR.rglob("*.webp"))) if THUMBS_DIR.is_dir() else 0
    expected = len(rows)
    if thumbs == 0 and expected:
        report(WARN, "the thumbnail cache is empty",
               "The first visit to each screen will generate them while the "
               "user waits.\n  python scripts/warm_thumbnails.py")
    else:
        report(OK, f"{thumbs} cached thumbnails")


def check_port():
    host = os.environ.get("CLOTHESAPP_HOST", "0.0.0.0")
    port = int(os.environ.get("CLOTHESAPP_PORT", "8000"))
    probe = "127.0.0.1" if host in ("0.0.0.0", "") else host
    s = socket.socket()
    s.settimeout(2)
    listening = s.connect_ex((probe, port)) == 0
    s.close()
    if listening:
        report(OK, f"something is listening on {probe}:{port}")
    else:
        report(WARN, f"nothing is listening on {probe}:{port}",
               "Expected if the server is stopped. If it should be running, "
               "check its output — it may have refused to start.")


def main() -> int:
    if (BACKEND / ".env").is_file():
        for line in (BACKEND / ".env").read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

    print(f"checking {BACKEND}\n")
    for section, fn in (("environment", check_env), ("TLS", check_tls),
                        ("data", check_data), ("port", check_port)):
        print(f"--- {section} ---")
        fn()
        print()

    if _problems:
        print(f"{len(_problems)} problem(s) to fix:")
        for p in _problems:
            print(f"  - {p}")
        return 1
    print("nothing blocking found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
