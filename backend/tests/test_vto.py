"""FLUX Virtual Try-On (VTO) is prepended to the outfit cascade.

VTO needs a person + a garment, so it's only attempted when a model photo is
present; otherwise generation starts at flex. These tests cover the cascade
ordering and that the route feeds VTO the right person/garment inputs. Cloth
photo enhancement is unaffected (it keeps the flex -> pro -> max cascade).
"""
import bfl
from conftest import create_cloth, make_png, wait_done


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


# --- cascade ordering (pure) -------------------------------------------------

def test_cascade_full_order_from_flex():
    # Fresh model-based generation starts at flex and cascades flex->vto->pro->max.
    assert bfl._outfit_cascade("flex", can_vto=True) == ["flex", "vto", "pro", "max"]


def test_cascade_from_vto_when_upgrading():
    # Pressing "try a better model" from flex lands on vto, then pro, then max.
    assert bfl._outfit_cascade("vto", can_vto=True) == ["vto", "pro", "max"]


def test_cascade_skips_vto_without_person():
    assert bfl._outfit_cascade("flex", can_vto=False) == ["flex", "pro", "max"]
    # Even if asked for vto explicitly, no person => vto is dropped.
    assert "vto" not in bfl._outfit_cascade("vto", can_vto=False)


def test_cascade_explicit_high_tier_skips_lower():
    # Explicitly starting at pro skips flex + vto.
    assert bfl._outfit_cascade("pro", can_vto=True) == ["pro", "max"]


def test_next_outfit_tier_walks_flex_vto_pro_max():
    # The "try a better model" button walks flex -> vto -> pro -> max -> (none).
    assert bfl.next_outfit_tier("flex", can_vto=True) == "vto"
    assert bfl.next_outfit_tier("vto", can_vto=True) == "pro"
    assert bfl.next_outfit_tier("pro", can_vto=True) == "max"
    assert bfl.next_outfit_tier("max", can_vto=True) is None
    # Model-less outfits skip vto: flex -> pro -> max.
    assert bfl.next_outfit_tier("flex", can_vto=False) == "pro"


def test_next_tier_is_flux_only_for_enhancement():
    # Cloth-photo enhancement never touches try-on: flex -> pro -> max, no vto.
    assert bfl.next_tier("flex") == "pro"
    assert bfl.next_tier("pro") == "max"
    assert bfl.next_tier("max") is None
    assert bfl.next_tier("vto") is None


# --- route wiring ------------------------------------------------------------

def test_generation_with_model_feeds_person_and_garment(client, auth, monkeypatch):
    """A generation with a model starts at flex, and passes the model photo as
    the person + the cloth collage as the garment so the cascade can reach VTO.
    The "try a better model" button then offers VTO next."""
    import routes_outfits
    captured = {}

    def fake(prompt, image_paths, start_tier="flex", *, person_path=None,
             garment_path=None, **kwargs):
        captured["start_tier"] = start_tier
        captured["person"] = person_path
        captured["garment"] = garment_path
        captured["paths"] = list(image_paths)
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake)
    a, _ = _two_clothes(client, auth)
    m = _create_model(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]], "model_id": m["id"]}).json()
    done = wait_done(client, auth, o["id"])
    assert done["status"] == "done"
    assert done["model_tier"] == "flex"  # fresh renders start at flex
    # Person is image 1, garment collage is image 2 (available for the VTO step).
    assert captured["person"] == captured["paths"][0]
    assert captured["garment"] == captured["paths"][1]
    assert captured["start_tier"] == "flex"
    # From flex, the "try a better model" button offers VTO next.
    assert done["next_tier"] == "vto"


def test_generation_without_model_does_not_use_vto(client, auth, monkeypatch):
    """Outfit-only generation (no person) passes no VTO inputs, so the cascade
    starts at flex."""
    import routes_outfits
    captured = {}

    def fake(prompt, image_paths, start_tier="flex", *, person_path=None,
             garment_path=None, **kwargs):
        captured["person"] = person_path
        captured["garment"] = garment_path
        return make_png(), "flex", "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake)
    a, _ = _two_clothes(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]]}).json()
    wait_done(client, auth, o["id"])
    assert captured["person"] is None
    assert captured["garment"] is None


