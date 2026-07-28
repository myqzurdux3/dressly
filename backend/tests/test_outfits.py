from conftest import create_cloth, gen_outfit, make_png, wait_done


def _two_clothes(client, auth):
    a = create_cloth(client, auth, name="Tee", category="tshirt")
    b = create_cloth(client, auth, name="Jeans", category="jeans")
    return a, b


def _create_model(client, auth, name="Alex"):
    r = client.post(
        "/models",
        headers=auth,
        data={"name": name},
        files=[
            ("images", ("f.png", make_png((10, 10, 10)), "image/png")),
            ("images", ("b.png", make_png((20, 20, 20)), "image/png")),
        ],
    )
    assert r.status_code == 200, r.text
    return r.json()


def test_generate_is_async_then_done(client, auth):
    a, b = _two_clothes(client, auth)
    # POST returns immediately as 'processing'
    r = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [b["id"], a["id"]], "tier": "flux"})
    assert r.status_code == 200, r.text
    # the row is returned before the background render runs
    assert r.json()["status"] == "processing"
    assert r.json()["generated_url"] == ""
    # ...and completes when polled
    o = wait_done(client, auth, r.json()["id"])
    assert o["status"] == "done"
    assert o["is_mock"] is True
    assert o["generated_url"]
    # cloth order preserved as submitted
    assert [c["name"] for c in o["cloths"]] == ["jeans", "tee"]


def test_generate_requires_cloth(client, auth):
    assert client.post("/outfits/generate", headers=auth,
                       json={"cloth_ids": []}).status_code == 400


def test_favorite_toggle_and_list(client, auth):
    a, b = _two_clothes(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]]}).json()
    assert client.get("/outfits/favorites/list", headers=auth).json() == []
    r = client.post(f"/outfits/{o['id']}/favorite", headers=auth, json={})
    assert r.json()["is_favorite"] is True
    favs = client.get("/outfits/favorites/list", headers=auth).json()
    assert [x["id"] for x in favs] == [o["id"]]


def test_wear_outfit_stamps_clothes_and_logs_agenda(client, auth):
    a, b = _two_clothes(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"], b["id"]]}).json()
    r = client.post(f"/outfits/{o['id']}/wear", headers=auth, json={"day": "2026-03-03"})
    assert r.status_code == 200
    assert r.json()["clothes_marked"] == 2
    # both clothes stamped
    for cid in (a["id"], b["id"]):
        assert client.get(f"/clothes/{cid}", headers=auth).json()["last_worn_at"] == "2026-03-03"
    # agenda got a worn entry for that outfit
    ag = client.get("/agenda", headers=auth).json()
    entries = [e for e in ag if e["outfit_id"] == o["id"]]
    assert len(entries) == 1 and entries[0]["worn"] is True


def test_replace_clothes(client, auth):
    a, b = _two_clothes(client, auth)
    c = create_cloth(client, auth, name="Cap", category="hat")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]]}).json()
    r = client.post(f"/outfits/{o['id']}/replace-clothes", headers=auth,
                    json={"cloth_ids": [b["id"], c["id"]]})
    assert r.status_code == 200
    assert set(r.json()["cloth_ids"]) == {b["id"], c["id"]}


def test_replace_clothes_renders_newly_added_cloth(client, auth):
    # Regression: with a per-cloth render subset set (only 'a' shown), adding a
    # new cloth used to keep the stale subset, so the added cloth was dropped
    # from the render instead of appearing. Editing the list must render ALL of
    # the newly chosen clothes (subset reset to "all").
    a, b = _two_clothes(client, auth)
    c = create_cloth(client, auth, name="Cap", category="hat")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"], b["id"]]}).json()
    # Restrict the render to only 'a'.
    reg = client.post(f"/outfits/{o['id']}/regenerate", headers=auth,
                      json={"render_cloth_ids": [a["id"]]})
    assert reg.status_code == 200, reg.text
    assert reg.json()["render_cloth_ids"] == [a["id"]]
    # Now add 'c' by editing the cloth list.
    r = client.post(f"/outfits/{o['id']}/replace-clothes", headers=auth,
                    json={"cloth_ids": [a["id"], b["id"], c["id"]]})
    assert r.status_code == 200, r.text
    assert set(r.json()["cloth_ids"]) == {a["id"], b["id"], c["id"]}
    # Subset reset to "all" -> every cloth (including the new 'c') is rendered.
    assert r.json()["render_cloth_ids"] == []


