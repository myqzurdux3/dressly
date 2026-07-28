from conftest import create_cloth, make_png


def _mk_model(client, auth, name, gender=""):
    r = client.post(
        "/models",
        headers=auth,
        data={"name": name, "gender": gender},
        files=[
            ("images", ("f.png", make_png(), "image/png")),
            ("images", ("b.png", make_png(), "image/png")),
        ],
    )
    assert r.status_code == 200, r.text
    return r.json()


# --- exclude clothes from generation algorithms -----------------------------

def test_exclude_from_algo_removes_from_pool(client, auth):
    keep = create_cloth(client, auth, name="Keep Tee", category="tshirt")
    excl = create_cloth(client, auth, name="Excl Tee", category="tshirt")
    create_cloth(client, auth, name="Jeans", category="jeans")

    r = client.post(f"/clothes/{excl['id']}/exclude-algo", headers=auth,
                    json={"exclude": True})
    assert r.status_code == 200 and r.json()["exclude_from_algo"] is True
    assert client.get(f"/clothes/{excl['id']}", headers=auth).json()["exclude_from_algo"] is True

    seen = set()
    for _ in range(15):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "random", "count": 1})
        for c in r.json()["selections"][0]:
            seen.add(c["id"])
    assert excl["id"] not in seen   # the excluded tee is never picked
    assert keep["id"] in seen       # the kept tee still is


def test_excluded_cloth_can_still_be_locked(client, auth):
    excl = create_cloth(client, auth, name="Excl Tee", category="tshirt")
    create_cloth(client, auth, name="Jeans", category="jeans")
    client.post(f"/clothes/{excl['id']}/exclude-algo", headers=auth,
                json={"exclude": True})
    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "random", "count": 1,
                          "locked_cloth_ids": [excl["id"]]})
    assert r.status_code == 200
    ids = {c["id"] for c in r.json()["selections"][0]}
    assert excl["id"] in ids  # a hand-locked excluded cloth stays in the outfit


def test_exclude_toggle_without_body_flips(client, auth):
    c = create_cloth(client, auth)
    r1 = client.post(f"/clothes/{c['id']}/exclude-algo", headers=auth, json={})
    assert r1.json()["exclude_from_algo"] is True
    r2 = client.post(f"/clothes/{c['id']}/exclude-algo", headers=auth, json={})
    assert r2.json()["exclude_from_algo"] is False


# --- model gender + random-by-gender ----------------------------------------

def test_model_gender_create_and_update(client, auth):
    m = _mk_model(client, auth, "Bob", gender="male")
    assert m["gender"] == "male"
    # Invalid gender is normalised to ''.
    m2 = _mk_model(client, auth, "X", gender="nope")
    assert m2["gender"] == ""
    upd = client.patch(f"/models/{m2['id']}", headers=auth,
                       json={"gender": "female"}).json()
    assert upd["gender"] == "female"


def test_random_model_gender_filter(client, auth):
    male = _mk_model(client, auth, "Bob", gender="male")
    _mk_model(client, auth, "Alice", gender="female")
    tee = create_cloth(client, auth, name="Tee", category="tshirt")

    seen = set()
    for _ in range(8):
        o = client.post("/outfits/generate", headers=auth,
                        json={"cloth_ids": [tee["id"]], "random_model": True,
                              "random_model_gender": "male"}).json()
        seen.add(o["model_id"])
    assert seen == {male["id"]}  # only the male model is ever picked


def test_brand_stored_uppercase_and_filter_case_insensitive(client, auth):
    r = client.post(
        "/clothes", headers=auth,
        data={"name": "Hoodie", "brand": "nike", "category": "hoodie"},
        files=[("images", ("f.png", make_png(), "image/png")),
               ("images", ("b.png", make_png(), "image/png"))])
    assert r.status_code == 200
    cid = r.json()["id"]
    assert r.json()["brand"] == "NIKE"  # lowercase input -> uppercase

    # Filtering by a lowercase brand still matches the uppercase-stored value.
    got = client.get("/clothes?brand=nike", headers=auth).json()
    assert cid in {x["id"] for x in got}

    # Updating with mixed case is normalised too.
    upd = client.put(f"/clothes/{cid}", headers=auth,
                     data={"brand": "AdIdAs"}).json()
    assert upd["brand"] == "ADIDAS"


def test_migrate_uppercases_legacy_brands(client, auth):
    import db
    c = create_cloth(client, auth, name="Tee", category="tshirt")
    # Simulate a legacy lower/mixed-case brand written before normalisation.
    with db.get_conn() as conn:
        conn.execute("UPDATE clothes SET brand = 'Levis' WHERE id = ?", (c["id"],))
        db._migrate(conn)
        row = conn.execute("SELECT brand FROM clothes WHERE id = ?",
                           (c["id"],)).fetchone()
    assert row["brand"] == "LEVIS"


def test_random_gender_falls_back_when_none_of_that_gender(client, auth):
    # Only a female model exists; asking for male still yields a person.
    female = _mk_model(client, auth, "Alice", gender="female")
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [tee["id"]], "random_model": True,
                          "random_model_gender": "male"}).json()
    assert o["model_id"] == female["id"]
