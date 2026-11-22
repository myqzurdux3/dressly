"""The personal stylist, with the Claude API replaced by a script.

What matters here is our side of the loop: tools read the right user's data,
proposals are validated and stored, the conversation is replayed as returned,
and a proposal becomes an outfit with one call.
"""
import copy
from types import SimpleNamespace

import pytest

import stylist
from conftest import create_cloth


class Block(SimpleNamespace):
    def model_dump(self, exclude_none=True):
        return {k: v for k, v in vars(self).items() if v is not None}


def text(t):
    return Block(type="text", text=t)


def tool(name, args, id_="tu1"):
    return Block(type="tool_use", id=id_, name=name, input=args)


class FakeAPI:
    """Answers each create() with the next scripted response."""

    def __init__(self, script):
        self.script = list(script)
        self.calls = []
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self.create))

    def create(self, **kw):
        kw = copy.deepcopy(kw)  # the caller keeps appending to the same list
        self.calls.append(kw)
        step = self.script.pop(0)
        if callable(step):
            step = step(kw)
        blocks, stop = step
        return SimpleNamespace(content=blocks, stop_reason=stop,
                               model=kw["model"], usage=SimpleNamespace(
                                   input_tokens=1000, output_tokens=200,
                                   cache_read_input_tokens=0,
                                   cache_creation_input_tokens=0))


@pytest.fixture()
def fake(monkeypatch):
    def install(script):
        api = FakeAPI(script)
        monkeypatch.setattr(stylist, "available", lambda: True)
        monkeypatch.setattr(stylist, "client", lambda: api)
        return api
    return install


def _turn(client, auth, message, thread_id=None, speed=None):
    """Send a message and read the thread once the background turn is done
    (TestClient runs background tasks before returning)."""
    body = {"message": message}
    if thread_id:
        body["thread_id"] = thread_id
    if speed:
        body["speed"] = speed
    r = client.post("/stylist/chat", headers=auth, json=body)
    assert r.status_code == 200, r.text
    tid = r.json()["thread_id"]
    t = client.get(f"/stylist/threads/{tid}", headers=auth).json()
    assert t["pending"] is False
    return tid, t


def _wardrobe(client, auth):
    tee = create_cloth(client, auth, name="Tee blanc", category="tshirt")["id"]
    jog = create_cloth(client, auth, name="Jogging gris", category="jogging")["id"]
    shoes = create_cloth(client, auth, name="Sneakers", category="sneakers")["id"]
    return tee, jog, shoes


def test_not_configured_says_so(client, auth, monkeypatch):
    monkeypatch.setattr(stylist, "available", lambda: False)
    r = client.post("/stylist/chat", headers=auth, json={"message": "hi"})
    assert r.status_code == 503
    assert client.get("/stylist/status", headers=auth).json()["available"] is False


