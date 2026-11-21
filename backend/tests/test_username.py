"""Signing in with a user name instead of the email."""


def _login(client, ident, password="pw123456"):
    return client.post("/auth/login", json={"email": ident, "password": password})


def test_set_a_username_then_sign_in_with_it(client, auth):
    r = client.post("/auth/username", headers=auth, json={"username": "Admin"})
    assert r.status_code == 200, r.text
    assert r.json()["username"] == "Admin"
    assert client.get("/auth/me", headers=auth).json()["username"] == "Admin"
    # Case does not matter, like the email.
    r = _login(client, "admin")
    assert r.status_code == 200, r.text
    assert r.json()["user"]["username"] == "Admin"


def test_email_still_works_and_wrong_password_fails(client, auth):
    client.post("/auth/username", headers=auth, json={"username": "bob"})
    me = client.get("/auth/me", headers=auth).json()
    assert _login(client, me["email"]).status_code == 200
    assert _login(client, "bob", "nope-nope").status_code == 401
    assert _login(client, "nobody").status_code == 401


def test_usernames_are_unique_and_validated(client, auth):
    assert client.post("/auth/username", headers=auth,
                       json={"username": "a@b"}).status_code == 400
    assert client.post("/auth/username", headers=auth,
                       json={"username": "ab"}).status_code == 400
    r = client.post("/auth/signup", json={
        "email": "other@test.co", "password": "secret123", "username": "taken"})
    assert r.status_code == 200, r.text
    assert client.post("/auth/username", headers=auth,
                       json={"username": "TAKEN"}).status_code == 409


def test_clearing_the_username(client, auth):
    client.post("/auth/username", headers=auth, json={"username": "temp"})
    r = client.post("/auth/username", headers=auth, json={"username": ""})
    assert r.status_code == 200 and r.json()["username"] == ""
    assert _login(client, "temp").status_code == 401
