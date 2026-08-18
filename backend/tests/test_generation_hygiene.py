"""What happens around a render: temp files, budgets, and storage failures."""

import tempfile
from pathlib import Path

import bfl
import routes_outfits
from tests.conftest import create_cloth, gen_outfit, wait_done


def _tmp_collages():
    return set(Path(tempfile.gettempdir()).glob("*_collage.png"))


def _two_clothes(client, auth):
    a = create_cloth(client, auth, name="Tee", category="tshirt")
    b = create_cloth(client, auth, name="Jeans", category="jeans")
    return a, b


def test_generation_leaves_no_temp_collage_behind(client, auth):
    a, b = _two_clothes(client, auth)
    before = _tmp_collages()

    o = gen_outfit(client, auth, [a["id"], b["id"]])
    wait_done(client, auth, o["id"])

    leaked = _tmp_collages() - before
    assert not leaked, f"temp collages left in /tmp: {leaked}"


def test_a_storage_failure_fails_the_outfit_instead_of_hanging(
        client, auth, monkeypatch):
    a, b = _two_clothes(client, auth)

    real_write = Path.write_bytes

    def boom(self, data):
        if self.suffix == ".png" and self.parent.name == "outfits":
            raise OSError(28, "No space left on device")
        return real_write(self, data)

    monkeypatch.setattr(Path, "write_bytes", boom)

    o = gen_outfit(client, auth, [a["id"], b["id"]])
    row = wait_done(client, auth, o["id"])
    # The row must reach a terminal state; 'processing' forever is the bug.
    assert row["status"] == "failed", row["status"]
    assert "space" in (row.get("error") or "").lower()


def test_outfit_cascade_accepts_a_deadline():
    """generate_outfit must be able to stop starting new tiers, like generate."""
    import inspect

    sig = inspect.signature(bfl.generate_outfit)
    assert "deadline_s" in sig.parameters
    src = inspect.getsource(routes_outfits._run_generation)
    assert "deadline_s=GENERATE_DEADLINE_S" in src, (
        "the route must pass the budget, not just accept one"
    )
