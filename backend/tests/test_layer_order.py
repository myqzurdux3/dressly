"""Clothes are rendered in the order they are worn.

Reported: "quand je génère un outfit des fois ça affiche la veste en dessous du
t shirt".

Two causes, and both of them let the answer change from one render to the next:

  * the collage tiled the garments in whatever order the clothes had been
    picked, so nothing in the reference image said which one went on top;
  * the only layering sentence in the prompt — used in separate-image mode and
    nowhere else — asked for "a single visible top layer" and told the model
    not to stack garments, which is the opposite of a jacket over a t-shirt.

The order is now stated once, in generator.LAYER_ORDER, and everything that
shows or describes an outfit is built from it.
"""
import generator
from conftest import create_cloth, make_png, wait_done


def _capture(monkeypatch):
    """Intercept the render so the prompt and the input images can be read."""
    import routes_outfits
    cap = {}

    def fake(prompt, image_paths, start_tier="flex", **kwargs):
        cap["prompt"] = prompt
        cap["paths"] = list(image_paths)
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake)
    return cap


# --- the order itself -----------------------------------------------------

def test_the_stack_runs_from_skin_outwards():
    order = [generator.layer_of(c) for c in
             ("underwear", "socks", "jeans", "tshirt", "hoodie", "jacket")]
    assert order == sorted(order), order
    # A jacket is over a t-shirt; shoes are over socks and over the trouser hem.
    assert generator.layer_of("jacket") > generator.layer_of("tshirt")
    assert generator.layer_of("shoes") > generator.layer_of("socks")
    assert generator.layer_of("shoes") > generator.layer_of("jeans")
    # A hat is not underneath a coat.
    assert generator.layer_of("cap") > generator.layer_of("coat")


def test_an_unknown_category_hides_nothing_it_should_not():
    """A category nobody has classified must not silently land on top of the
    jacket, nor underneath the t-shirt."""
    unknown = generator.layer_of("kimono-thing")
    assert generator.layer_of("jacket") < unknown < generator.layer_of("shoes")


def test_sorting_is_stable_within_a_layer():
    """Two t-shirts keep the order the user picked them in — the rule decides
    between layers, not inside one."""
    items = [{"c": "tshirt", "n": 1}, {"c": "tshirt", "n": 2},
             {"c": "jacket", "n": 3}, {"c": "jeans", "n": 4}]
    got = [i["n"] for i in generator.layer_sorted(items, key=lambda i: i["c"])]
    assert got == [4, 1, 2, 3]


# --- what the model is told ----------------------------------------------

def test_the_prompt_names_the_layering_order(client, auth, monkeypatch):
    """The regression, stated directly: the jacket is named after the t-shirt
    and is the one that must stay visible."""
    cap = _capture(monkeypatch)
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    jacket = create_cloth(client, auth, name="Veste", category="jacket")
    jeans = create_cloth(client, auth, name="Jeans", category="jeans")

    # Submitted jacket-first, which is exactly how it used to end up underneath.
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [jacket["id"], tee["id"], jeans["id"]]}).json()
    wait_done(client, auth, o["id"])

    p = cap["prompt"].lower()
    assert "closest to the body first" in p, p
    assert p.index("tshirt") < p.index("jacket"), \
        f"the jacket is named before the t-shirt, i.e. underneath it: {p}"
    assert "single visible top layer" not in p, \
        "the prompt still asks for one layer, which is what hid the jacket"


def test_one_upper_garment_gets_no_layering_sentence(client, auth, monkeypatch):
    """Nothing can be layered wrongly, so nothing is said — the prompt does not
    grow a clause for every outfit."""
    cap = _capture(monkeypatch)
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    jeans = create_cloth(client, auth, name="Jeans", category="jeans")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [tee["id"], jeans["id"]]}).json()
    wait_done(client, auth, o["id"])
    assert "closest to the body first" not in cap["prompt"].lower()


def test_shoes_and_socks_do_not_trigger_the_clause(client, auth, monkeypatch):
    """Only the torso can be got wrong; a sentence about shoes over socks is
    noise in a prompt that is already long."""
    cap = _capture(monkeypatch)
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    socks = create_cloth(client, auth, name="Socks", category="socks")
    shoes = create_cloth(client, auth, name="Shoes", category="shoes")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [tee["id"], socks["id"], shoes["id"]]}).json()
    wait_done(client, auth, o["id"])
    assert "closest to the body first" not in cap["prompt"].lower()


