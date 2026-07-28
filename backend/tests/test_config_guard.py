"""The production config guard must refuse obviously-unsafe deployments.

config.py runs its checks at import time, so each case re-imports the module in
a subprocess with a controlled environment rather than mutating this one.
"""
import os
import subprocess
import sys

import pytest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOOD_SECRET = "x" * 48


def _import_config(**env):
    """Import config in a clean subprocess. Returns (returncode, stderr)."""
    child = dict(os.environ)
    child.pop("CLOTHESAPP_ENV", None)
    child.pop("CLOTHESAPP_SECRET", None)
    child.pop("CLOTHESAPP_CORS", None)
    child.update({k: v for k, v in env.items() if v is not None})
    proc = subprocess.run(
        [sys.executable, "-c", "import config"],
        cwd=BACKEND_DIR, env=child, capture_output=True, text=True,
    )
    return proc.returncode, proc.stderr


def test_dev_boots_with_no_env_at_all():
    code, err = _import_config()
    assert code == 0, err


def test_prod_rejects_default_secret():
    code, err = _import_config(
        CLOTHESAPP_ENV="prod", CLOTHESAPP_CORS="https://a.example"
    )
    assert code != 0
    assert "CLOTHESAPP_SECRET is unset" in err


def test_prod_rejects_short_secret():
    code, err = _import_config(
        CLOTHESAPP_ENV="prod", CLOTHESAPP_SECRET="tooshort",
        CLOTHESAPP_CORS="https://a.example",
    )
    assert code != 0
    assert "at least 32" in err


def test_prod_rejects_wildcard_cors():
    code, err = _import_config(
        CLOTHESAPP_ENV="prod", CLOTHESAPP_SECRET=GOOD_SECRET, CLOTHESAPP_CORS="*"
    )
    assert code != 0
    assert "CLOTHESAPP_CORS is '*'" in err


def test_prod_boots_when_configured():
    code, err = _import_config(
        CLOTHESAPP_ENV="prod", CLOTHESAPP_SECRET=GOOD_SECRET,
        CLOTHESAPP_CORS="https://a.example,https://b.example",
    )
    assert code == 0, err


@pytest.mark.parametrize("raw,expected", [
    ("https://a.example", ["https://a.example"]),
    (" https://a.example , https://b.example ",
     ["https://a.example", "https://b.example"]),
])
def test_cors_list_is_trimmed(raw, expected, monkeypatch):
    monkeypatch.setenv("CLOTHESAPP_CORS", raw)
    import importlib

    import config
    importlib.reload(config)
    assert config.ALLOW_ORIGINS == expected
    monkeypatch.delenv("CLOTHESAPP_CORS")
    importlib.reload(config)
