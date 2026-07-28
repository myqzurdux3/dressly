import db
from conftest import create_cloth


def _make_admin(email):
    with db.get_conn() as conn:
        conn.execute("UPDATE users SET is_admin = 1 WHERE email = ?", (email,))


def test_audit_records_key_actions(client, auth):
    # auth fixture already signed up -> 'auth.signup' recorded
    create_cloth(client, auth)  # -> 'cloth.create'
    with db.get_conn() as conn:
        actions = [r["action"] for r in conn.execute(
            "SELECT action FROM audit_log ORDER BY id").fetchall()]
    assert "auth.signup" in actions
    assert "cloth.create" in actions


def test_login_failure_is_audited(client):
    client.post("/auth/signup", json={"email": "x@y.co", "password": "pw123456"})
    client.post("/auth/login", json={"email": "x@y.co", "password": "wrong"})
    with db.get_conn() as conn:
        n = conn.execute(
            "SELECT COUNT(*) FROM audit_log WHERE action = 'auth.login_failed'"
        ).fetchone()[0]
    assert n == 1


def test_audit_endpoint_admin_only(client, auth):
    assert client.get("/notifications/audit", headers=auth).status_code == 403
    tok = client.post("/auth/signup",
                      json={"email": "boss@x.co", "password": "pw123456"}).json()["token"]
    _make_admin("boss@x.co")
    r = client.get("/notifications/audit",
                   headers={"Authorization": f"Bearer {tok}"})
    assert r.status_code == 200
    assert any(e["action"] == "auth.signup" for e in r.json())


def test_audit_filter_by_action(client, auth):
    create_cloth(client, auth)
    tok = client.post("/auth/signup",
                      json={"email": "adm@x.co", "password": "pw123456"}).json()["token"]
    _make_admin("adm@x.co")
    r = client.get("/notifications/audit?action=cloth.",
                   headers={"Authorization": f"Bearer {tok}"})
    assert r.status_code == 200
    assert all(e["action"].startswith("cloth.") for e in r.json())
