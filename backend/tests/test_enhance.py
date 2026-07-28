import time

from conftest import create_cloth, make_png


def _img(client, auth, cloth_id, image_id):
    for x in client.get(f"/clothes/{cloth_id}", headers=auth).json()["images"]:
        if x["id"] == image_id:
            return x
    return None


def _wait_enhance(client, auth, cloth_id, image_id, tries=200):
    for _ in range(tries):
        im = _img(client, auth, cloth_id, image_id)
        if im and im["enhance_status"] in (None, "ready", "failed"):
            if im["enhance_status"] != "processing":
                return im
        time.sleep(0.02)
    return _img(client, auth, cloth_id, image_id)


def test_deterministic_enhance_accept(client, auth):
    c = create_cloth(client, auth)
    img = c["images"][0]
    r = client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                    headers=auth, json={"mode": "auto"})
    assert r.status_code == 200
    im = _wait_enhance(client, auth, c["id"], img["id"])
    assert im["enhance_status"] == "ready"
    assert im["enhanced_url"]

    assert im["enhance_method"] == "none"  # not applied until accepted
    old_original = img["original_url"]
    r = client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance/accept",
                    headers=auth)
    assert r.status_code == 200
    im2 = _img(client, auth, c["id"], img["id"])
    assert im2["enhance_status"] is None
    assert im2["enhanced_url"] == ""
    assert im2["original_url"] != old_original  # photo was replaced
    assert im2["bg_accepted"] == "pending"      # cutout re-review
    assert im2["enhance_method"] == "auto"      # method now recorded


def test_enhance_reject_keeps_original(client, auth):
    c = create_cloth(client, auth)
    img = c["images"][0]
    original = img["original_url"]
    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                headers=auth, json={"mode": "auto"})
    _wait_enhance(client, auth, c["id"], img["id"])
    r = client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance/reject",
                    headers=auth)
    assert r.status_code == 200
    im = _img(client, auth, c["id"], img["id"])
    assert im["enhance_status"] is None
    assert im["enhanced_url"] == ""
    assert im["original_url"] == original  # untouched


def test_ai_enhance_dry_run(client, auth):
    # No BFL key in tests → dry-run mock image, but the flow must still work.
    c = create_cloth(client, auth)
    img = c["images"][0]
    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                headers=auth, json={"mode": "ai"})
    im = _wait_enhance(client, auth, c["id"], img["id"])
    assert im["enhance_status"] == "ready"
    assert im["enhanced_url"]
    assert im["enhance_pending_method"] == "ai"
    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance/accept", headers=auth)
    assert _img(client, auth, c["id"], img["id"])["enhance_method"] == "ai"


def test_replace_resets_enhance_method(client, auth):
    from conftest import make_png
    c = create_cloth(client, auth)
    img = c["images"][0]
    # enhance + accept → method 'auto'
    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                headers=auth, json={"mode": "auto"})
    _wait_enhance(client, auth, c["id"], img["id"])
    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance/accept", headers=auth)
    assert _img(client, auth, c["id"], img["id"])["enhance_method"] == "auto"
    # replacing the photo resets it to 'none'
    client.put(f"/clothes/{c['id']}/images/{img['id']}", headers=auth,
               files={"image": ("n.png", make_png((1, 2, 3)), "image/png")})
    assert _img(client, auth, c["id"], img["id"])["enhance_method"] == "none"


def test_reenhance_changes_url(client, auth):
    # Re-running enhancement must yield a new URL so the client never shows a
    # stale cached image.
    c = create_cloth(client, auth)
    img = c["images"][0]
    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                headers=auth, json={"mode": "auto"})
    im1 = _wait_enhance(client, auth, c["id"], img["id"])
    url1 = im1["enhanced_url"]
    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                headers=auth, json={"mode": "auto"})
    im2 = _wait_enhance(client, auth, c["id"], img["id"])
    assert im2["enhanced_url"] and im2["enhanced_url"] != url1


def test_enhance_uses_the_kept_image_as_source(client, auth, monkeypatch):
    """The upgrader must run on the image the user kept: the cut-out when they
    kept the cropped one, or the original when they kept the original."""
    import db
    import enhance
    from PIL import Image

    captured = {}

    def fake_det(src, cutout, dst):
        captured["src"] = src
        Image.new("RGB", (8, 8), (2, 2, 2)).save(dst, "JPEG")
        return dst

    monkeypatch.setattr(enhance, "enhance_deterministic", fake_det)

    c = create_cloth(client, auth)
    cid, iid = c["id"], c["images"][0]["id"]

    # Keep the cut-out ("the cropped one").
    client.post(f"/clothes/{cid}/images/{iid}/accept", headers=auth)
    with db.get_conn() as conn:
        cutout = conn.execute(
            "SELECT cutout_path FROM cloth_images WHERE id = ?", (iid,)
        ).fetchone()["cutout_path"]
    client.post(f"/clothes/{cid}/images/{iid}/enhance", headers=auth, json={"mode": "auto"})
    _wait_enhance(client, auth, cid, iid)
    assert captured["src"] == cutout  # not the uncropped original

    # Keep the original instead.
    client.post(f"/clothes/{cid}/images/{iid}/reject", headers=auth)
    with db.get_conn() as conn:
        original = conn.execute(
            "SELECT original_path FROM cloth_images WHERE id = ?", (iid,)
        ).fetchone()["original_path"]
    client.post(f"/clothes/{cid}/images/{iid}/enhance", headers=auth, json={"mode": "auto"})
    _wait_enhance(client, auth, cid, iid)
    assert captured["src"] == original


def test_ai_enhance_prompt_includes_item_context(client, auth, monkeypatch):
    """The AI enhance prompt mentions the garment type, the user's name and the
    side (front/back) so the model edits the right item."""
    import bfl
    captured = {}

    def fake_generate(prompt, paths, start_tier="flex", **kw):
        captured["prompt"] = prompt
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(bfl, "generate", fake_generate)

    r = client.post(
        "/clothes", headers=auth,
        data={"name": "Cozy Hoodie", "category": "hoodie"},
        files=[("images", ("f.png", make_png(), "image/png")),
               ("images", ("b.png", make_png(), "image/png"))])
    c = r.json()
    back = next(i for i in c["images"] if i["role"] == "back")
    client.post(f"/clothes/{c['id']}/images/{back['id']}/enhance",
                headers=auth, json={"mode": "ai"})
    _wait_enhance(client, auth, c["id"], back["id"])

    p = captured["prompt"].lower()
    assert "hoodie" in p          # garment type
    assert "cozy hoodie" in p     # user-given name (stored lowercase)
    assert "back" in p            # this image is the back side


def test_accept_without_candidate_400(client, auth):
    c = create_cloth(client, auth)
    img = c["images"][0]
    r = client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance/accept",
                    headers=auth)
    assert r.status_code == 400
