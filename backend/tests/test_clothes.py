from conftest import create_cloth, make_png


def test_create_and_get_and_list(client, auth):
    c = create_cloth(client, auth, name="Red Tee",
                     colors=[{"color": "Red", "dominance": "full"}])
    assert c["name"] == "red tee"  # names normalised to lowercase
    assert len(c["images"]) == 2
    assert {im["role"] for im in c["images"]} == {"front", "back"}
    assert [col["color"] for col in c["colors"]] == ["Red"]
    assert c["last_worn_at"] is None

    got = client.get(f"/clothes/{c['id']}", headers=auth).json()
    assert got == c

    lst = client.get("/clothes", headers=auth).json()
    assert [x["id"] for x in lst] == [c["id"]]
    # Batched list output must equal the single-item hydrate.
    assert lst[0] == got


def test_filter_by_category(client, auth):
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    jeans = create_cloth(client, auth, name="Jeans", category="jeans")
    create_cloth(client, auth, name="Cap", category="cap")

    only_tops = client.get("/clothes?category=tshirt", headers=auth).json()
    assert [x["id"] for x in only_tops] == [tee["id"]]

    only_bottoms = client.get("/clothes?category=jeans", headers=auth).json()
    assert [x["id"] for x in only_bottoms] == [jeans["id"]]

    # No filter returns everything.
    assert len(client.get("/clothes", headers=auth).json()) == 3
    # Unknown category returns nothing.
    assert client.get("/clothes?category=nope", headers=auth).json() == []


def test_name_stored_lowercase_and_migrated(client, auth):
    import db
    r = client.post("/clothes", headers=auth,
                    data={"name": "Blue SHIRT", "category": "shirt"},
                    files=[("images", ("f.png", make_png(), "image/png")),
                           ("images", ("b.png", make_png(), "image/png"))])
    cid = r.json()["id"]
    assert r.json()["name"] == "blue shirt"  # created lowercase
    upd = client.put(f"/clothes/{cid}", headers=auth,
                     data={"name": "Red JACKET"}).json()
    assert upd["name"] == "red jacket"  # updated lowercase
    # Legacy mixed-case names are lowered by the migration.
    with db.get_conn() as conn:
        conn.execute("UPDATE clothes SET name = 'MiXeD Case' WHERE id = ?", (cid,))
        db._migrate(conn)
        row = conn.execute("SELECT name FROM clothes WHERE id = ?", (cid,)).fetchone()
    assert row["name"] == "mixed case"


def test_search_matches_category_and_tags(client, auth):
    tee = create_cloth(client, auth, name="plain top", category="tshirt")
    client.put(f"/clothes/{tee['id']}", headers=auth,
               data={"tags": '["summer", "casual"]'})
    jeans = create_cloth(client, auth, name="blue bottoms", category="jeans")

    def ids(q):
        return {x["id"] for x in client.get(f"/clothes?search={q}", headers=auth).json()}

    assert tee["id"] in ids("tshirt")   # by category key
    assert tee["id"] in ids("summer")   # by tag
    assert jeans["id"] in ids("bottoms")  # by name still works
    assert jeans["id"] not in ids("tshirt")


def test_create_requires_two_images(client, auth):
    r = client.post("/clothes", headers=auth,
                    data={"name": "x", "category": "tshirt"},
                    files=[("images", ("f.png", make_png(), "image/png"))])
    assert r.status_code == 400


def test_update_metadata(client, auth):
    c = create_cloth(client, auth)
    r = client.put(f"/clothes/{c['id']}", headers=auth,
                   data={"name": "Renamed", "brand": "Acme", "cut": "slim",
                         "category": "shirt"})
    assert r.status_code == 200
    assert r.json()["name"] == "renamed"
    assert r.json()["brand"] == "ACME"  # brands normalised to uppercase


def test_add_replace_delete_images(client, auth):
    c = create_cloth(client, auth)
    cid = c["id"]
    front = next(i for i in c["images"] if i["role"] == "front")

    # replace front -> url changes, bg reset to pending
    r = client.put(f"/clothes/{cid}/images/{front['id']}", headers=auth,
                   files={"image": ("n.png", make_png((0, 200, 0)), "image/png")})
    assert r.status_code == 200
    new_front = next(i for i in r.json()["images"] if i["id"] == front["id"])
    assert new_front["original_url"] != front["original_url"]
    assert new_front["bg_accepted"] == "pending"

    # add extra
    r = client.post(f"/clothes/{cid}/images", headers=auth, data={"role": "extra"},
                    files={"image": ("x.png", make_png((10, 10, 10)), "image/png")})
    assert r.status_code == 200
    imgs = r.json()["images"]
    assert len(imgs) == 3
    extra = imgs[-1]
    assert extra["role"] == "extra"

    # delete extra ok
    assert client.delete(f"/clothes/{cid}/images/{extra['id']}", headers=auth).status_code == 200


def test_image_urls_are_cache_busted(client, auth):
    c = create_cloth(client, auth)
    img = c["images"][0]
    assert "?v=" in img["original_url"]
    assert "?v=" in img["cutout_url"]


def test_regenerated_cutout_changes_url(client, auth):
    # Regenerating the cut-out at the SAME filename (reject → accept) must still
    # change the URL so the app's image cache refreshes instead of showing a
    # stale picture — the reported "not updated until refresh" bug.
    import time
    c = create_cloth(client, auth)
    img = c["images"][0]

    def cutout():
        return client.get(f"/clothes/{c['id']}", headers=auth).json()["images"][0]["cutout_url"]

    url1 = cutout()
    client.post(f"/clothes/{c['id']}/images/{img['id']}/reject", headers=auth)
    time.sleep(0.01)
    client.post(f"/clothes/{c['id']}/images/{img['id']}/accept", headers=auth)
    url2 = cutout()  # canonical cut-out regenerated → new mtime → new ?v
    assert url1.split("?")[0] == url2.split("?")[0]  # same file path
    assert url1 != url2  # but a different cache-bust version


def test_front_back_cannot_be_deleted(client, auth):
    c = create_cloth(client, auth)
    for role in ("front", "back"):
        img = next(i for i in c["images"] if i["role"] == role)
        r = client.delete(f"/clothes/{c['id']}/images/{img['id']}", headers=auth)
        assert r.status_code == 400


def test_score_and_wear(client, auth):
    c = create_cloth(client, auth)
    assert client.patch(f"/clothes/{c['id']}/score", headers=auth,
                        json={"score": 4}).status_code == 200
    r = client.post(f"/clothes/{c['id']}/wear", headers=auth, json={"day": "2026-01-02"})
    assert r.status_code == 200
    assert r.json()["last_worn_at"] == "2026-01-02"
    got = client.get(f"/clothes/{c['id']}", headers=auth).json()
    assert got["score"] == 4
    assert got["last_worn_at"] == "2026-01-02"


def test_user_isolation(client, auth):
    mine = create_cloth(client, auth)
    other = client.post("/auth/signup",
                        json={"email": "z@z.co", "password": "pw123456"}).json()["token"]
    oh = {"Authorization": f"Bearer {other}"}
    assert client.get("/clothes", headers=oh).json() == []
    assert client.get(f"/clothes/{mine['id']}", headers=oh).status_code == 404


def test_delete_cloth(client, auth):
    c = create_cloth(client, auth)
    assert client.delete(f"/clothes/{c['id']}", headers=auth).status_code == 200
    assert client.get(f"/clothes/{c['id']}", headers=auth).status_code == 404