def test_a_turn_reads_the_wardrobe_and_proposes_an_outfit(client, auth, fake):
    tee, jog, shoes = _wardrobe(client, auth)
    seen = {}

    def after_wardrobe(kw):
        result = kw["messages"][-1]["content"][0]
        seen["wardrobe"] = result["content"]
        return ([tool("propose_outfit", {"title": "Samedi", "reason": "Simple.",
                                         "cloth_ids": [shoes, tee, jog]}, "tu2")],
                "tool_use")

    api = fake([
        ([text("Je regarde."), tool("get_wardrobe", {"category": ""})], "tool_use"),
        after_wardrobe,
    ])
    tid, t = _turn(client, auth, "Quoi porter ?")
    listing = seen["wardrobe"].lower()
    assert "tee blanc" in listing and "jogging gris" in listing
    user_msg, reply = t["messages"]
    assert user_msg["role"] == "user" and user_msg["text"] == "Quoi porter ?"
    # Text already said and only proposals left: no wrap-up call.
    assert reply["text"] == "Je regarde."
    assert len(api.calls) == 2
    (prop,) = reply["proposals"]
    assert prop["title"] == "Samedi"
    # Stored in wearing order, with pictures for the card.
    assert set(prop["cloth_ids"]) == {tee, jog, shoes}
    assert all(c["thumb_url"] for c in prop["cloths"])
    # The model got the tools and the adaptive-thinking settings.
    assert {t["name"] for t in api.calls[0]["tools"]} >= {"get_wardrobe", "propose_outfit"}
    assert api.calls[0]["fallbacks"] == "default"

    # The next turn replays the whole conversation as it was returned.
    api2 = fake([([text("Avec plaisir.")], "end_turn")])
    _turn(client, auth, "Merci", tid)
    replay = api2.calls[0]["messages"]
    # The proposal's result was held back and opens the next question.
    last = replay[-1]["content"]
    assert last[0]["type"] == "tool_result" and last[0]["tool_use_id"] == "tu2"
    # The first turn opened with the wardrobe, then the question.
    assert "<wardrobe>" in replay[0]["content"][0]["text"]
    assert replay[0]["content"][1]["text"].endswith("Quoi porter ?")
    assert replay[1]["content"][1]["type"] == "tool_use"
    assert last[-1]["text"].endswith("Merci")


def test_bad_ids_go_back_to_the_model_as_an_error(client, auth, fake):
    tee, jog, shoes = _wardrobe(client, auth)
    errors = []

    def check(kw):
        res = kw["messages"][-1]["content"][0]
        errors.append(res)
        return ([text("Désolé.")], "end_turn")

    fake([
        ([tool("propose_outfit", {"title": "x", "reason": "y",
                                  "cloth_ids": [tee, 99999]})], "tool_use"),
        check,
    ])
    _, t = _turn(client, auth, "go")
    assert errors[0]["is_error"] is True and "99999" in errors[0]["content"]
    assert t["messages"][1]["proposals"] == []


def test_two_bottoms_are_refused(client, auth, fake):
    tee, jog, shoes = _wardrobe(client, auth)
    jeans = create_cloth(client, auth, name="Jean", category="jeans")["id"]
    errors = []
    fake([
        ([tool("propose_outfit", {"title": "x", "reason": "y",
                                  "cloth_ids": [tee, jog, jeans]})], "tool_use"),
        lambda kw: (errors.append(kw["messages"][-1]["content"][0])
                    or ([text("ok")], "end_turn")),
    ])
    client.post("/stylist/chat", headers=auth, json={"message": "go"})
    assert errors[0]["is_error"] and "same kind" in errors[0]["content"]


def test_saving_a_proposal_makes_an_outfit_once(client, auth, fake):
    tee, jog, shoes = _wardrobe(client, auth)
    fake([
        ([tool("propose_outfit", {"title": "T", "reason": "R",
                                  "cloth_ids": [tee, jog, shoes]})], "tool_use"),
        ([text("Voilà.")], "end_turn"),
    ])
    tid, t = _turn(client, auth, "go")
    pid = t["messages"][1]["proposals"][0]["id"]
    r = client.post(f"/stylist/proposals/{pid}/save", headers=auth)
    assert r.status_code == 200, r.text
    oid = r.json()["outfit_id"]
    outfit = client.get(f"/outfits/{oid}", headers=auth).json()
    assert outfit["kind"] == "manual" and outfit["generated_url"]
    assert set(outfit["cloth_ids"]) == {tee, jog, shoes}
    again = client.post(f"/stylist/proposals/{pid}/save", headers=auth).json()
    assert again == {"outfit_id": oid, "created": False}
    thread = client.get(f"/stylist/threads/{tid}", headers=auth).json()
    assert thread["messages"][1]["proposals"][0]["outfit_id"] == oid


