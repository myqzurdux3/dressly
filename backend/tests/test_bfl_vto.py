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


# --- how many reference images each model actually takes ------------------
#
# Found by reading the endpoints' own OpenAPI schemas after the FLUX MCP was
# connected: the klein models expose input_image .. input_image_4, pro/max/flex
# expose eight. The app's cheapest tier is configured as flux-2-klein-4b, and
# the code was sending it up to eight — fields that endpoint does not have.

def test_the_klein_models_take_four_references():
    assert bfl.max_images_for("flux-2-klein-4b") == 4
    assert bfl.max_images_for("flux-2-klein-9b") == 4


def test_pro_max_and_flex_take_eight():
    assert bfl.max_images_for("flux-2-pro") == 8
    assert bfl.max_images_for("flux-2-max") == 8
    assert bfl.max_images_for("flux-2-flex") == 8


def test_an_unknown_slug_assumes_the_smaller_cap():
    """Too few reference images is a poorer picture; too many is a rejected
    request. The safe guess is the small one."""
    assert bfl.max_images_for("flux-9-something-new") == 4
    assert bfl.max_images_for("") == 4


def test_the_caps_follow_the_configured_slugs():
    """Re-pointing a tier at another model in the environment must move its cap
    with it, which keying on the tier NAME could never do."""
    assert bfl.TIER_MAX_IMAGES["flex"] == bfl.max_images_for(bfl.TIER_SLUGS["flex"])
    assert bfl.TIER_MAX_IMAGES["max"] == bfl.max_images_for(bfl.TIER_SLUGS["max"])


def test_a_submit_never_exceeds_the_models_slots(monkeypatch):
    """The regression: nine references went to a four-slot endpoint."""
    sent = {}
    monkeypatch.setattr(bfl, "_post_json", lambda slug, body: sent.update(body) or {})
    bfl._submit("flux-2-klein-4b", "prompt", [f"uri{i}" for i in range(9)],
                width=1024, height=1024)
    slots = [k for k in sent if k.startswith("input_image")]
    assert len(slots) == 4, sorted(slots)
    assert "input_image_5" not in sent

    sent.clear()
    bfl._submit("flux-2-pro", "prompt", [f"uri{i}" for i in range(9)],
                width=1024, height=1024)
    slots = [k for k in sent if k.startswith("input_image")]
    assert len(slots) == 8, sorted(slots)


def test_try_on_is_not_filed_under_the_cheap_tier():
    """VTO is a tool, not a FLUX tier, so it is absent from TIER_SLUGS — and the
    fallback filed it under 'flex'. That put try-on spend on the cheapest tier's
    line, which is the very number you would read to judge try-on's cost."""
    import config

    assert bfl.slug_to_tier(config.BFL_MODEL_VTO) == bfl.VTO_TIER
    assert bfl.slug_to_tier(config.BFL_MODEL_FLEX) == "flex"
    assert bfl.slug_to_tier("something-unknown") == "flex"


def test_the_try_on_endpoint_is_v2():
    """v2 has the same request shape as v1 and renders up to 4 MP instead of ~1.
    https://docs.bfl.ml/api-reference/models/virtual-try-on-v2"""
    import config

    assert config.BFL_MODEL_VTO == "flux-tools/vto-v2"


def test_prompt_upsampling_is_not_sent_by_default(monkeypatch):
    """Neither VTO version has that field — both take Flux2KleinTryonInputs
    (prompt / person / garment / seed / safety_tolerance / output_format /
    webhook_*). Sending it meant every try-on submitted twice: once refused for
    an unknown field, once accepted."""
    import config

    assert config.BFL_VTO_PROMPT_UPSAMPLING is False

    calls = []
    monkeypatch.setattr(bfl, "BFL_VTO_PROMPT_UPSAMPLING", False)
    monkeypatch.setattr(bfl, "_post_json",
                        lambda slug, body: calls.append(dict(body)) or {"id": "x"})
    bfl._submit_vto("prompt", "PERSON", "GARMENT")
    assert len(calls) == 1, f"{len(calls)} submits for one try-on"
    assert "prompt_upsampling" not in calls[0]
    # The fields the schema does define are all still there.
    assert calls[0]["person"] == "PERSON" and calls[0]["garment"] == "GARMENT"


def test_the_moderation_dial_is_actually_sent(monkeypatch):
    """It was never in the body, so every call used the provider's default with
    no way to loosen it — and a refused garment photo had no lever at all."""
    import config

    sent = {}
    monkeypatch.setattr(bfl, "_post_json", lambda slug, body: sent.update(body) or {})
    bfl._submit("flux-2-klein-4b", "p", ["uri"], width=1024, height=1024)
    assert sent["safety_tolerance"] == config.BFL_SAFETY_TOLERANCE

    sent.clear()
    bfl._submit_vto("p", "PERSON", "GARMENT")
    assert sent["safety_tolerance"] == config.BFL_SAFETY_TOLERANCE


def test_the_dial_stays_inside_the_documented_range():
    """0..5 "for public use" per their schema; anything else is a 422."""
    import config

    assert 0 <= config.BFL_SAFETY_TOLERANCE <= 5
