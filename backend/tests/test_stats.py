from conftest import create_cloth, gen_outfit


def test_stats_me(client, auth):
    a = create_cloth(client, auth, name="Tee", category="tshirt")
    b = create_cloth(client, auth, name="Jeans", category="jeans")
    o = gen_outfit(client, auth, [a["id"], b["id"]])
    client.post(f"/outfits/{o['id']}/wear", headers=auth, json={"day": "2026-06-06"})

    s = client.get("/stats/me", headers=auth).json()
    assert s["clothes_count"] == 2
    assert s["outfits_generated"] == 1
    assert s["outfits_count"] == 1
    assert s["clothes_worn_count"] == 2
    assert s["clothes_worn_pct"] == 100
    assert s["most_worn_outfit"]["outfit"]["id"] == o["id"]
    assert s["most_worn_outfit"]["times_worn"] == 1
    names = {c["name"] for c in s["top_clothes"]}
    assert names == {"tee", "jeans"}
    assert all(c["times_worn"] == 1 and c["thumb_url"] for c in s["top_clothes"])


def test_generated_count_survives_deletion(client, auth):
    a = create_cloth(client, auth, name="Tee", category="tshirt")
    o1 = gen_outfit(client, auth, [a["id"]])
    gen_outfit(client, auth, [a["id"]])
    assert client.get("/stats/me", headers=auth).json()["outfits_generated"] == 2
    # Delete one — lifetime "generated" must NOT go down; current count does.
    assert client.delete(f"/outfits/{o1['id']}", headers=auth).status_code == 200
    s = client.get("/stats/me", headers=auth).json()
    assert s["outfits_generated"] == 2
    assert s["outfits_count"] == 1


def test_stats_empty(client, auth):
    s = client.get("/stats/me", headers=auth).json()
    assert s["clothes_count"] == 0
    assert s["clothes_worn_pct"] == 0
    assert s["most_worn_outfit"] is None
    assert s["top_clothes"] == []
