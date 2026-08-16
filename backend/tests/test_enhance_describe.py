"""Whether the owner's own words about a garment go into the AI prompt.

Naming the item helps the model edit the right thing and keep its design. But a
label is only as good as what somebody typed: a nickname, a tag that means
something only to its owner, a brand entered in the wrong field — all of those
are descriptions the model will dutifully try to honour. Hence a switch, and
hence it is remembered per image so a retry repeats the same job.
"""
import time

import db
import enhance
from conftest import create_cloth, make_png


def _garment(client, auth):
    """A garment with every user-entered field filled in."""
    import json

    r = client.post(
        "/clothes", headers=auth,
        data={"name": "Jogging noir", "brand": "Adidas", "category": "jogging",
              "cut": "slim", "tags": json.dumps(["sport", "hiver"]),
              "colors": json.dumps([{"color": "Black", "dominance": "full"}])},
        files=[("images", ("f.png", make_png(), "image/png")),
               ("images", ("b.png", make_png(), "image/png"))])
    assert r.status_code == 200, r.text
    return r.json()


def _capture_prompt(monkeypatch):
    seen = {}

    def fake_generate(prompt, paths, start_tier="flex", **kw):
        seen["prompt"] = prompt
        from PIL import Image
        import io
        buf = io.BytesIO()
        Image.new("RGB", (8, 8), (3, 3, 3)).save(buf, "JPEG")
        return buf.getvalue(), start_tier, "mock"

    monkeypatch.setattr("bfl.generate", fake_generate)
    return seen


def _run(client, auth, cloth, image_id, **body):
    r = client.post(f"/clothes/{cloth['id']}/images/{image_id}/enhance",
                    headers=auth, json={"mode": "ai", "tier": "flex", **body})
    assert r.status_code == 200, r.text
    for _ in range(200):
        got = _image(client, auth, cloth["id"], image_id)
        if got.get("enhance_status") != "processing":
            return got
        time.sleep(0.02)
    return got


def _image(client, auth, cloth_id, image_id):
    for im in client.get(f"/clothes/{cloth_id}", headers=auth).json()["images"]:
        if im["id"] == image_id:
            return im
    return {}


# --- the prompt itself ----------------------------------------------------

def test_describing_puts_everything_the_owner_typed_in_the_prompt(
        client, auth, monkeypatch):
    seen = _capture_prompt(monkeypatch)
    c = _garment(client, auth)
    _run(client, auth, c, c["images"][0]["id"], describe=True)

    p = seen["prompt"].lower()
    assert "jogging noir" in p, p      # the name they gave it
    assert "adidas" in p, p            # the brand
    assert "slim" in p, p              # the cut
    assert "black" in p, p             # the colour
    assert "sport" in p, p             # a tag


def test_not_describing_leaves_only_what_the_photo_shows(
        client, auth, monkeypatch):
    """The garment type and the side stay: they describe the PICTURE, not the
    owner's opinion of it, and dropping the side invents a design from the
    other one."""
    seen = _capture_prompt(monkeypatch)
    c = _garment(client, auth)
    _run(client, auth, c, c["images"][0]["id"], describe=False)

    p = seen["prompt"].lower()
    assert "jogging noir" not in p, p
    assert "adidas" not in p, p
    assert "sport" not in p, p
    assert "a jogging" in p, "the garment type was dropped too"
    assert "front of the garment" in p, "the side was dropped"


def test_describing_is_the_default(client, auth, monkeypatch):
    """What the prompt did before the switch existed — an image nobody has
    chosen for must not quietly change behaviour."""
    seen = _capture_prompt(monkeypatch)
    c = _garment(client, auth)
    _run(client, auth, c, c["images"][0]["id"])
    assert "adidas" in seen["prompt"].lower()


def test_a_garment_with_nothing_filled_in_still_reads_well(
        client, auth, monkeypatch):
    """No brand, no cut, no colours, no tags: the sentence must not grow empty
    brackets or stray semicolons."""
    seen = _capture_prompt(monkeypatch)
    c = create_cloth(client, auth, name="Tee", category="tshirt")
    _run(client, auth, c, c["images"][0]["id"], describe=True)
    p = seen["prompt"]
    assert "()" not in p and "( " not in p, p
    assert ";;" not in p and ", ," not in p, p


def test_only_the_first_few_colours_and_tags_are_named():
    """A garment tagged eight ways would otherwise bury the instruction."""
    prompt = enhance._ai_prompt(
        name="x", category="tshirt", role="front", describe=True,
        colors=["Black", "White", "Grey", "Red", "Blue"],
        tags=["a", "b", "c", "d", "e"])
    # Asserted on the description clause alone: the surrounding instruction
    # contains ordinary English that a substring search trips over ("centred"
    # contains "red").
    clause = prompt.split("(", 1)[1].split(")", 1)[0].lower()
    assert clause == "in black, white, grey; a, b, c", clause


