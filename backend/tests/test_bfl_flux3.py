"""FLUX 3 Image takes its references as one `images` array; FLUX.2 as
input_image, input_image_2, ... Sending one shape to the other family is a
request the endpoint has no field for."""
import bfl


def _capture(monkeypatch):
    sent = {}

    def fake_post(slug, body):
        sent["slug"] = slug
        sent["body"] = body
        return {"id": "x", "polling_url": "https://example/poll"}

    monkeypatch.setattr(bfl, "_post_json", fake_post)
    monkeypatch.setattr(bfl, "_record_usage", lambda *a, **k: None)
    return sent


def test_flux3_sends_one_images_array(monkeypatch):
    sent = _capture(monkeypatch)
    uris = [f"data:image/jpeg;base64,{i}" for i in range(12)]
    bfl._submit("flux-3-image", "p", uris, width=768, height=1024)
    body = sent["body"]
    assert body["images"] == uris[:10]  # the documented cap
    assert not any(k.startswith("input_image") for k in body)
    assert body["grounding"] is False
    assert (body["width"], body["height"]) == (768, 1024)


def test_flux3_without_references_sends_no_images(monkeypatch):
    sent = _capture(monkeypatch)
    bfl._submit("flux-3-image-klein", "p", [], width=768, height=1024)
    assert "images" not in sent["body"]


def test_flux2_keeps_numbered_fields(monkeypatch):
    sent = _capture(monkeypatch)
    uris = ["a", "b", "c"]
    bfl._submit("flux-2-max", "p", uris, width=768, height=1024)
    body = sent["body"]
    assert body["input_image"] == "a"
    assert body["input_image_3"] == "c"
    assert "images" not in body and "grounding" not in body


def test_caps():
    assert bfl.max_images_for("flux-3-image") == 10
    assert bfl.max_images_for("flux-3-image-klein") == 10
    assert bfl.max_images_for("flux-2-klein-4b") == 4
