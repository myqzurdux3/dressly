from conftest import create_cloth


def test_agenda_crud_and_worn(client, auth):
    a = create_cloth(client, auth, name="Tee")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"]]}).json()

    r = client.post("/agenda", headers=auth,
                    json={"day": "2026-07-20", "outfit_id": o["id"], "title": "Work"})
    assert r.status_code == 200
    entry = r.json()
    assert entry["title"] == "Work"
    assert entry["outfit"] is not None
    eid = entry["id"]

    lst = client.get("/agenda", headers=auth).json()
    assert any(e["id"] == eid for e in lst)

    # mark worn -> stamps the outfit's clothes with the agenda day
    r = client.post(f"/agenda/{eid}/worn", headers=auth, json={})
    assert r.status_code == 200
    assert r.json()["worn"] is True
    assert r.json()["clothes_marked"] == 1
    assert client.get(f"/clothes/{a['id']}", headers=auth).json()["last_worn_at"] == "2026-07-20"

    assert client.delete(f"/agenda/{eid}", headers=auth).status_code == 200
    assert all(e["id"] != eid for e in client.get("/agenda", headers=auth).json())


def test_agenda_requires_day(client, auth):
    assert client.post("/agenda", headers=auth, json={"day": ""}).status_code == 400


def test_wearing_cloth_logs_agenda(client, auth):
    a = create_cloth(client, auth, name="Solo Tee")
    client.post(f"/clothes/{a['id']}/wear", headers=auth, json={"day": "2026-05-05"})
    ag = client.get("/agenda", headers=auth).json()
    match = [e for e in ag if e["day"] == "2026-05-05" and e["outfit_id"] is None]
    assert len(match) == 1
    assert match[0]["title"] == "solo tee"  # title derives from the (lowercase) name
    assert match[0]["worn"] is True
