## What and why

<!-- The behaviour that changes, and the reason. Not a list of the files touched. -->

## Evidence

<!-- For a fix: the test that was red before it. For a performance change: the
     numbers, measured, before and after. For a refactor: what got simpler. -->

## Checks

- [ ] `cd backend && python3 -m pytest`
- [ ] `cd dressly && flutter test`
- [ ] `cd dressly && dart analyze lib test`
- [ ] Migration added rather than an existing one edited (if the schema changed)
