import db
from conftest import create_cloth


def _make_admin(email):
    with db.get_conn() as conn:
        conn.execute("UPDATE users SET is_admin = 1 WHERE email = ?", (email,))


def test_notifications_are_admin_only(client, auth):
    assert client.get("/notifications", headers=auth).status_code == 403
    assert client.get("/notifications/reports", headers=auth).status_code == 403


def test_admin_can_read_queues(client):
    tok = client.post(
        "/auth/signup", json={"email": "admin@x.co", "password": "pw123456"}
    ).json()["token"]
    _make_admin("admin@x.co")
    h = {"Authorization": f"Bearer {tok}"}
    assert client.get("/notifications", headers=h).status_code == 200
    assert client.get("/notifications/reports", headers=h).status_code == 200


def test_reject_creates_admin_visible_notification(client, auth):
    c = create_cloth(client, auth)
    img = c["images"][0]
    r = client.post(
        f"/clothes/{c['id']}/images/{img['id']}/reject", headers=auth
    )
    assert r.status_code == 200
    # A normal user cannot see the notification queue...
    assert client.get("/notifications", headers=auth).status_code == 403
    # ...but an admin can, and the reported item is there.
    tok = client.post(
        "/auth/signup", json={"email": "boss@x.co", "password": "pw123456"}
    ).json()["token"]
    _make_admin("boss@x.co")
    notifs = client.get(
        "/notifications", headers={"Authorization": f"Bearer {tok}"}
    ).json()
    assert any(n["cloth_id"] == c["id"] for n in notifs)