def test_flux_formula_prompt_with_model(client, auth, monkeypatch):
    """With a model, the prompt uses the FLUX try-on formula and the model photo
    is image 1, the cloth collage image 2."""
    import routes_outfits
    captured = {}

    def fake_generate(prompt, image_paths, start_tier="flex", **kwargs):
        captured["prompt"] = prompt
        captured["paths"] = list(image_paths)
        from conftest import make_png as mp
        return mp(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake_generate)
    a, _ = _two_clothes(client, auth)
    m = _create_model(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]], "model_id": m["id"]}).json()
    wait_done(client, auth, o["id"])
    p = captured["prompt"].lower()
    assert "person of image 1" in p and "image 2" in p
    assert len(captured["paths"]) == 2  # model photo + collage


def test_replace_model_swaps_person(client, auth):
    a, _ = _two_clothes(client, auth)
    m = _create_model(client, auth)
    # Start as an outfit-only image (no model).
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]]}).json()
    assert o["model_id"] is None
    # Swap in a real person.
    r = client.post(f"/outfits/{o['id']}/replace-model", headers=auth,
                    json={"model_id": m["id"]})
    assert r.status_code == 200, r.text
    assert r.json()["model_id"] == m["id"]
    done = wait_done(client, auth, o["id"])
    assert done["status"] == "done"
    assert done["model_name"] == "Alex"
    # And drop the model again (back to outfit-only).
    r2 = client.post(f"/outfits/{o['id']}/replace-model", headers=auth,
                     json={"model_id": None})
    assert r2.status_code == 200
    assert r2.json()["model_id"] is None


def test_replace_model_rejects_foreign_model(client, auth):
    a, _ = _two_clothes(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]]}).json()
    r = client.post(f"/outfits/{o['id']}/replace-model", headers=auth,
                    json={"model_id": 99999})
    assert r.status_code == 404


def test_blacklist_prevents_regeneration(client, auth):
    a, b = _two_clothes(client, auth)  # the only top+bottom combo available
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"], b["id"]]}).json()
    wait_done(client, auth, o["id"])
    assert o["is_blacklisted"] is False

    r = client.post(f"/outfits/{o['id']}/blacklist", headers=auth, json={})
    assert r.status_code == 200 and r.json()["is_blacklisted"] is True
    assert client.get(f"/outfits/{o['id']}", headers=auth).json()["is_blacklisted"] is True

    # The random algorithm can only build {a, b} — now banned → nothing to make.
    r2 = client.post("/outfits/generate-from-algo", headers=auth,
                     json={"algo": "random"})
    assert r2.status_code == 404

    # Un-ban restores it.
    client.post(f"/outfits/{o['id']}/blacklist", headers=auth,
                json={"blacklisted": False})
    r3 = client.post("/outfits/generate-from-algo", headers=auth,
                     json={"algo": "random"})
    assert r3.status_code == 200


def test_failed_outfit_can_be_retried(client, auth, monkeypatch):
    """A generation failure leaves the outfit intact; a retry recovers it."""
    import routes_outfits
    from bfl import BflError
    calls = {"n": 0}

    def flaky(prompt, image_paths, start_tier="flex", **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise BflError("transient boom")
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", flaky)
    a, _ = _two_clothes(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]]}).json()
    failed = wait_done(client, auth, o["id"])
    assert failed["status"] == "failed"
    assert failed["cloth_ids"] == [a["id"]]  # clothes preserved

    r = client.post(f"/outfits/{o['id']}/regenerate", headers=auth,
                    json={"tier": failed["model_tier"]})
    assert r.status_code == 200
    recovered = wait_done(client, auth, o["id"])
    assert recovered["status"] == "done"


