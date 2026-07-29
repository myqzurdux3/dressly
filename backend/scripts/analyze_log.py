#!/usr/bin/env python3
"""Summarise the access log: what is slow, and where the time goes.

    python scripts/analyze_log.py               # whole file
    python scripts/analyze_log.py --last 500    # most recent 500 requests
    python scripts/analyze_log.py --slow 1000   # only requests over 1s

Reading it:

* a request MISSING from the log never reached the server — the stall is on the
  client or the network, not here;
* a large "transfer" share means the bytes were slow to go out, which is the
  link, not the code;
* a large "handler" share means the server itself was slow.
"""
import argparse
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

BACKEND = Path(__file__).resolve().parent.parent

LINE = re.compile(
    r"^(?P<ts>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) "
    r"(?P<method>\w+)\s+(?P<status>\d{3})\s+(?P<ms>\d+)ms\s+"
    r"(?P<size>\S+)\s+(?P<path>\S+)\s+(?P<client>\S+)"
    r"(?: \(handler (?P<handler>[\d.]+)ms, transfer (?P<transfer>[\d.]+)ms\))?"
)

# Collapse ids so /clothes/12 and /clothes/34 count as one endpoint.
_NUM = re.compile(r"/\d+")


def _bucket(path: str) -> str:
    path = path.split("?")[0]
    if path.startswith("/thumb/"):
        parts = path.split("/")
        return f"/thumb/{parts[2]}/{parts[3]}/…" if len(parts) > 4 else path
    if path.startswith(("/images/", "/generated/")):
        return path.split("/")[1].join(["/", "/…"])
    return _NUM.sub("/{id}", path)


def _pct(values, p):
    if not values:
        return 0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * p / 100))]


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", default=str(BACKEND / "data/logs/access.log"))
    ap.add_argument("--last", type=int, help="only the most recent N requests")
    ap.add_argument("--slow", type=int, default=0,
                    help="only requests at least this many ms")
    args = ap.parse_args()

    path = Path(args.file)
    if not path.is_file():
        print(f"no log at {path}")
        print("Is CLOTHESAPP_ACCESS_LOG=0, or has the server not run yet?")
        return 1

    rows = []
    for line in path.read_text(errors="replace").splitlines():
        m = LINE.match(line)
        if m:
            rows.append(m.groupdict())
    if args.last:
        rows = rows[-args.last:]
    if args.slow:
        rows = [r for r in rows if int(r["ms"]) >= args.slow]
    if not rows:
        print("nothing matched")
        return 0

    by = defaultdict(list)
    for r in rows:
        by[_bucket(r["path"])].append(r)

    print(f"{len(rows)} requests, {rows[0]['ts']} -> {rows[-1]['ts']}\n")
    print(f"{'endpoint':46} {'n':>5} {'median':>8} {'p95':>8} {'max':>8}")
    print("-" * 80)
    for name, group in sorted(
            by.items(), key=lambda kv: -_pct([int(r["ms"]) for r in kv[1]], 95)):
        ms = [int(r["ms"]) for r in group]
        print(f"{name[:46]:46} {len(ms):5} {statistics.median(ms):7.0f}ms "
              f"{_pct(ms, 95):7.0f}ms {max(ms):7.0f}ms")

    slowest = sorted(rows, key=lambda r: -int(r["ms"]))[:10]
    print(f"\nslowest {len(slowest)} requests")
    print("-" * 80)
    for r in slowest:
        split = ""
        if r.get("transfer"):
            split = (f"   handler {float(r['handler']):.0f}ms, "
                     f"transfer {float(r['transfer']):.0f}ms")
        print(f"  {r['ts']}  {int(r['ms']):6}ms  {r['size']:>9}  "
              f"{r['path'][:60]}{split}")

    # Where the time goes, when the log says.
    split_rows = [r for r in rows if r.get("transfer")]
    if split_rows:
        transfer = sum(float(r["transfer"]) for r in split_rows)
        handler = sum(float(r["handler"]) for r in split_rows)
        total = transfer + handler
        print(f"\non the {len(split_rows)} requests with a breakdown:")
        print(f"  handler  {handler / total * 100:5.1f}%   (server's own work)")
        print(f"  transfer {transfer / total * 100:5.1f}%   (sending the bytes)")
        if transfer > handler:
            print("  -> dominated by transfer: the link, not the code.")
        else:
            print("  -> dominated by the handler: the server is the bottleneck.")

    errors = [r for r in rows if r["status"][0] in "45"]
    if errors:
        print(f"\n{len(errors)} error responses")
        counts = defaultdict(int)
        for r in errors:
            counts[(r["status"], _bucket(r["path"]))] += 1
        for (status, name), n in sorted(counts.items(), key=lambda kv: -kv[1]):
            print(f"  {status}  {n:4}x  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
