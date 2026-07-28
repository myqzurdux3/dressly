"""Real-time admin alerting for user-reported problems.

Reports are always persisted in the DB (notifications / outfit_reports). This
module additionally pushes them out-of-band so an admin sees them without
polling — via a Slack/Discord webhook and/or SMTP email. Everything is
best-effort and runs on a background thread, so a slow or misconfigured
transport never blocks (or fails) the user's request.

Configure with env vars (see config.py):
  DRESSLY_ADMIN_WEBHOOK   Slack/Discord-style incoming webhook URL
  DRESSLY_ADMIN_EMAIL     recipient address (+ SMTP_HOST / SMTP_USER / ...)
With nothing configured, alerts are just printed to the server log.
"""
import json
import logging
import smtplib
import ssl
import threading
import urllib.request
from email.message import EmailMessage

import config

log = logging.getLogger(__name__)


def notify_admins(subject: str, body: str) -> None:
    """Fire-and-forget: dispatch on a daemon thread so the caller returns now."""
    threading.Thread(
        target=_dispatch, args=(subject, body), daemon=True
    ).start()


def _dispatch(subject: str, body: str) -> None:
    delivered = False
    if config.ADMIN_WEBHOOK_URL:
        try:
            _post_webhook(config.ADMIN_WEBHOOK_URL, f"*{subject}*\n{body}")
            delivered = True
        except Exception as e:  # pragma: no cover - network dependent
            log.warning("webhook failed: %s", e)
    if config.SMTP_HOST and config.ADMIN_EMAIL:
        try:
            _send_email(subject, body)
            delivered = True
        except Exception as e:  # pragma: no cover - network dependent
            log.warning("email failed: %s", e)
    if not delivered:
        # No transport configured (or all failed) — at least surface it.
        log.warning("ADMIN ALERT — %s\n%s", subject, body)


def _post_webhook(url: str, text: str) -> None:
    data = json.dumps({"text": text}).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}
    )
    urllib.request.urlopen(req, timeout=10).read()


def _send_email(subject: str, body: str) -> None:
    msg = EmailMessage()
    msg["Subject"] = f"[Dressly] {subject}"
    msg["From"] = config.SMTP_FROM
    msg["To"] = config.ADMIN_EMAIL
    msg.set_content(body)
    with smtplib.SMTP(config.SMTP_HOST, config.SMTP_PORT, timeout=15) as s:
        if config.SMTP_USE_TLS:
            s.starttls(context=ssl.create_default_context())
        if config.SMTP_USER:
            s.login(config.SMTP_USER, config.SMTP_PASSWORD)
        s.send_message(msg)
