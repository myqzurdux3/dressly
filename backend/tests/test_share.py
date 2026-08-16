"""Sharing one outfit with somebody who has no account.

The link is a row, not a signature, for one reason: a link you regret sending
has to be able to stop working. Everything else here is about exposing the
smallest thing that still makes sense to send.
"""
import db
from conftest import create_cloth, gen_outfit


def _outfit(client, auth):
    c = create_cloth(client, auth, name="Tee", category="tshirt")
    return gen_outfit(client, auth, [c["id"]])


def _share(client, auth, outfit_id):
    r = client.post(f"/outfits/{outfit_id}/share", headers=auth)
    assert r.status_code == 200, r.text
    return r.json()


# --- making a link --------------------------------------------------------

def test_sharing_returns_a_link(client, auth):
    o = _outfit(client, auth)
    body = _share(client, auth, o["id"])
    assert body["path"].startswith("/share/")
    assert len(body["token"]) >= 20, "a guessable token is not a permission"
    assert body["expires_at"]


def test_sharing_twice_hands_out_the_same_link(client, auth):
    """Otherwise every tap leaves another live link nobody remembers."""
    o = _outfit(client, auth)
    first = _share(client, auth, o["id"])
    second = _share(client, auth, o["id"])
    assert first["token"] == second["token"]


def test_an_outfit_with_no_image_cannot_be_shared(client, auth):
    """A planned day has no render yet; a link to nothing is not a share."""
    c = create_cloth(client, auth)
    r = client.post("/agenda/plan/apply", headers=auth,
                    json={"days": {"2026-08-04": [c["id"]]}})
    outfit_id = r.json()["created"][0]["outfit_id"]
    r = client.post(f"/outfits/{outfit_id}/share", headers=auth)
    assert r.status_code == 400
    assert "generate it" in r.json()["detail"]


def test_another_users_outfit_cannot_be_shared(client, auth):
    o = _outfit(client, auth)
    other = client.post("/auth/signup",
                        json={"email": "x@x.co", "password": "pw123456"}).json()
    oh = {"Authorization": f"Bearer {other['token']}"}
    assert client.post(f"/outfits/{o['id']}/share", headers=oh).status_code == 404


def test_sharing_needs_a_token(client, auth):
    o = _outfit(client, auth)
    assert client.post(f"/outfits/{o['id']}/share").status_code == 401


# --- using a link ---------------------------------------------------------

def test_the_page_opens_without_an_account(client, auth):
    o = _outfit(client, auth)
    token = _share(client, auth, o["id"])["token"]
    r = client.get(f"/share/{token}")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "tee" in r.text.lower(), "the garments are not listed"


def test_the_image_is_served_through_the_token(client, auth):
    """The recipient has no session and no signed URL; the token is the
    authorisation."""
    o = _outfit(client, auth)
    token = _share(client, auth, o["id"])["token"]
    r = client.get(f"/share/{token}/image")
    assert r.status_code == 200
    assert len(r.content) > 100


def test_the_page_asks_not_to_be_indexed(client, auth):
    """A shared outfit is not a public catalogue entry."""
    o = _outfit(client, auth)
    token = _share(client, auth, o["id"])["token"]
    for path in (f"/share/{token}", f"/share/{token}/image"):
        r = client.get(path)
        assert "noindex" in r.headers.get("x-robots-tag", ""), path


def test_the_page_leaks_nothing_about_the_owner(client, auth):
    o = _outfit(client, auth)
    token = _share(client, auth, o["id"])["token"]
    page = client.get(f"/share/{token}").text
    assert "u@test.co" not in page
    assert "Bearer" not in page


def test_a_made_up_token_is_a_404(client):
    assert client.get("/share/not-a-real-token").status_code == 404
    assert client.get("/share/not-a-real-token/image").status_code == 404


# --- taking it back -------------------------------------------------------

def test_revoking_kills_the_link(client, auth):
    """The reason links are rows."""
    o = _outfit(client, auth)
    token = _share(client, auth, o["id"])["token"]
    assert client.get(f"/share/{token}").status_code == 200

    r = client.delete(f"/outfits/{o['id']}/share", headers=auth)
    assert r.status_code == 200 and r.json()["revoked"] == 1
    assert client.get(f"/share/{token}").status_code == 404
    assert client.get(f"/share/{token}/image").status_code == 404


def test_a_revoked_link_is_not_resurrected_by_sharing_again(client, auth):
    o = _outfit(client, auth)
    old = _share(client, auth, o["id"])["token"]
    client.delete(f"/outfits/{o['id']}/share", headers=auth)
    new = _share(client, auth, o["id"])["token"]
    assert new != old
    assert client.get(f"/share/{old}").status_code == 404
    assert client.get(f"/share/{new}").status_code == 200


def test_an_expired_link_stops_working_on_its_own(client, auth):
    """Nobody revokes the link they forgot about."""
    o = _outfit(client, auth)
    token = _share(client, auth, o["id"])["token"]
    with db.get_conn() as conn:
        conn.execute(
            "UPDATE outfit_shares SET expires_at = datetime('now', '-1 day') "
            "WHERE token = ?", (token,))
    assert client.get(f"/share/{token}").status_code == 404


def test_an_expired_link_is_replaced_not_reused(client, auth):
    o = _outfit(client, auth)
    token = _share(client, auth, o["id"])["token"]
    with db.get_conn() as conn:
        conn.execute(
            "UPDATE outfit_shares SET expires_at = datetime('now', '-1 day') "
            "WHERE token = ?", (token,))
    assert _share(client, auth, o["id"])["token"] != token


def test_deleting_the_outfit_takes_its_links_with_it(client, auth):
    o = _outfit(client, auth)
    token = _share(client, auth, o["id"])["token"]
    assert client.delete(f"/outfits/{o['id']}", headers=auth).status_code == 200
    assert client.get(f"/share/{token}").status_code == 404


# --- what the app asks ----------------------------------------------------

def test_the_app_can_ask_whether_an_outfit_is_shared(client, auth):
    o = _outfit(client, auth)
    assert client.get(f"/outfits/{o['id']}/share",
                      headers=auth).json()["shared"] is False
    _share(client, auth, o["id"])
    body = client.get(f"/outfits/{o['id']}/share", headers=auth).json()
    assert body["shared"] is True and body["path"].startswith("/share/")


def test_revoking_when_nothing_is_shared_is_not_an_error(client, auth):
    o = _outfit(client, auth)
    r = client.delete(f"/outfits/{o['id']}/share", headers=auth)
    assert r.status_code == 200 and r.json()["revoked"] == 0
