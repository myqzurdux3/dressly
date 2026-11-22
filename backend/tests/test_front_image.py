"""db.front_image(s) / db.display_path: the one rule for a garment's picture."""

import db


def _user(conn, email):
    return conn.execute(
        "INSERT INTO users (email, password_hash) VALUES (?, 'x')", (email,)
    ).lastrowid


def _cloth(conn, user_id):
    return conn.execute(
        "INSERT INTO clothes (user_id, name) VALUES (?, 'c')", (user_id,)
    ).lastrowid


def _img(conn, cloth_id, role, sort_order=0, bg="pending", cutout="cut"):
    return conn.execute(
        "INSERT INTO cloth_images (cloth_id, role, original_path, cutout_path, "
        "sort_order, bg_accepted) VALUES (?, ?, ?, ?, ?, ?)",
        (cloth_id, role, f"orig-{role}-{sort_order}", cutout, sort_order, bg),
    ).lastrowid


def test_front_wins_then_sort_order_then_id():
    with db.get_conn() as conn:
        u = _user(conn, "a@test.co")
        a, b, c, empty = (_cloth(conn, u) for _ in range(4))
        # a: a back photo sorted first must still lose to the front photo.
        _img(conn, a, "back", sort_order=0)
        front_a = _img(conn, a, "front", sort_order=5)
        # b: two front photos, lowest sort_order wins.
        _img(conn, b, "front", sort_order=2)
        front_b = _img(conn, b, "front", sort_order=1)
        # c: no front at all, same sort_order: lowest id wins.
        first_c = _img(conn, c, "extra", sort_order=0)
        _img(conn, c, "back", sort_order=0)

        got = db.front_images(conn, [a, b, c, empty])
        assert {k: r["id"] for k, r in got.items()} == {
            a: front_a, b: front_b, c: first_c}
        # The single-garment form agrees with the batch form.
        assert db.front_image(conn, a)["id"] == front_a
        assert db.front_image(conn, empty) is None
        assert db.front_images(conn, []) == {}


def test_user_scope_hides_other_users_clothes():
    with db.get_conn() as conn:
        me, other = _user(conn, "me@test.co"), _user(conn, "o@test.co")
        mine, theirs = _cloth(conn, me), _cloth(conn, other)
        _img(conn, mine, "front")
        _img(conn, theirs, "front")
        assert set(db.front_images(conn, [mine, theirs], me)) == {mine}
        assert db.front_image(conn, theirs, me) is None
        assert set(db.front_images(conn, [mine, theirs])) == {mine, theirs}


def test_display_path_honours_a_rejected_cutout():
    row = {"original_path": "o", "cutout_path": "c", "bg_accepted": "accepted"}
    assert db.display_path(row) == "c"
    assert db.display_path({**row, "bg_accepted": "rejected"}) == "o"
    assert db.display_path({**row, "cutout_path": ""}) == "o"
