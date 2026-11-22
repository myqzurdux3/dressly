import base64

import bfl
import openrouter


def test_body_sends_references_and_nearest_ratio():
    body = openrouter.build_body("m/x", "p", ["data:a", "data:b"], 768, 1024)
    assert body["model"] == "m/x"
    assert body["aspect_ratio"] == "3:4"
    assert [r["image_url"]["url"] for r in body["input_references"]] == [
        "data:a", "data:b"]


def test_body_without_references_has_no_field():
    assert "input_references" not in openrouter.build_body("m", "p", [], 1, 1)


def test_reply_decodes_b64_and_cost():
    raw, cost = openrouter.parse_reply({
        "data": [{"b64_json": base64.b64encode(b"PNG").decode()}],
        "usage": {"cost": 0.04},
    })
    assert raw == b"PNG" and cost == 0.04


def test_reply_without_image_raises():
    try:
        openrouter.parse_reply({"data": []})
    except openrouter.OpenRouterError:
        return
    raise AssertionError("expected OpenRouterError")


def test_generate_tries_openrouter_first(monkeypatch, tmp_path):
    monkeypatch.setattr(bfl, "api_key", lambda: "k")
    monkeypatch.setattr(openrouter, "generate",
                        lambda *a, **k: (b"IMG", "g/m", 0.02))
    monkeypatch.setattr(openrouter, "model", lambda: "g/m")
    raw, tier, slug = bfl.generate("p", [], start_tier="openrouter")
    assert (raw, tier, slug) == (b"IMG", "openrouter", "openrouter:g/m")


def test_openrouter_failure_falls_back_to_bfl(monkeypatch):
    monkeypatch.setattr(bfl, "api_key", lambda: "k")

    def boom(*a, **k):
        raise openrouter.OpenRouterError("down")

    monkeypatch.setattr(openrouter, "generate", boom)
    monkeypatch.setattr(bfl, "_submit", lambda *a, **k: {"polling_url": "u"})
    monkeypatch.setattr(bfl, "_resolve_image_url", lambda *a, **k: "url")
    monkeypatch.setattr(bfl, "_download", lambda url: b"BFL")
    raw, tier, _ = bfl.generate("p", [], start_tier="openrouter")
    assert raw == b"BFL" and tier == "flex"


def test_better_model_after_openrouter_is_pro():
    assert bfl.next_outfit_tier("openrouter") == "pro"


def test_enhance_errors_never_show_server_paths():
    from routes_clothes import _short_reason
    missing = _short_reason(FileNotFoundError(2, "No such file", "/home/x/y.jpg"))
    assert "/home" not in missing and "missing" in missing
    msg = _short_reason(RuntimeError(
        "flex: HTTP 422 at /home/dressly/backend/data/a.jpg | pro: x"))
    assert "/home" not in msg and msg.startswith("flex: HTTP 422")