# --- remembering the choice ----------------------------------------------

def test_the_choice_is_remembered_for_a_retry(client, auth, monkeypatch):
    """The retry buttons re-post the same job. A setting that reverted to the
    default on retry is one the user cannot trust."""
    seen = _capture_prompt(monkeypatch)
    c = _garment(client, auth)
    image_id = c["images"][0]["id"]

    _run(client, auth, c, image_id, describe=False)
    assert "adidas" not in seen["prompt"].lower()

    # A retry sends no `describe` at all — as the button does.
    _run(client, auth, c, image_id)
    assert "adidas" not in seen["prompt"].lower(), \
        "the retry reverted to describing"


def test_the_choice_can_be_flipped_back(client, auth, monkeypatch):
    seen = _capture_prompt(monkeypatch)
    c = _garment(client, auth)
    image_id = c["images"][0]["id"]
    _run(client, auth, c, image_id, describe=False)
    _run(client, auth, c, image_id, describe=True)
    assert "adidas" in seen["prompt"].lower()


def test_the_app_can_read_the_current_choice(client, auth):
    c = _garment(client, auth)
    image_id = c["images"][0]["id"]
    # Never chosen reads as the default rather than as null.
    assert _image(client, auth, c["id"], image_id)["enhance_describe"] is True

    client.post(f"/clothes/{c['id']}/images/{image_id}/enhance",
                headers=auth, json={"mode": "auto", "describe": False})
    assert _image(client, auth, c["id"], image_id)["enhance_describe"] is False


def test_the_choice_is_per_image_not_per_garment(client, auth):
    """The front and the back are enhanced separately and can disagree."""
    c = _garment(client, auth)
    front, back = c["images"][0]["id"], c["images"][1]["id"]
    client.post(f"/clothes/{c['id']}/images/{front}/enhance",
                headers=auth, json={"mode": "auto", "describe": False})
    assert _image(client, auth, c["id"], front)["enhance_describe"] is False
    assert _image(client, auth, c["id"], back)["enhance_describe"] is True


def test_the_deterministic_pass_ignores_it(client, auth):
    """'auto' never builds a prompt; the switch must not change what it does."""
    c = _garment(client, auth)
    image_id = c["images"][0]["id"]
    got = _run(client, auth, c, image_id, mode="auto", describe=False)
    assert got["enhance_status"] == "ready"


def test_a_row_that_predates_the_column_describes(client, auth):
    """NULL means nobody ever chose, which is the old behaviour."""
    c = _garment(client, auth)
    image_id = c["images"][0]["id"]
    with db.get_conn() as conn:
        conn.execute("UPDATE cloth_images SET enhance_describe = NULL "
                     "WHERE id = ?", (image_id,))
    assert _image(client, auth, c["id"], image_id)["enhance_describe"] is True


# --- setting the switch without paying for a render ----------------------

def test_ticking_the_box_does_not_start_an_enhancement(client, auth,
                                                       monkeypatch):
    """The user is setting up the next run, not asking for one. A checkbox that
    billed an API call would be a trap."""
    import routes_clothes

    def explode(*a, **kw):
        raise AssertionError("ticking the box started a render")

    monkeypatch.setattr(routes_clothes, "_run_enhance", explode)
    c = _garment(client, auth)
    image_id = c["images"][0]["id"]

    r = client.patch(f"/clothes/{c['id']}/images/{image_id}/enhance-describe",
                     headers=auth, json={"describe": False})
    assert r.status_code == 200, r.text
    got = [im for im in r.json()["images"] if im["id"] == image_id][0]
    assert got["enhance_describe"] is False
    assert got["enhance_status"] is None, "an enhancement was kicked off"


def test_the_saved_choice_is_what_the_next_run_uses(client, auth, monkeypatch):
    seen = _capture_prompt(monkeypatch)
    c = _garment(client, auth)
    image_id = c["images"][0]["id"]
    client.patch(f"/clothes/{c['id']}/images/{image_id}/enhance-describe",
                 headers=auth, json={"describe": False})
    _run(client, auth, c, image_id)          # no `describe` in the body
    assert "adidas" not in seen["prompt"].lower()


def test_another_users_image_cannot_be_toggled(client, auth):
    c = _garment(client, auth)
    other = client.post("/auth/signup",
                        json={"email": "d@d.co", "password": "pw123456"}).json()
    oh = {"Authorization": f"Bearer {other['token']}"}
    r = client.patch(
        f"/clothes/{c['id']}/images/{c['images'][0]['id']}/enhance-describe",
        headers=oh, json={"describe": False})
    assert r.status_code == 404


def test_an_unknown_image_is_a_404(client, auth):
    c = _garment(client, auth)
    r = client.patch(f"/clothes/{c['id']}/images/999999/enhance-describe",
                     headers=auth, json={"describe": False})
    assert r.status_code == 404
