"""The interactive docs are a development tool, not a public listing."""

import importlib

import config


def _app_with_env(monkeypatch, is_dev: bool):
    monkeypatch.setattr(config, "IS_DEV", is_dev)
    import main
    return importlib.reload(main).app


def test_docs_are_served_in_dev(client):
    assert client.get("/docs").status_code == 200
    assert client.get("/openapi.json").status_code == 200


def test_docs_are_gone_in_production(monkeypatch):
    from fastapi.testclient import TestClient

    app = _app_with_env(monkeypatch, False)
    with TestClient(app) as c:
        assert c.get("/docs").status_code == 404
        assert c.get("/redoc").status_code == 404
        assert c.get("/openapi.json").status_code == 404
        # The API itself is untouched.
        assert c.get("/health").status_code == 200

    _app_with_env(monkeypatch, True)  # restore for the rest of the session
