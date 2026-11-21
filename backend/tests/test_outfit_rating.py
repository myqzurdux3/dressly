import json

import db
import generator
from conftest import create_cloth, make_png


def _manual(client, auth, ids):
    layout = json.dumps({"background": {"type": "solid", "color": "#FFFFFF"},
                         "items": []})
    r = client.post(
        "/outfits/manual", headers=auth,
        data={"cloth_ids": json.dumps(ids), "layout": layout},
        files=[("image", ("c.png", make_png((255, 255, 255)), "image/png"))])
    assert r.status_code == 200, r.text
    return r.json()


def test_rate_an_outfit_and_sort_by_rating(client, auth):
    a = create_cloth(client, auth, name="Tee", category="tshirt")
    b = create_cloth(client, auth, name="Jeans", category="jeans")
    c = create_cloth(client, auth, name="Shorts", category="shorts")
    o1 = _manual(client, auth, [a["id"], b["id"]])
    o2 = _manual(client, auth, [a["id"], c["id"]])
    assert o1["rating"] == 0
    r = client.post(f"/outfits/{o1['id']}/rating", headers=auth, json={"rating": 5})
    assert r.status_code == 200 and r.json()["rating"] == 5
    client.post(f"/outfits/{o2['id']}/rating", headers=auth, json={"rating": 2})
    got = client.get(f"/outfits/{o1['id']}", headers=auth).json()
    assert got["rating"] == 5
    order = [o["id"] for o in client.get(
        "/outfits?sort=best_rated", headers=auth).json()]
    assert order.index(o1["id"]) < order.index(o2["id"])
    assert client.post(f"/outfits/{o1['id']}/rating", headers=auth,
                       json={"rating": 6}).status_code == 422
    assert client.post("/outfits/99999/rating", headers=auth,
                       json={"rating": 3}).status_code == 404


def test_a_disliked_outfit_is_not_proposed_again(client, auth):
    a = create_cloth(client, auth, name="Tee", category="tshirt")
    b = create_cloth(client, auth, name="Jeans", category="jeans")
    o = _manual(client, auth, [a["id"], b["id"]])
    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "random", "count": 1})
    assert r.status_code == 200
    client.post(f"/outfits/{o['id']}/rating", headers=auth, json={"rating": 1})
    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "random", "count": 1})
    assert r.status_code == 404 or not r.json()["selections"], r.text


def test_good_ratings_pull_pieces_together(client, auth):
    a = create_cloth(client, auth, name="Tee", category="tshirt")
    create_cloth(client, auth, name="Jeans", category="jeans")
    b = create_cloth(client, auth, name="Chino", category="trousers")
    o = _manual(client, auth, [a["id"], b["id"]])
    client.post(f"/outfits/{o['id']}/rating", headers=auth, json={"rating": 5})
    with db.get_conn() as conn:
        uid = conn.execute("SELECT user_id FROM outfits WHERE id=?",
                           (o["id"],)).fetchone()[0]
        pairs = generator.learned_pairs(conn, uid)
    assert pairs[tuple(sorted((a["id"], b["id"])))] == 2.0
    hits = 0
    for _ in range(40):
        sel = generator.select(generator.GenerateRequest(
            "random", user_id=uid, weather="cold"))
        hits += b["id"] in {c["id"] for c in sel}
    assert hits > 28, hits
