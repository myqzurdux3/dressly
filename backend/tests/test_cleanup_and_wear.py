"""Files that outlive what they belong to, and wear dates that go backwards."""
import asyncio

from conftest import create_cloth, gen_outfit, make_png
from db import get_conn


# --- outfit delete --------------------------------------------------------

def test_deleting_an_outfit_drops_both_versions(client, auth):
    from config import OUTFITS_DIR

    c = create_cloth(client, auth)
    o = gen_outfit(client, auth, [c["id"]])
    ai = OUTFITS_DIR / f"{o['id']}_ai_test.png"
    manual = OUTFITS_DIR / f"{o['id']}_manual.png"
    ai.write_bytes(make_png())
    manual.write_bytes(make_png())
    with get_conn() as conn:
        conn.execute("UPDATE outfits SET generated_path = ?, ai_path = ?, "
                     "manual_path = ? WHERE id = ?",
                     (str(manual), str(ai), str(manual), o["id"]))
    r = client.delete(f"/outfits/{o['id']}", headers=auth)
    assert r.status_code == 200
    assert not ai.exists()
    assert not manual.exists()


def test_deleting_an_outfit_with_missing_files_is_fine(client, auth):
    from config import OUTFITS_DIR

    c = create_cloth(client, auth)
    o = gen_outfit(client, auth, [c["id"]])
    with get_conn() as conn:
        conn.execute("UPDATE outfits SET ai_path = ? WHERE id = ?",
                     (str(OUTFITS_DIR / "gone.png"), o["id"]))
    assert client.delete(f"/outfits/{o['id']}", headers=auth).status_code == 200


# --- garment delete -------------------------------------------------------

def test_deleting_a_cloth_purges_its_thumbnails(client, auth):
    from config import THUMBS_DIR

    c = create_cloth(client, auth)
    stale = THUMBS_DIR / "400" / "images" / str(c["id"]) / "x_cutout.webp.webp"
    stale.parent.mkdir(parents=True, exist_ok=True)
    stale.write_bytes(b"x")
    other = THUMBS_DIR / "400" / "images" / f"{c['id']}0" / "keep.webp"
    other.parent.mkdir(parents=True, exist_ok=True)
    other.write_bytes(b"x")
    assert client.delete(f"/clothes/{c['id']}", headers=auth).status_code == 200
    assert not stale.parent.exists()
    assert other.exists()  # another garment's folder is left alone


def test_startup_reclaims_orphan_blobs(monkeypatch, tmp_path):
    import apiusage
    import images
    import main

    monkeypatch.setattr(images, "warm_model", lambda: None)
    monkeypatch.setattr(apiusage, "install", lambda: None)
    stored = images.save_original(make_png((1, 2, 3)), tmp_path / "doomed")
    blob = images.BLOBS_DIR / next(
        p.relative_to(images.BLOBS_DIR) for p in images.BLOBS_DIR.rglob("*")
        if p.is_file() and p.stat().st_ino == stored.stat().st_ino)
    stored.unlink()

    async def boot():
        async with main.lifespan(main.app):
            pass

    asyncio.run(boot())
    assert not blob.exists()


# --- wear dates -----------------------------------------------------------

def _last_worn(client, auth, cloth_id):
    return client.get(f"/clothes/{cloth_id}", headers=auth).json()["last_worn_at"]


def test_logging_an_older_wear_keeps_the_latest_day(client, auth):
    c = create_cloth(client, auth)
    o = gen_outfit(client, auth, [c["id"]])
    client.post(f"/outfits/{o['id']}/wear", headers=auth, json={"day": "2026-07-20"})
    client.post(f"/outfits/{o['id']}/wear", headers=auth, json={"day": "2026-07-01"})
    assert _last_worn(client, auth, c["id"]) == "2026-07-20"


def test_wearing_a_cloth_on_an_older_day_keeps_the_latest_day(client, auth):
    c = create_cloth(client, auth)
    client.post(f"/clothes/{c['id']}/wear", headers=auth, json={"day": "2026-07-20"})
    client.post(f"/clothes/{c['id']}/wear", headers=auth, json={"day": "2026-07-01"})
    assert _last_worn(client, auth, c["id"]) == "2026-07-20"


def _wears(cloth_id):
    with get_conn() as conn:
        return [r["day"] for r in conn.execute(
            "SELECT day FROM cloth_wears WHERE cloth_id = ? ORDER BY day",
            (cloth_id,))]


def _entry(client, auth, day, outfit_id):
    r = client.post("/agenda", headers=auth, json={"day": day, "outfit_id": outfit_id})
    assert r.status_code == 200, r.text
    return r.json()["id"]


def test_unconfirming_an_agenda_entry_takes_the_wear_back(client, auth):
    c = create_cloth(client, auth)
    o = gen_outfit(client, auth, [c["id"]])
    early = _entry(client, auth, "2026-07-01", o["id"])
    late = _entry(client, auth, "2026-07-20", o["id"])
    client.post(f"/agenda/{early}/worn", headers=auth, json={})
    client.post(f"/agenda/{late}/worn", headers=auth, json={})
    assert _wears(c["id"]) == ["2026-07-01", "2026-07-20"]

    r = client.post(f"/agenda/{late}/worn", headers=auth, json={"worn": False})
    assert r.status_code == 200
    assert _wears(c["id"]) == ["2026-07-01"]
    assert _last_worn(client, auth, c["id"]) == "2026-07-01"

    client.post(f"/agenda/{early}/worn", headers=auth, json={"worn": False})
    assert _wears(c["id"]) == []
    assert _last_worn(client, auth, c["id"]) is None


def test_unconfirming_keeps_a_wear_another_entry_still_covers(client, auth):
    a = create_cloth(client, auth, name="Tee")
    b = create_cloth(client, auth, name="Jean", category="jeans")
    o1 = gen_outfit(client, auth, [a["id"], b["id"]])
    o2 = gen_outfit(client, auth, [a["id"]])
    e1 = _entry(client, auth, "2026-07-20", o1["id"])
    e2 = _entry(client, auth, "2026-07-20", o2["id"])
    client.post(f"/agenda/{e1}/worn", headers=auth, json={})
    client.post(f"/agenda/{e2}/worn", headers=auth, json={})

    client.post(f"/agenda/{e1}/worn", headers=auth, json={"worn": False})
    assert _wears(a["id"]) == ["2026-07-20"]   # still worn through o2
    assert _wears(b["id"]) == []
