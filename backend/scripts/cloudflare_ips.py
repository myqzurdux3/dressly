#!/usr/bin/env python3
"""Fetch Cloudflare's proxy ranges for CLOTHESAPP_TRUSTED_PROXIES.

Why this matters, and it is not cosmetic:

With Cloudflare in front, every request arrives from a Cloudflare address. The
real client is in X-Forwarded-For, and uvicorn only believes that header from
addresses in --forwarded-allow-ips. Leave it at 127.0.0.1 and request.client.host
becomes Cloudflare's address for everybody, which means:

  - the per-IP sign-in limit counts the whole internet as one visitor, so ten
    failed logins from anywhere lock out every user at once, and
  - a password-guessing run is indistinguishable from ordinary traffic, which is
    the entire point of that limit.

So the list has to be right, and it changes: Cloudflare publishes it and adds
ranges. Run this after setting up the proxy and again if sign-ins start failing
with 429 for no reason.

    python3 scripts/cloudflare_ips.py              # print the value
    python3 scripts/cloudflare_ips.py --write-env  # put it in .env

uvicorn 0.51 accepts CIDR networks here (older versions compared strings and
would silently trust nothing), which is why this can pass ranges rather than
thousands of addresses.
"""
import argparse
import re
import sys
import urllib.request
from pathlib import Path

BACKEND = Path(__file__).resolve().parent.parent
SOURCES = ("https://www.cloudflare.com/ips-v4", "https://www.cloudflare.com/ips-v6")
KEY = "CLOTHESAPP_TRUSTED_PROXIES"

# Used when the machine cannot reach Cloudflare. Correct as published on
# 2026-07-30; treat it as a floor, not as current — that is why the fetch is
# tried first.
FALLBACK = (
    "173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,"
    "141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,"
    "197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,"
    "104.24.0.0/14,172.64.0.0/13,131.0.72.0/22,"
    "2400:cb00::/32,2606:4700::/32,2803:f800::/32,2405:b500::/32,"
    "2405:8100::/32,2a06:98c0::/29,2c0f:f248::/32"
)

_CIDR = re.compile(r"^[0-9a-fA-F:.]+/\d{1,3}$")


def fetch() -> list[str]:
    out: list[str] = []
    for url in SOURCES:
        with urllib.request.urlopen(url, timeout=15) as resp:
            body = resp.read().decode()
        found = [ln.strip() for ln in body.splitlines() if _CIDR.match(ln.strip())]
        if not found:
            raise ValueError(f"{url} returned nothing that looks like a range")
        out += found
    return out


def write_env(value: str) -> Path:
    """Replace the key in .env, keeping everything else byte for byte."""
    env = BACKEND / ".env"
    lines = env.read_text().splitlines() if env.exists() else []
    line = f"{KEY}={value}"
    for i, existing in enumerate(lines):
        if existing.strip().startswith(f"{KEY}="):
            lines[i] = line
            break
    else:
        lines += ["", "# Cloudflare's proxy ranges, so the real client IP is",
                  "# believed from X-Forwarded-For. See scripts/cloudflare_ips.py.",
                  line]
    env.write_text("\n".join(lines) + "\n")
    return env


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--write-env", action="store_true",
                    help="update backend/.env instead of printing")
    args = ap.parse_args()

    try:
        ranges = fetch()
        source = "cloudflare.com"
    except Exception as e:
        print(f"could not fetch Cloudflare's list ({e}); using the built-in copy",
              file=sys.stderr)
        ranges, source = FALLBACK.split(","), "built-in fallback"

    # 127.0.0.1 stays: doctor.py and any local probe come from there.
    value = ",".join(["127.0.0.1"] + ranges)
    print(f"{len(ranges)} ranges from {source}", file=sys.stderr)

    if args.write_env:
        path = write_env(value)
        print(f"wrote {KEY} to {path}", file=sys.stderr)
        print("Restart the server for it to take effect.", file=sys.stderr)
    else:
        print(f"{KEY}={value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