def test_outfit_sort_by_times_worn(client, auth):
    a, _ = _two_clothes(client, auth)
    o1 = client.post("/outfits/generate", headers=auth,
                     json={"cloth_ids": [a["id"]]}).json()
    o2 = client.post("/outfits/generate", headers=auth,
                     json={"cloth_ids": [a["id"]]}).json()
    wait_done(client, auth, o1["id"])
    wait_done(client, auth, o2["id"])
    # Wear o2 on two days → worn count 2; o1 stays 0.
    for day in ("2026-01-01", "2026-01-02"):
        client.post(f"/outfits/{o2['id']}/wear", headers=auth, json={"day": day})

    most = client.get("/outfits?sort=most_worn", headers=auth).json()
    assert most[0]["id"] == o2["id"]
    least = client.get("/outfits?sort=least_worn", headers=auth).json()
    assert least[0]["id"] == o1["id"]


def test_outfit_filter_by_favorite(client, auth):
    a, _ = _two_clothes(client, auth)
    o1 = client.post("/outfits/generate", headers=auth,
                     json={"cloth_ids": [a["id"]]}).json()
    client.post("/outfits/generate", headers=auth,
                json={"cloth_ids": [a["id"]]})
    client.post(f"/outfits/{o1['id']}/favorite", headers=auth, json={})
    favs = client.get("/outfits?favorite=true", headers=auth).json()
    assert [o["id"] for o in favs] == [o1["id"]]


def test_cloth_sort_by_times_worn(client, auth):
    a = create_cloth(client, auth, name="Tee", category="tshirt")
    b = create_cloth(client, auth, name="Jeans", category="jeans")
    o = gen_outfit(client, auth, [b["id"]])
    client.post(f"/outfits/{o['id']}/wear", headers=auth, json={"day": "2026-03-03"})
    worn = client.get("/clothes?sort=worn", headers=auth).json()
    assert worn[0]["id"] == b["id"]  # the worn cloth comes first


def test_outfit_wear_history(client, auth):
    a, _ = _two_clothes(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]]}).json()
    wait_done(client, auth, o["id"])
    assert client.get(f"/outfits/{o['id']}/wears", headers=auth).json()["total"] == 0
    for day in ("2026-02-02", "2026-02-03", "2026-02-03"):  # dup day dedup'd
        client.post(f"/outfits/{o['id']}/wear", headers=auth, json={"day": day})
    w = client.get(f"/outfits/{o['id']}/wears", headers=auth).json()
    assert w["total"] == 2
    assert w["days"] == ["2026-02-03", "2026-02-02"]  # newest first


def test_favorites_model_filter(client, auth):
    a, _ = _two_clothes(client, auth)
    m = _create_model(client, auth)
    o_no = client.post("/outfits/generate", headers=auth,
                       json={"cloth_ids": [a["id"]]}).json()
    o_yes = client.post("/outfits/generate", headers=auth,
                        json={"cloth_ids": [a["id"]], "model_id": m["id"]}).json()
    for o in (o_no, o_yes):
        client.post(f"/outfits/{o['id']}/favorite", headers=auth, json={})
    with_model = client.get("/outfits/favorites/list?model=with", headers=auth).json()
    assert [o["id"] for o in with_model] == [o_yes["id"]]
    none = client.get("/outfits/favorites/list?model=none", headers=auth).json()
    assert [o["id"] for o in none] == [o_no["id"]]


def test_delete_outfit(client, auth):
    a, _ = _two_clothes(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]]}).json()
    assert client.delete(f"/outfits/{o['id']}", headers=auth).status_code == 200
    assert client.get(f"/outfits/{o['id']}", headers=auth).status_code == 404


def _cloth_branded(client, auth, name, brand, category):
    r = client.post("/clothes", headers=auth,
                    data={"name": name, "brand": brand, "category": category,
                          "cut": "normal"},
                    files=[("images", ("f.png", make_png(), "image/png")),
                           ("images", ("b.png", make_png(), "image/png"))])
    return r.json()


