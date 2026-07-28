def test_signup_login_me(client):
    r = client.post("/auth/signup", json={"email": "a@b.co", "password": "pw123456"})
    assert r.status_code == 200, r.text
    token = r.json()["token"]

    r = client.post("/auth/login", json={"email": "a@b.co", "password": "pw123456"})
    assert r.status_code == 200
    assert r.json()["user"]["email"] == "a@b.co"

    r = client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.json()["email"] == "a@b.co"


def test_login_wrong_password(client):
    client.post("/auth/signup", json={"email": "a@b.co", "password": "pw123456"})
    r = client.post("/auth/login", json={"email": "a@b.co", "password": "nope"})
    assert r.status_code >= 400


def test_protected_requires_token(client):
    assert client.get("/clothes").status_code == 401


def test_health(client):
    assert client.get("/health").json() == {"ok": True}