def test_threads_are_private_and_deletable(client, auth, fake):
    fake([([text("Bonjour.")], "end_turn")])
    tid, _ = _turn(client, auth, "Salut")
    assert [t["id"] for t in client.get("/stylist/threads", headers=auth).json()["items"]] == [tid]
    other = client.post("/auth/signup", json={"email": "o@test.co", "password": "pw123456"})
    other_auth = {"Authorization": f"Bearer {other.json()['token']}"}
    assert client.get(f"/stylist/threads/{tid}", headers=other_auth).status_code == 404
    assert client.delete(f"/stylist/threads/{tid}", headers=auth).status_code == 200
    assert client.get("/stylist/threads", headers=auth).json()["items"] == []


def test_api_failure_keeps_nothing_half_written(client, auth, monkeypatch):
    def boom():
        raise stylist.StylistUnavailable("The stylist could not be reached")
    monkeypatch.setattr(stylist, "available", lambda: True)
    monkeypatch.setattr(stylist, "client", boom)
    r = client.post("/stylist/chat", headers=auth, json={"message": "hi"})
    assert r.status_code == 200
    t = client.get(f"/stylist/threads/{r.json()['thread_id']}", headers=auth).json()
    assert t["pending"] is False
    assert t["error"] == "The stylist could not be reached"
    assert t["messages"] == []


def test_speeds_pick_the_model_and_fallback(client, auth, fake):
    api = fake([([text("ok")], "end_turn")] * 3)
    _turn(client, auth, "a", speed="fast")
    _turn(client, auth, "b", speed="expert")
    _turn(client, auth, "c")
    fast, expert, default = api.calls
    assert fast["model"] == "claude-haiku-5-5" and "fallbacks" not in fast
    assert expert["model"] == "claude-opus-5-5" and expert["fallbacks"] == "default"
    assert default["model"] == "claude-sonnet-5-5"
    speeds = client.get("/stylist/status", headers=auth).json()["speeds"]
    assert set(speeds) == {"fast", "balanced", "expert"}


def test_search_filters_and_photos(client, auth, fake):
    import db

    tee, jog, shoes = _wardrobe(client, auth)
    with db.get_conn() as conn:
        conn.execute("UPDATE clothes SET score = 5, custom_tags = '[\"sport\"]' "
                     "WHERE id = ?", (jog,))
    got = {}

    def search(kw):
        return ([tool("search_wardrobe", {
            "text": "", "category": "", "color": "", "brand": "", "tag": "sport",
            "min_rating": 4, "favorites_only": False, "include_excluded": False},
            "s1"), tool("view_garments", {"cloth_ids": [jog, 99999]}, "v1")],
            "tool_use")

    def read(kw):
        res = kw["messages"][-1]["content"]
        got["search"], got["view"] = res[0]["content"], res[1]["content"]
        return ([text("ok")], "end_turn")

    fake([search, read])
    _turn(client, auth, "go")
    assert got["search"].startswith("1 garment(s)")
    assert "jogging gris" in got["search"].lower()
    kinds = [b["type"] for b in got["view"]]
    assert kinds == ["text", "image", "text"]
    assert got["view"][1]["source"]["media_type"] == "image/jpeg"
    assert "not in the wardrobe" in got["view"][2]["text"]


