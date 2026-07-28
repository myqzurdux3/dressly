import json

import db
from conftest import create_cloth, gen_outfit, wait_done


def test_cloth_favorite_toggle_and_filter(client, auth):
    a = create_cloth(client, auth, name="Fav")
    create_cloth(client, auth, name="Plain")
    assert client.get(f"/clothes/{a['id']}", headers=auth).json()["is_favorite"] is False
    r = client.post(f"/clothes/{a['id']}/favorite", headers=auth, json={})
    assert r.json()["is_favorite"] is True
    favs = client.get("/clothes?favorite=true", headers=auth).json()
    assert [c["name"] for c in favs] == ["fav"]


def test_cloth_wear_history_and_count(client, auth):
    from datetime import date
    y = date.today().year
    a = create_cloth(client, auth)
    client.post(f"/clothes/{a['id']}/wear", headers=auth, json={"day": f"{y}-02-02"})
    client.post(f"/clothes/{a['id']}/wear", headers=auth, json={"day": f"{y}-02-02"})  # dedup
    client.post(f"/clothes/{a['id']}/wear", headers=auth, json={"day": f"{y-1}-12-31"})
    w = client.get(f"/clothes/{a['id']}/wears", headers=auth).json()
    assert w["total"] == 2               # deduped same-day
    assert w["days"] == [f"{y}-02-02", f"{y-1}-12-31"]
    assert w["this_year"] == 1           # only the current-year one


def test_outfit_wear_marks_clothes_and_worn_today(client, auth):
    a = create_cloth(client, auth)
    o = gen_outfit(client, auth, [a["id"]])
    assert o["worn_today"] is False
    client.post(f"/outfits/{o['id']}/wear", headers=auth, json={})  # today
    got = client.get(f"/outfits/{o['id']}", headers=auth).json()
    assert got["worn_today"] is True
    # cloth stamped + recorded
    assert client.get(f"/clothes/{a['id']}", headers=auth).json()["last_worn_at"] is not None
    assert client.get(f"/clothes/{a['id']}/wears", headers=auth).json()["total"] == 1


def test_random_person_prompt_added_without_models(client, auth):
    a = create_cloth(client, auth)
    r = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]], "random_model": True})
    o = wait_done(client, auth, r.json()["id"])
    assert "person" in o["prompt"].lower()


def test_linked_back_excluded_from_history(client, auth):
    a = create_cloth(client, auth)
    front = gen_outfit(client, auth, [a["id"]])
    # simulate a linked back view directly (generate_back needs a model+back photo)
    with db.get_conn() as conn:
        uid = conn.execute("SELECT id FROM users LIMIT 1").fetchone()["id"]
        back_id = conn.execute(
            "INSERT INTO outfits (user_id, cloth_ids, model_tier, view, status, linked_id) "
            "VALUES (?, ?, 'flux', 'back', 'done', ?)",
            (uid, json.dumps([a["id"]]), front["id"]),
        ).lastrowid
        conn.execute("UPDATE outfits SET linked_id = ? WHERE id = ?",
                     (back_id, front["id"]))
    ids = [o["id"] for o in client.get("/outfits", headers=auth).json()]
    assert front["id"] in ids
    assert back_id not in ids  # back is reached via the front, not listed separately
    # the front exposes its linked back
    assert client.get(f"/outfits/{front['id']}", headers=auth).json()["linked_id"] == back_id


def test_report_image_creates_notification(client, auth):
    c = create_cloth(client, auth)
    r = client.post(f"/clothes/{c['id']}/images/{c['images'][0]['id']}/report",
                    headers=auth, json={"message": "edge is cut"})
    assert r.status_code == 200
    with db.get_conn() as conn:
        n = conn.execute("SELECT COUNT(*) FROM notifications WHERE cloth_id = ?",
                         (c["id"],)).fetchone()[0]
    assert n == 1