def test_high_quality_only_starts_at_pro_and_skips_flex_vto(client, auth, monkeypatch):
    """The 'high quality only' preference is expressed by the client sending
    tier='pro': generation renders pro -> max, skipping flex + vto. The button
    then only offers max."""
    import routes_outfits
    seen = {"tiers": []}

    def fake(prompt, image_paths, start_tier="flex", **kwargs):
        seen["tiers"].append(start_tier)
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake)
    a, _ = _two_clothes(client, auth)
    m = _create_model(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]], "model_id": m["id"],
                          "tier": "pro"}).json()
    o = wait_done(client, auth, o["id"])
    assert o["model_tier"] == "pro"
    assert o["next_tier"] == "max"  # only max left; no flex/vto
    # Press "try a better model" -> max, then no further step.
    client.post(f"/outfits/{o['id']}/regenerate", headers=auth, json={})
    o = wait_done(client, auth, o["id"])
    assert o["model_tier"] == "max"
    assert o["next_tier"] is None
    assert seen["tiers"] == ["pro", "max"]


def test_back_view_inherits_front_tier(client, auth, monkeypatch):
    """The back view renders at the same tier as the front (so an HQ pro front
    yields a pro back), not always flex."""
    import routes_outfits
    seen = {"tiers": []}

    def fake(prompt, image_paths, start_tier="flex", **kwargs):
        seen["tiers"].append(start_tier)
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake)
    a, _ = _two_clothes(client, auth)
    m = _create_model(client, auth)
    front = client.post("/outfits/generate", headers=auth,
                        json={"cloth_ids": [a["id"]], "model_id": m["id"],
                              "tier": "pro"}).json()
    front = wait_done(client, auth, front["id"])
    assert front["model_tier"] == "pro"

    back = client.post(f"/outfits/{front['id']}/back", headers=auth).json()
    back = wait_done(client, auth, back["id"])
    assert back["view"] == "back"
    assert back["model_tier"] == "pro"  # inherited from the front


def test_try_better_model_steps_flex_to_vto_to_pro_to_max(client, auth, monkeypatch):
    """A fresh model render starts at flex; pressing "try a better model" walks
    flex -> vto -> pro -> max, then stops."""
    import routes_outfits
    seen = {"tiers": []}

    def fake(prompt, image_paths, start_tier="flex", **kwargs):
        seen["tiers"].append(start_tier)
        # Echo the requested tier back as the tier used (no real cascade here).
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake)
    a, _ = _two_clothes(client, auth)
    m = _create_model(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]], "model_id": m["id"]}).json()
    o = wait_done(client, auth, o["id"])
    assert o["model_tier"] == "flex" and o["next_tier"] == "vto"

    # Press "try a better model" repeatedly (regenerate with no explicit tier
    # uses the server's next_outfit_tier).
    for expect_tier, expect_next in (("vto", "pro"), ("pro", "max"), ("max", None)):
        client.post(f"/outfits/{o['id']}/regenerate", headers=auth, json={})
        o = wait_done(client, auth, o["id"])
        assert o["model_tier"] == expect_tier
        assert o["next_tier"] == expect_next

    assert seen["tiers"] == ["flex", "vto", "pro", "max"]


def test_vto_submits_person_and_garment(monkeypatch, tmp_path):
    """generate_outfit posts person + garment (raw base64) to the VTO endpoint
    and returns the vto tier on success."""
    from PIL import Image
    person = tmp_path / "person.png"
    garment = tmp_path / "garment.png"
    Image.new("RGB", (32, 48), (200, 180, 160)).save(person)
    Image.new("RGB", (32, 48), (30, 60, 90)).save(garment)

    seen = {}

    def fake_post(slug, body):
        seen["slug"] = slug
        seen["body"] = body
        return {"id": "x", "polling_url": "http://poll"}

    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")
    monkeypatch.setattr(bfl, "_post_json", fake_post)
    monkeypatch.setattr(bfl, "_poll", lambda url, slug: "http://img")
    monkeypatch.setattr(bfl, "_download", lambda url: b"IMG")

    data, tier, slug = bfl.generate_outfit(
        "prompt", [str(person), str(garment)], start_tier="vto",
        person_path=str(person), garment_path=str(garment),
    )
    assert (data, tier, slug) == (b"IMG", "vto", bfl.BFL_MODEL_VTO)
    assert seen["slug"] == bfl.BFL_MODEL_VTO
    assert seen["body"]["person"] and seen["body"]["garment"]
    # Raw base64, not a data: URI (the VTO endpoint expects bare base64).
    assert not seen["body"]["person"].startswith("data:")
