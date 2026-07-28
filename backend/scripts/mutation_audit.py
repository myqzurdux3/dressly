#!/usr/bin/env python3
"""Judge test value by mutation: break the code, see which tests notice.

A test that never fails under any mutation of the code it claims to exercise is
not protecting anything. This applies small, plausible edits to the production
modules (flip a comparison, change a constant, negate a condition, drop a call),
runs the suite against each, and records which tests caught it.

Output: per-test "kill count" — how many mutants that test detected. Zero means
the test never once noticed broken code.

    python scripts/mutation_audit.py            # all modules
    python scripts/mutation_audit.py images.py  # one module
"""
import ast
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BACKEND = Path(__file__).resolve().parent.parent

# Production modules worth mutating (tests and scripts excluded).
TARGETS = [
    "images.py", "db.py", "auth.py", "ratelimit.py", "config.py",
    "routes_clothes.py", "routes_outfits.py", "routes_thumbs.py",
    "generator.py", "routes_stats.py", "routes_agenda.py", "audit.py",
]

_CMP_FLIP = {
    ast.Lt: ast.GtE, ast.GtE: ast.Lt, ast.Gt: ast.LtE, ast.LtE: ast.Gt,
    ast.Eq: ast.NotEq, ast.NotEq: ast.Eq,
}


class _Collect(ast.NodeVisitor):
    """Find mutation sites: (lineno, col, kind, description)."""

    def __init__(self):
        self.sites = []

    def visit_Compare(self, node):
        if len(node.ops) == 1 and type(node.ops[0]) in _CMP_FLIP:
            self.sites.append((node.lineno, node.col_offset, "cmp",
                               type(node.ops[0]).__name__))
        self.generic_visit(node)

    def visit_Constant(self, node):
        if isinstance(node.value, bool):
            self.sites.append((node.lineno, node.col_offset, "bool",
                               str(node.value)))
        elif isinstance(node.value, int) and not isinstance(node.value, bool):
            self.sites.append((node.lineno, node.col_offset, "int",
                               str(node.value)))
        elif isinstance(node.value, str) and node.value and len(node.value) < 40:
            self.sites.append((node.lineno, node.col_offset, "str",
                               node.value[:20]))
        self.generic_visit(node)


class _Mutate(ast.NodeTransformer):
    """Apply exactly the one mutation at `target`."""

    def __init__(self, target):
        self.target = target
        self.applied = False

    def _hit(self, node):
        return (node.lineno, node.col_offset) == self.target[:2]

    def visit_Compare(self, node):
        self.generic_visit(node)
        if self.target[2] == "cmp" and self._hit(node):
            new = _CMP_FLIP[type(node.ops[0])]()
            node.ops = [new]
            self.applied = True
        return node

    def visit_Constant(self, node):
        if not self._hit(node):
            return node
        kind = self.target[2]
        if kind == "bool" and isinstance(node.value, bool):
            self.applied = True
            return ast.copy_location(ast.Constant(value=not node.value), node)
        if kind == "int" and isinstance(node.value, int) \
                and not isinstance(node.value, bool):
            self.applied = True
            return ast.copy_location(ast.Constant(value=node.value + 1), node)
        if kind == "str" and isinstance(node.value, str):
            self.applied = True
            return ast.copy_location(
                ast.Constant(value="MUTANT_" + node.value), node)
        return node


def _mutants_for(path: Path, limit: int):
    """Yield (description, mutated_source) for a module, evenly sampled."""
    src = path.read_text()
    tree = ast.parse(src)
    collector = _Collect()
    collector.visit(tree)
    sites = collector.sites
    if not sites:
        return
    step = max(1, len(sites) // limit)
    for site in sites[::step][:limit]:
        mutated = _Mutate(site).visit(ast.parse(src))
        ast.fix_missing_locations(mutated)
        try:
            code = ast.unparse(mutated)
        except Exception:
            continue
        yield f"{path.name}:{site[0]} {site[2]}({site[3]})", code


def _run_suite(workdir: Path):
    """Run pytest in workdir; return the set of failing test ids."""
    proc = subprocess.run(
        [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider",
         "--no-header", "-W", "ignore", "--tb=no", "-rf"],
        cwd=workdir, capture_output=True, text=True, timeout=1800,
    )
    failed = set()
    for line in proc.stdout.splitlines():
        if line.startswith("FAILED ") or line.startswith("ERROR "):
            failed.add(line.split(" ", 1)[1].split(" ")[0])
    return failed, proc.returncode


def main() -> int:
    targets = sys.argv[1:] or TARGETS
    per_module = int(len(targets) and max(4, 60 // len(targets)))

    with tempfile.TemporaryDirectory(prefix="mutaudit_") as tmp:
        work = Path(tmp) / "backend"
        shutil.copytree(BACKEND, work,
                        ignore=shutil.ignore_patterns("data", "__pycache__",
                                                      ".pytest_cache"))
        print("baseline run...", flush=True)
        baseline_failed, rc = _run_suite(work)
        if baseline_failed:
            print("baseline is not green; fix that first:", baseline_failed)
            return 1

        kills: dict = {}
        survivors = []
        total = 0
        for name in targets:
            path = work / name
            if not path.is_file():
                continue
            original = path.read_text()
            for desc, code in _mutants_for(path, per_module):
                total += 1
                path.write_text(code)
                try:
                    failed, _ = _run_suite(work)
                except subprocess.TimeoutExpired:
                    failed = {"<timeout>"}
                finally:
                    path.write_text(original)
                if failed:
                    for t in failed:
                        kills[t] = kills.get(t, 0) + 1
                else:
                    survivors.append(desc)
                print(f"  {desc:52} -> {len(failed):3} test(s) caught it",
                      flush=True)

    out = {"mutants": total, "kills": kills, "survivors": survivors}
    Path(BACKEND / "mutation_report.json").write_text(json.dumps(out, indent=2))
    print(f"\n{total} mutants; {len(survivors)} survived unnoticed")
    print(f"{len(kills)} distinct tests caught at least one")
    print("report -> backend/mutation_report.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
