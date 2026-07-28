import numpy as np
from PIL import Image

import images
from conftest import create_cloth


def _img(client, auth, cid, iid):
    return next(x for x in client.get(f"/clothes/{cid}", headers=auth).json()["images"]
               if x["id"] == iid)


def test_redo_bg_stores_tolerance(client, auth):
    c = create_cloth(client, auth)
    cid, iid = c["id"], c["images"][0]["id"]
    assert _img(client, auth, cid, iid)["bg_tolerance"] == "medium"
    for level in ("low", "high", "medium"):
        r = client.post(f"/clothes/{cid}/images/{iid}/redo-bg",
                        headers=auth, json={"tolerance": level})
        assert r.status_code == 200
        assert _img(client, auth, cid, iid)["bg_tolerance"] == level
        assert _img(client, auth, cid, iid)["bg_accepted"] == "pending"


def test_apply_tolerance_changes_alpha_coverage():
    # A soft-edged mask: a filled circle with a fuzzy border.
    size = 64
    yy, xx = np.mgrid[0:size, 0:size]
    dist = np.sqrt((xx - size / 2) ** 2 + (yy - size / 2) ** 2)
    alpha = np.clip((20 - (dist - 15)) * 12, 0, 255).astype(np.uint8)
    rgba = np.dstack([np.full((size, size), 128, np.uint8)] * 3 + [alpha])
    im = Image.fromarray(rgba, "RGBA")

    def coverage(t):
        out = images._apply_tolerance(im.copy(), t)
        return int(np.asarray(out.split()[3]).sum())

    low, med, high = coverage("low"), coverage("medium"), coverage("high")
    assert low > med > high  # 'low' keeps more, 'high' removes more


def test_trim_transparent_crops_empty_margins():
    from PIL import ImageDraw
    im = Image.new("RGBA", (100, 100), (0, 0, 0, 0))  # all void
    ImageDraw.Draw(im).rectangle([30, 30, 49, 49], fill=(200, 0, 0, 255))
    out = images._trim_transparent(im, pad_frac=0.0)
    assert out.size == (20, 20)  # cropped tight to the 20x20 content

    # A fully-transparent image is left untouched (no bbox to crop to).
    assert images._trim_transparent(
        Image.new("RGBA", (40, 40), (0, 0, 0, 0))).size == (40, 40)
