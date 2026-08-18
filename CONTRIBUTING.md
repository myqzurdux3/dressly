# Contributing

Personal project, so this is mostly a note to my future self and to anyone I hand it to.

## Before you commit

Both suites, both green:

```bash
cd backend && python3 -m pytest        # 546 tests, ~6 min
cd dressly && flutter test             # 220 tests, ~10 s
cd dressly && dart analyze lib test    # no issues
```

A red suite is not a starting point for a refactor.

## House rules

**Tests never touch the network.** `backend/tests/conftest.py` stubs the weather, the
provider balance and the image API; the Flutter tests use a recording fake instead of a
real `ApiClient`. If a test suddenly takes seconds, something is calling out.

**Prove the bug before fixing it.** Write the failing test first — several bugs found in
the last audit looked obvious and were not (see `AUDIT.md` for the one agent conclusion
that turned out to be wrong).

**Comments explain why.** The code says what it does. A comment earns its place by
recording a decision, a constraint, or a trap someone already fell into — for example why
the outfit cascade has a deadline but never aborts a call in flight.

**Measure before optimising.** Every performance guess made on this project has been wrong
until measured. Put the numbers in the commit message.

**Migrations are append-only.** Add a new `@migration` function in `backend/db.py`; never
edit one that has already run against a real database.

## Deployment

`DEPLOIEMENT.txt` (French) is the authority: backend first, then the APK. Do not use
`flutter install` — it uninstalls the previous version and takes your data with it.
