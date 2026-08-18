"""Storing a photo must never rewrite a blob other clothes are linked to.

link_bytes used to do `dst.unlink()` then `os.link(blob, dst)`, with a plain
`dst.write_bytes(data)` as a fallback. Two failure modes:

  * between the unlink and the link, dst does not exist — while its URL, with a
    ?v= cache-buster, is already in the client's hands;
  * if the unlink failed and dst was still a hard link INTO the blob store, the
    fallback wrote through it and rewrote the shared inode: every other cloth
    linked to that blob silently changed picture, and the blob's digest no
    longer described its own content.
"""

import os

import pytest

import images


def test_two_clothes_with_the_same_photo_share_one_inode(tmp_path, monkeypatch):
    monkeypatch.setattr(images, "BLOBS_DIR", tmp_path / "blobs")
    data = b"the same picture"

    a = images.link_bytes(data, tmp_path / "a.webp")
    b = images.link_bytes(data, tmp_path / "b.webp")

    assert a.read_bytes() == b.read_bytes() == data
    assert os.stat(a).st_ino == os.stat(b).st_ino, "dedupe lost"


def test_a_failed_link_does_not_rewrite_the_shared_blob(tmp_path, monkeypatch):
    """The regression: the fallback must write a NEW file, never through dst."""
    monkeypatch.setattr(images, "BLOBS_DIR", tmp_path / "blobs")
    shared = b"picture used by two clothes"
    first = images.link_bytes(shared, tmp_path / "first.webp")
    second = images.link_bytes(shared, tmp_path / "second.webp")
    blob = next(p for p in (tmp_path / "blobs").rglob("*") if p.is_file())
    assert os.stat(first).st_ino == os.stat(blob).st_ino

    # Now store DIFFERENT bytes at second.webp on a filesystem that refuses
    # hard links.
    def no_links(*a, **k):
        raise OSError(18, "Invalid cross-device link")

    monkeypatch.setattr(images.os, "link", no_links)
    images.link_bytes(b"a different picture", second)

    assert second.read_bytes() == b"a different picture"
    assert first.read_bytes() == shared, "the other cloth's photo was rewritten"
    assert blob.read_bytes() == shared, "the blob no longer matches its digest"


def test_replacing_a_photo_never_leaves_the_path_missing(tmp_path, monkeypatch):
    """dst is replaced by rename, so it is always readable — old bytes or new."""
    monkeypatch.setattr(images, "BLOBS_DIR", tmp_path / "blobs")
    dst = tmp_path / "front.webp"
    images.link_bytes(b"version one", dst)

    seen = []
    real_replace = images.os.replace

    def watching(src, target):
        # Only the rename onto dst matters; the blob store has its own.
        if str(target) == str(dst):
            seen.append(dst.exists())  # still readable right up to the rename
        return real_replace(src, target)

    monkeypatch.setattr(images.os, "replace", watching)
    images.link_bytes(b"version two", dst)

    assert seen == [True], "dst disappeared before being replaced"
    assert dst.read_bytes() == b"version two"


def test_a_storage_failure_is_raised_not_swallowed(tmp_path, monkeypatch):
    """A photo that could not be stored must not look stored."""
    monkeypatch.setattr(images, "BLOBS_DIR", tmp_path / "blobs")

    def boom(*a, **k):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(images.os, "replace", boom)
    with pytest.raises(OSError):
        images.link_bytes(b"x", tmp_path / "nope.webp")


def test_no_temp_files_are_left_behind(tmp_path, monkeypatch):
    monkeypatch.setattr(images, "BLOBS_DIR", tmp_path / "blobs")
    for i in range(3):
        images.link_bytes(f"photo {i}".encode(), tmp_path / f"p{i}.webp")
    assert not list(tmp_path.glob("*.tmp"))


def test_dst_is_never_written_through_even_if_it_cannot_be_unlinked(
        tmp_path, monkeypatch):
    """The exact scenario that corrupted a shared blob.

    The old code unlinked dst before linking. When that unlink failed —
    permissions, a read-only parent, an NFS quirk — dst was STILL a hard link
    into the blob store, and the fallback `dst.write_bytes(data)` wrote through
    it, rewriting the inode every other cloth shared.

    The fix never unlinks and never writes to dst: it renames a fresh file onto
    the name. So refusing every unlink must change nothing.
    """
    monkeypatch.setattr(images, "BLOBS_DIR", tmp_path / "blobs")
    shared = b"picture used by two clothes"
    first = images.link_bytes(shared, tmp_path / "first.webp")
    second = images.link_bytes(shared, tmp_path / "second.webp")
    blob = next(p for p in (tmp_path / "blobs").rglob("*") if p.is_file())

    def refuse(*a, **k):
        raise PermissionError(13, "Permission denied")

    monkeypatch.setattr(images.os, "unlink", refuse)
    monkeypatch.setattr(images.Path, "unlink", refuse)
    monkeypatch.setattr(images.os, "link", refuse)   # force the fallback too

    images.link_bytes(b"a different picture", second)

    assert second.read_bytes() == b"a different picture"
    assert first.read_bytes() == shared, "the other cloth's photo was rewritten"
    assert blob.read_bytes() == shared, "the blob no longer matches its digest"


def test_two_uploads_of_the_same_photo_at_once_do_not_collide(tmp_path, monkeypatch):
    """Same bytes -> same digest -> same blob path, from several threads.

    The blob was written to a fixed `<name>.tmp` before being renamed into
    place, so two simultaneous uploads of the same photo used the same temp
    name: one renamed the other's file away and the loser died with
    FileNotFoundError. Identical photos are not exotic — re-uploading the same
    picture for the front and back of a garment does it.
    """
    import threading

    monkeypatch.setattr(images, "BLOBS_DIR", tmp_path / "blobs")
    data = b"one photo, many uploads"
    errors: list = []
    barrier = threading.Barrier(4)

    def store(i):
        try:
            barrier.wait(timeout=10)
            images.link_bytes(data, tmp_path / f"copy{i}.webp")
        except Exception as e:  # noqa: BLE001 - the point of the test
            errors.append(repr(e))

    threads = [threading.Thread(target=store, args=(i,)) for i in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=20)

    assert not errors, errors
    for i in range(4):
        assert (tmp_path / f"copy{i}.webp").read_bytes() == data
    assert not list((tmp_path / "blobs").rglob("*.tmp"))