def test_same_brand_algo_never_mixes_brands(client, auth):
    # Whichever brand the (weighted) pick lands on, the completion step must not
    # pull in a cloth of a different brand — the outfit is single-brand.
    _cloth_branded(client, auth, "Tee", "Nike", "tshirt")
    _cloth_branded(client, auth, "Hoodie", "Nike", "hoodie")
    _cloth_branded(client, auth, "Jeans", "Stussy", "jeans")
    for _ in range(8):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "same-brand", "count": 1})
        assert r.status_code == 200
        sel = r.json()["selections"][0]
        assert len({c["brand"] for c in sel}) == 1  # never mixes brands


def test_same_brand_weighted_by_wardrobe_share(client, auth):
    # 10 Nike items vs 1 Adidas — the weighted pick must favour Nike heavily
    # (proportional to how much of each you own), not a flat random.
    for i in range(5):
        _cloth_branded(client, auth, f"Nike Tee {i}", "Nike", "tshirt")
        _cloth_branded(client, auth, f"Nike Jean {i}", "Nike", "jeans")
    _cloth_branded(client, auth, "Adidas Tee", "Adidas", "tshirt")

    picks = []
    for _ in range(30):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "same-brand", "count": 1})
        assert r.status_code == 200
        sel = r.json()["selections"][0]
        assert len({c["brand"] for c in sel}) == 1  # never mixes
        picks.append(next(iter({c["brand"] for c in sel})))
    nike, adidas = picks.count("NIKE"), picks.count("ADIDAS")
    assert nike > adidas
    assert nike >= 2 * max(1, adidas)  # Nike (~91% weight) clearly dominates


def test_locked_cloth_forced_into_algo_selection(client, auth):
    # A hoodie is cold-only, so weather=hot filters it out of the pool. Locking
    # it must still put it in the outfit (winning its 'top' slot over the tee).
    _cloth_branded(client, auth, "Tee", "Nike", "tshirt")
    hoodie = _cloth_branded(client, auth, "Hoodie", "Nike", "hoodie")
    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "random", "weather": "hot", "count": 1,
                          "locked_cloth_ids": [hoodie["id"]]})
    assert r.status_code == 200
    sel = r.json()["selections"][0]
    assert hoodie["id"] in [c["id"] for c in sel]


def test_algos_list_includes_least_worn(client, auth):
    data = client.get("/outfits/algos/list", headers=auth).json()
    ids = [a["id"] for a in data["algos"]]
    assert "least-worn" in ids
    assert "least-worn" in data["algos_list"]


def test_preview_and_generate_from_algo(client, auth):
    _two_clothes(client, auth)
    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "random", "count": 1})
    assert r.status_code == 200
    assert len(r.json()["selections"]) >= 1

    r = client.post("/outfits/generate-from-algo", headers=auth,
                    json={"algo": "random", "tier": "flux"})
    assert r.status_code == 200
    o = wait_done(client, auth, r.json()["id"])
    assert o["status"] == "done"


def test_replace_clothes_on_back_view_updates_front(client, auth):
    # Editing clothes while viewing the BACK must also update the linked FRONT
    # (they are one outfit shown from two angles).
    m = _create_model(client, auth)
    a, b = _two_clothes(client, auth)
    c = create_cloth(client, auth, name="Cap", category="hat")
    front = gen_outfit(client, auth, [a["id"]], model_id=m["id"])
    r = client.post(f"/outfits/{front['id']}/back", headers=auth, json={})
    assert r.status_code == 200, r.text
    back = wait_done(client, auth, r.json()["id"])
    assert back["view"] == "back"
    rr = client.post(f"/outfits/{back['id']}/replace-clothes", headers=auth,
                     json={"cloth_ids": [b["id"], c["id"]]})
    assert rr.status_code == 200, rr.text
    wait_done(client, auth, back["id"])
    wait_done(client, auth, front["id"])
    f = client.get(f"/outfits/{front['id']}", headers=auth).json()
    bk = client.get(f"/outfits/{back['id']}", headers=auth).json()
    assert set(f["cloth_ids"]) == {b["id"], c["id"]}, f"front not updated: {f['cloth_ids']}"
    assert set(bk["cloth_ids"]) == {b["id"], c["id"]}, bk["cloth_ids"]
