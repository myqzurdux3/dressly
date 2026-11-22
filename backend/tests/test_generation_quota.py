"""Every paid render path must go through the per-user generation quota.

A render route that depends on get_current_user instead of generation_guard
lets an authenticated client loop it without limit — each call a billed BFL
render. (That happened once, on the since-removed /outfits/generate-from-algo.)
"""

import config
from tests.conftest import create_cloth


def _clothes(client, auth):
    top = create_cloth(client, auth, name="Tee", category="tshirt")
    bottom = create_cloth(client, auth, name="Jeans", category="jeans")
    return [top["id"], bottom["id"]]


def test_generate_is_quota_limited(client, auth, monkeypatch):
    ids = _clothes(client, auth)
    monkeypatch.setattr(config, "GENERATION_RATE_LIMIT", 1)

    first = client.post("/outfits/generate", headers=auth,
                        json={"cloth_ids": ids})
    second = client.post("/outfits/generate", headers=auth,
                         json={"cloth_ids": ids})
    assert first.status_code == 200
    assert second.status_code == 429


def test_every_paid_render_route_uses_the_guard():
    """Structural check: a new render endpoint added without the guard fails here."""
    import inspect
    import re

    import routes_outfits

    src = inspect.getsource(routes_outfits)
    paid = [
        "generate_outfit", "regenerate",
        "replace_clothes", "replace_model", "generate_back",
    ]
    for name in paid:
        m = re.search(rf"def {name}\((.*?)\):", src, re.S)
        assert m, f"{name} not found — rename the list in this test"
        assert "generation_guard" in m.group(1), (
            f"{name} bills a render but does not depend on generation_guard"
        )