def test_actions_save_render_rate_schedule_and_cost(client, auth, fake,
                                                     monkeypatch):
    import db
    import routes_stylist

    tee, jog, shoes = _wardrobe(client, auth)
    started = []
    monkeypatch.setattr(routes_stylist, "start_render",
                        lambda user, ids, person, tier: started.append(
                            (ids, person, tier)) or 999)
    fake([
        ([text("Je m'en occupe."),
          tool("save_outfit", {"title": "A", "cloth_ids": [tee, jog, shoes],
                               "reason": "r"}, "a1"),
          tool("render_outfit", {"title": "B", "cloth_ids": [tee, jog, shoes],
                                 "person": "random"}, "a2"),
          tool("update_garment", {"cloth_id": jog, "rating": 5,
                                  "favorite": "yes", "excluded": "keep"}, "a3"),
          tool("schedule_outfit", {"day": "2026-12-01", "outfit_id": 0,
                                   "cloth_ids": [tee, jog, shoes],
                                   "title": "Dîner"}, "a4")], "tool_use"),
        ([text("Fait.")], "end_turn"),
    ])
    body = {"message": "go", "render_tier": "openrouter"}
    r = client.post("/stylist/chat", json=body, headers=auth)
    tid = r.json()["thread_id"]
    th = client.get(f"/stylist/threads/{tid}", headers=auth).json()
    cards = th["messages"][-1]["proposals"]
    assert [c["title"] for c in cards] == ["A", "B"]
    assert cards[0]["outfit_id"] and cards[1]["render_id"] == 999
    assert started[0][1:] == ("random", "openrouter")
    c = client.get(f"/clothes/{jog}", headers=auth).json()
    assert c["score"] == 5 and c["is_favorite"] is True
    agenda = client.get("/agenda", headers=auth).json()
    day = [e for e in agenda if e["day"] == "2026-12-01"]
    # Saved and scheduled in one turn: the same outfit, not a second copy.
    assert day and day[0]["outfit_id"] == cards[0]["outfit_id"]
    with db.get_conn() as conn:
        rows = conn.execute("SELECT model, cost_usd FROM llm_usage").fetchall()
    # Sonnet 5.5: 1000 in at $2/M + 200 out at $10/M = $0.004 per call.
    assert len(rows) == 2 and abs(rows[0]["cost_usd"] - 0.004) < 1e-9


def test_render_a_proposal_from_the_app(client, auth, fake, monkeypatch):
    import routes_stylist

    tee, jog, shoes = _wardrobe(client, auth)
    monkeypatch.setattr(routes_stylist, "start_render",
                        lambda user, ids, person, tier: 777)
    fake([([text("Voilà."), tool("propose_outfit", {
        "title": "T", "cloth_ids": [tee, jog, shoes], "reason": ""})],
        "tool_use")])
    tid, th = _turn(client, auth, "go")
    pid = th["messages"][-1]["proposals"][0]["id"]
    r = client.post(f"/stylist/proposals/{pid}/render",
                    json={"person": "none", "tier": "flex"}, headers=auth)
    assert r.json() == {"outfit_id": 777}
    th = client.get(f"/stylist/threads/{tid}", headers=auth).json()
    assert th["messages"][-1]["proposals"][0]["render_id"] == 777


def test_a_rendering_outfit_lists_its_garment_pictures(client, auth):
    import json as _json

    import db

    tee, jog, shoes = _wardrobe(client, auth)
    with db.get_conn() as conn:
        uid = conn.execute("SELECT user_id FROM clothes WHERE id = ?",
                           (tee,)).fetchone()[0]
        oid = conn.execute(
            "INSERT INTO outfits (user_id, cloth_ids, status) "
            "VALUES (?, ?, 'processing')",
            (uid, _json.dumps([tee, jog]))).lastrowid
    one = client.get(f"/outfits/{oid}", headers=auth).json()
    assert all("thumb_url" in c for c in one["cloths"])
    listed = [o for o in client.get("/outfits", headers=auth).json()
              if o["id"] == oid][0]
    assert all("thumb_url" in c for c in listed["cloths"])


def test_deleting_a_thread_during_its_turn_drops_the_reply(client, auth, fake):
    """The thread goes while the stylist is still answering: the reply has
    nowhere to land and the turn must end quietly, not crash."""
    def delete_then_answer(_kw):
        tid = client.get("/stylist/threads", headers=auth).json()["items"][0]["id"]
        assert client.delete(f"/stylist/threads/{tid}", headers=auth).status_code == 200
        return ([text("Trop tard.")], "end_turn")

    fake([delete_then_answer])
    r = client.post("/stylist/chat", headers=auth, json={"message": "Salut"})
    assert r.status_code == 200
    assert client.get("/stylist/threads", headers=auth).json()["items"] == []
    from db import get_conn
    with get_conn() as conn:
        assert conn.execute("SELECT COUNT(*) FROM stylist_messages").fetchone()[0] == 0
