from conftest import create_cloth


def _img(client, auth, cid, iid):
    return next(x for x in client.get(f"/clothes/{cid}", headers=auth).json()["images"]
               if x["id"] == iid)


def test_redo_bg_resets_to_pending_and_changes_cutout(client, auth):
    c = create_cloth(client, auth)
    cid, iid = c["id"], c["images"][0]["id"]
    client.post(f"/clothes/{cid}/images/{iid}/accept", headers=auth)
    assert _img(client, auth, cid, iid)["bg_accepted"] == "accepted"
    before = _img(client, auth, cid, iid)["cutout_url"]
    r = client.post(f"/clothes/{cid}/images/{iid}/redo-bg", headers=auth)
    assert r.status_code == 200
    after = _img(client, auth, cid, iid)
    assert after["bg_accepted"] == "pending"   # up for review again
    assert after["cutout_url"] != before       # fresh cut-out


def test_ai_enhance_tier_and_next(client, auth):
    import time
    c = create_cloth(client, auth)
    cid, iid = c["id"], c["images"][0]["id"]
    client.post(f"/clothes/{cid}/images/{iid}/enhance",
                headers=auth, json={"mode": "ai", "tier": "flex"})
    for _ in range(200):
        im = _img(client, auth, cid, iid)
        if im["enhance_status"] != "processing":
            break
        time.sleep(0.02)
    assert im["enhance_status"] == "ready"
    assert im["enhance_tier"] == "flex"
    assert im["enhance_next_tier"] == "pro"   # flex -> pro -> max

    # step up to pro — one tier left (max)
    client.post(f"/clothes/{cid}/images/{iid}/enhance",
                headers=auth, json={"mode": "ai", "tier": "pro"})
    for _ in range(200):
        im = _img(client, auth, cid, iid)
        if im["enhance_status"] != "processing":
            break
        time.sleep(0.02)
    assert im["enhance_tier"] == "pro"
    assert im["enhance_next_tier"] == "max"

    # step up to max — top tier, nothing above
    client.post(f"/clothes/{cid}/images/{iid}/enhance",
                headers=auth, json={"mode": "ai", "tier": "max"})
    for _ in range(200):
        im = _img(client, auth, cid, iid)
        if im["enhance_status"] != "processing":
            break
        time.sleep(0.02)
    assert im["enhance_tier"] == "max"
    assert im["enhance_next_tier"] is None     # top tier