def test_the_duplication_guard_survived_the_rewrite(client, auth, monkeypatch):
    """The old sentence was not all wrong: it also stopped the model rendering
    the same garment twice."""
    cap = _capture(monkeypatch)
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    jeans = create_cloth(client, auth, name="Jeans", category="jeans")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [tee["id"], jeans["id"]],
                          "image_mode": "separate"}).json()
    wait_done(client, auth, o["id"])
    # Positive phrasing on purpose — FLUX.2 ignores "do not X" (see
    # docs.bfl.ai/guides/prompting_guide_flux2), so the guard is stated as the
    # outcome instead.
    p = cap["prompt"].lower()
    assert "exactly once" in p, p
    assert "do not" not in p, f"a negative instruction FLUX.2 cannot act on: {p}"


# --- what the model is shown ---------------------------------------------

def test_separate_images_arrive_in_wearing_order(client, auth, monkeypatch):
    """Each image is described in the prompt by its number, so the images and
    the descriptions have to be ordered by the same rule."""
    cap = _capture(monkeypatch)
    tee = create_cloth(client, auth, name="Coton tee", category="tshirt")
    jacket = create_cloth(client, auth, name="Bomber", category="jacket")
    jeans = create_cloth(client, auth, name="Denim", category="jeans")

    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [jacket["id"], tee["id"], jeans["id"]],
                          "image_mode": "separate"}).json()
    wait_done(client, auth, o["id"])

    p = cap["prompt"].lower()
    # image 1 = jeans (bottom), image 2 = tee, image 3 = jacket.
    assert "image 1 is the denim" in p, p
    assert "image 2 is the coton tee" in p, p
    assert "image 3 is the bomber" in p, p


def test_the_stored_cloth_order_is_left_alone(client, auth, monkeypatch):
    """Only the render is reordered. The outfit still lists the clothes the way
    the user picked them, which is what the app shows back to them."""
    _capture(monkeypatch)
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    jacket = create_cloth(client, auth, name="Veste", category="jacket")
    submitted = [jacket["id"], tee["id"]]
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": submitted}).json()
    done = wait_done(client, auth, o["id"])
    assert done["cloth_ids"] == submitted
    assert [c["name"] for c in done["cloths"]] == ["veste", "tee"]


# --- where an added detail goes in the prompt -----------------------------
#
# "Word order matters — FLUX.2 pays more attention to what comes first", with
# the priority main subject -> key action -> critical style -> essential
# context -> secondary details (docs.bfl.ml/guides/prompting_guide_flux2).
# A detail typed on a regenerate is a secondary detail, and it was landing in
# front of the subject sentence.

def test_an_added_detail_follows_the_subject_instead_of_leading(
        client, auth, monkeypatch):
    cap = _capture(monkeypatch)
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [tee["id"]]}).json()
    wait_done(client, auth, o["id"])

    client.post(f"/outfits/{o['id']}/regenerate", headers=auth,
                json={"tier": "flex", "add_detail": "hands in pockets"})
    wait_done(client, auth, o["id"])

    p = cap["prompt"].lower()
    assert "hands in pockets" in p, p
    subject = p.index("full-body photo") if "full-body photo" in p else p.index("photo of")
    assert subject < p.index("hands in pockets"), \
        f"the detail is ahead of the subject sentence: {p}"


def test_the_detail_survives_a_plain_regenerate(client, auth, monkeypatch):
    """It is stored on the outfit, like the image mode and the render subset —
    not recovered from the prompt text, which the re-compose cuts at the
    generated markers."""
    cap = _capture(monkeypatch)
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [tee["id"]]}).json()
    wait_done(client, auth, o["id"])

    client.post(f"/outfits/{o['id']}/regenerate", headers=auth,
                json={"tier": "flex", "add_detail": "hands in pockets"})
    wait_done(client, auth, o["id"])
    client.post(f"/outfits/{o['id']}/regenerate", headers=auth, json={"tier": "flex"})
    wait_done(client, auth, o["id"])
    assert "hands in pockets" in cap["prompt"].lower()


def test_a_new_detail_replaces_the_old_one(client, auth, monkeypatch):
    """Otherwise every regenerate stacks another clause onto the prompt."""
    cap = _capture(monkeypatch)
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [tee["id"]]}).json()
    wait_done(client, auth, o["id"])

    for detail in ("hands in pockets", "arms crossed"):
        client.post(f"/outfits/{o['id']}/regenerate", headers=auth,
                    json={"tier": "flex", "add_detail": detail})
        wait_done(client, auth, o["id"])

    p = cap["prompt"].lower()
    assert "arms crossed" in p
    assert "hands in pockets" not in p, f"both details piled up: {p}"


def test_the_user_own_prompt_still_leads(client, auth, monkeypatch):
    """Their explicit text keeps the front position; only the auto-generated
    detail moved."""
    cap = _capture(monkeypatch)
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [tee["id"]],
                          "prompt": "golden hour on a rooftop"}).json()
    wait_done(client, auth, o["id"])
    assert cap["prompt"].lower().startswith("golden hour on a rooftop")
