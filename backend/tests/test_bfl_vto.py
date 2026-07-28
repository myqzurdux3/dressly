import bfl


def test_vto_body_requests_higher_quality(monkeypatch):
    # With prompt-upsampling enabled, the VTO submit asks the API for extra
    # detail and keeps lossless PNG output.
    monkeypatch.setattr(bfl, "BFL_VTO_PROMPT_UPSAMPLING", True)
    sent = {}
    monkeypatch.setattr(bfl, "_post_json", lambda slug, body: sent.update(body) or {"id": "x"})
    bfl._submit_vto("a person wearing the outfit", "PERSONB64", "GARMENTB64")
    assert sent["prompt_upsampling"] is True
    assert sent["output_format"] == "png"
    assert sent["person"] == "PERSONB64" and sent["garment"] == "GARMENTB64"


def test_vto_retries_without_quality_field_on_bad_request(monkeypatch):
    # If the slug rejects prompt_upsampling (400), we retry WITHOUT it instead of
    # failing — so the cascade doesn't silently skip try-on.
    monkeypatch.setattr(bfl, "BFL_VTO_PROMPT_UPSAMPLING", True)
    calls = []

    def fake_post(slug, body):
        calls.append(dict(body))
        if "prompt_upsampling" in body:
            raise bfl.BflError("vto: HTTP 400 unknown field prompt_upsampling")
        return {"id": "ok"}

    monkeypatch.setattr(bfl, "_post_json", fake_post)
    out = bfl._submit_vto("prompt", "P", "G")
    assert out == {"id": "ok"}
    assert len(calls) == 2
    assert "prompt_upsampling" in calls[0]        # first attempt asked for it
    assert "prompt_upsampling" not in calls[1]     # retry dropped it


def test_vto_non_400_error_is_not_retried(monkeypatch):
    # A non-bad-request failure (e.g. auth) must propagate, not silently retry.
    monkeypatch.setattr(bfl, "BFL_VTO_PROMPT_UPSAMPLING", True)
    calls = []

    def fake_post(slug, body):
        calls.append(dict(body))
        raise bfl.BflError("vto: HTTP 401 unauthorized")

    monkeypatch.setattr(bfl, "_post_json", fake_post)
    try:
        bfl._submit_vto("prompt", "P", "G")
        assert False, "expected BflError"
    except bfl.BflError:
        pass
    assert len(calls) == 1  # no retry on 401


def test_outfit_output_dims_portrait_by_default():
    # No model photo -> outfits are head-to-toe, so a portrait (not square) size.
    w, h = bfl._outfit_output_dims(None)
    assert h > w, f"expected portrait, got {w}x{h}"
    assert w % 32 == 0 and h % 32 == 0


def test_outfit_output_dims_matches_model_aspect(tmp_path):
    # A tall model photo -> a tall (portrait) render, never a squished square.
    from PIL import Image
    p = tmp_path / "model.png"
    Image.new("RGB", (600, 1000)).save(p)  # 3:5 portrait
    w, h = bfl._outfit_output_dims(str(p))
    assert h > w
    assert abs((w / h) - (600 / 1000)) < 0.06  # aspect preserved (± rounding)


def test_fit_dims_are_valid_flux_sizes():
    for ar in (3 / 4, 9 / 16, 1.0, 4 / 3):
        w, h = bfl._fit_dims(ar)
        assert w % 32 == 0 and h % 32 == 0
        assert 512 <= w <= 1536 and 512 <= h <= 1536
        assert 0.7e6 < w * h < 1.4e6  # ~1 MP budget
