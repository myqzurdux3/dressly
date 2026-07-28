from conftest import create_cloth


def test_clothes_pagination(client, auth):
    for i in range(5):
        create_cloth(client, auth, name=f"C{i}")
    full = client.get("/clothes", headers=auth).json()
    assert len(full) == 5

    page1 = client.get("/clothes?limit=2&offset=0", headers=auth).json()
    page2 = client.get("/clothes?limit=2&offset=2", headers=auth).json()
    assert [c["id"] for c in page1] == [c["id"] for c in full[:2]]
    assert [c["id"] for c in page2] == [c["id"] for c in full[2:4]]
    # no limit still returns everything
    assert len(full) == 5


def test_outfits_pagination(client, auth):
    a = create_cloth(client, auth)
    oids = []
    for _ in range(4):
        oids.append(client.post("/outfits/generate", headers=auth,
                                json={"cloth_ids": [a["id"]]}).json()["id"])
    full = client.get("/outfits", headers=auth).json()
    assert len(full) == 4
    page = client.get("/outfits?limit=2&offset=1", headers=auth).json()
    assert [o["id"] for o in page] == [o["id"] for o in full[1:3]]


def test_agenda_batch_hydrate_matches(client, auth):
    a = create_cloth(client, auth, name="Tee")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]]}).json()
    client.post("/agenda", headers=auth,
                json={"day": "2026-08-01", "outfit_id": o["id"], "title": "A"})
    lst = client.get("/agenda", headers=auth).json()
    assert len(lst) == 1
    e = lst[0]
    # embedded outfit hydrated with its clothes
    assert e["outfit"] is not None
    assert [c["name"] for c in e["outfit"]["cloths"]] == ["tee"]
