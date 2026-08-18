"""Background removal: correctness of the reimplementation, and the memory
behaviour that forced it.

The reported symptom was `INFO: Child process [13583] died.` every time the
server had to cut out an image. Cause: onnxruntime leaves ~660 MB resident in
whatever process runs inference, permanently — dropping the session and calling
gc.collect() moves RSS by 1 MB. Three uvicorn workers each pay it once and the
kernel starts killing them.

So inference moved into a child process that exits, and out of rembg (0.94 s and
227 MB to import, mostly pymatting, which this app never uses) into a direct
onnxruntime call. That second change is only safe if the output is unchanged,
which is what test_the_mask_matches_rembg_exactly is for.
"""
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest
from PIL import Image, ImageDraw

import cutout
import images

BACKEND = Path(__file__).resolve().parent.parent
LINUX_ONLY = pytest.mark.skipif(not Path("/proc/self/status").exists(),
                                reason="reads /proc for RSS")


@pytest.fixture(scope="module")
def photo(tmp_path_factory):
    """Something with a clear subject, so a mask is meaningful."""
    path = tmp_path_factory.mktemp("cut") / "photo.jpg"
    im = Image.new("RGB", (900, 1200), (238, 238, 240))
    d = ImageDraw.Draw(im)
    d.ellipse((180, 240, 720, 960), fill=(38, 58, 138))
    d.rectangle((380, 200, 520, 300), fill=(38, 58, 138))
    im.save(path, "JPEG", quality=95)
    return path


def _rss_mb() -> int:
    with open("/proc/self/status") as status:
        for line in status:
            if line.startswith("VmRSS"):
                return int(line.split()[1]) // 1024
    return 0


# --- the output must not have changed -------------------------------------

def test_the_mask_matches_rembg_exactly(photo):
    """cutout.py is a transcription of rembg's u2net path, not an improvement on
    it. If this drifts, every garment already in the database was cut out by
    different code than the next one will be."""
    pytest.importorskip("rembg")
    from rembg import remove as rembg_remove
    from rembg.session_factory import new_session

    with Image.open(photo) as img:
        img.load()
        mine = cutout.cut_out(img)
        theirs = rembg_remove(img, session=new_session("u2net"))

    a, b = np.array(mine), np.array(theirs.convert("RGBA"))
    assert a.shape == b.shape
    assert np.array_equal(a, b), "the cut-out no longer matches rembg's"


def test_the_mask_actually_selects_the_subject(photo):
    """Parity with rembg is worthless if both are blank — that would pass a
    pixel-comparison test perfectly."""
    with Image.open(photo) as img:
        mask = np.array(cutout.alpha_mask(img))
    assert mask.max() > 200, "nothing was selected"
    assert mask.min() < 60, "everything was selected"
    # The subject sits in the middle; the corners are backdrop.
    h, w = mask.shape
    assert mask[h // 2, w // 2] > 128
    assert mask[2, 2] < 128


def test_the_written_file_is_the_format_its_name_claims(photo, tmp_path):
    """_encode_cutout picks its format from the suffix. The child writes to a
    scratch file first, and when that was named '.part' the result was a PNG
    stored under a .webp name: decodable, since PIL sniffs content, so nothing
    failed — it was just 56% larger, forever."""
    dst = tmp_path / "a_cutout.webp"
    images.remove_background(photo, dst)
    head = dst.read_bytes()[:12]
    assert head[:4] == b"RIFF" and head[8:12] == b"WEBP", f"not WebP: {head!r}"


def test_a_png_destination_still_gets_a_png(photo, tmp_path):
    """Historical rows and re-generations pass .png paths."""
    dst = tmp_path / "a_cutout.png"
    images.remove_background(photo, dst)
    assert dst.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"


def test_the_cutout_is_trimmed_and_capped(photo, tmp_path):
    dst = tmp_path / "b_cutout.webp"
    images.remove_background(photo, dst)
    with Image.open(dst) as im:
        assert max(im.size) <= images.CUTOUT_MAX_PX
        assert im.size != (900, 1200), "not trimmed to the garment"
        assert im.mode == "RGBA"


# --- the bug that started this -------------------------------------------

@LINUX_ONLY
def test_the_calling_process_does_not_keep_the_models_memory(photo, tmp_path):
    """The whole reason inference is not in-process. In-process this grew by
    ~660 MB and never gave it back, which is what the kernel was killing."""
    images.remove_background(photo, tmp_path / "c_cutout.webp")
    before = _rss_mb()
    for i in range(2):
        images.remove_background(photo, tmp_path / f"d{i}_cutout.webp")
    growth = _rss_mb() - before
    assert growth < 100, f"the parent grew {growth} MB per cut-out"


def test_onnxruntime_is_not_imported_by_the_web_process():
    """Importing it costs 43 MB in every worker, and it is only ever needed in
    the child. rembg costs 227 MB and 0.94 s and is needed only to download the
    model, which is why it is imported inside ensure_model()."""
    out = subprocess.run(
        [sys.executable, "-c",
         "import sys, images, routes_clothes;"
         "print([m for m in ('onnxruntime', 'rembg', 'pymatting')"
         " if m in sys.modules])"],
        cwd=BACKEND, capture_output=True, text=True, timeout=180)
    assert out.returncode == 0, out.stderr
    assert out.stdout.strip().endswith("[]"), \
        f"the web process imports heavy inference deps: {out.stdout.strip()}"


# --- failure handling -----------------------------------------------------

def test_a_failing_child_raises_with_its_own_error(tmp_path):
    """Not a bare 500 with 'Child process died' as the only clue."""
    missing = tmp_path / "not-an-image.jpg"
    missing.write_bytes(b"this is not a JPEG")
    with pytest.raises(images.CutoutFailed) as exc:
        images.remove_background(missing, tmp_path / "e_cutout.webp")
    assert "cutout exited" in str(exc.value)
    # The child's own traceback, not just an exit code.
    assert "Error" in str(exc.value) or "error" in str(exc.value)


def test_a_failure_leaves_nothing_behind(tmp_path):
    bad = tmp_path / "bad.jpg"
    bad.write_bytes(b"nope")
    dst = tmp_path / "f_cutout.webp"
    with pytest.raises(images.CutoutFailed):
        images.remove_background(bad, dst)
    assert not dst.exists(), "a broken cut-out was left where a garment's goes"
    assert not list(tmp_path.glob(".*part*")), "scratch file not cleaned up"


def test_a_hanging_child_is_killed(photo, tmp_path, monkeypatch):
    """Without a deadline the upload request hangs until the phone gives up, and
    the server never says why."""
    monkeypatch.setattr(images, "CUTOUT_TIMEOUT_S", 0.4)
    monkeypatch.setattr(images.subprocess, "run", _sleep_forever)
    with pytest.raises(images.CutoutFailed) as exc:
        images.remove_background(photo, tmp_path / "g_cutout.webp")
    assert "still running" in str(exc.value)


def _sleep_forever(cmd, **kw):
    raise subprocess.TimeoutExpired(cmd, kw.get("timeout", 0))


def test_the_semaphore_is_released_after_a_failure(tmp_path, photo):
    """A semaphore leaked on the error path stops every later upload — the
    failure would be one bad photo, the symptom would be a dead server."""
    bad = tmp_path / "bad2.jpg"
    bad.write_bytes(b"nope")
    for _ in range(images.CUTOUT_CONCURRENCY + 1):
        with pytest.raises(images.CutoutFailed):
            images.remove_background(bad, tmp_path / "h_cutout.webp")
    # Still works afterwards.
    images.remove_background(photo, tmp_path / "i_cutout.webp")


@pytest.mark.skipif(images.CUTOUT_CONCURRENCY != 1,
                    reason="only meaningful at the default of 1")
def test_only_one_cutout_runs_at_a_time(photo, tmp_path):
    """Two children at ~830 MB each is the out-of-memory kill this avoids. Two
    garment photos take twice as long on purpose."""
    from concurrent.futures import ThreadPoolExecutor

    running = []
    peak = [0]
    real = images.subprocess.run

    def watched(cmd, **kw):
        running.append(1)
        peak[0] = max(peak[0], len(running))
        try:
            return real(cmd, **kw)
        finally:
            running.pop()

    images.subprocess.run = watched
    try:
        with ThreadPoolExecutor(max_workers=3) as pool:
            list(pool.map(
                lambda i: images.remove_background(
                    photo, tmp_path / f"p{i}_cutout.webp"), range(3)))
    finally:
        images.subprocess.run = real
    assert peak[0] == 1, f"{peak[0]} cut-outs ran at once"


# --- threads / the affinity error ----------------------------------------

def _child_threads(**env):
    environ = {k: v for k, v in os.environ.items()
               if not k.startswith(("OMP_", "CLOTHESAPP_REMBG"))}
    environ.update({k: str(v) for k, v in env.items()})
    r = subprocess.run([sys.executable, "-c",
                        "import cutout; print(cutout.THREADS)"],
                       cwd=BACKEND, env=environ, capture_output=True, text=True,
                       timeout=180)
    assert r.returncode == 0, r.stderr
    return int(r.stdout.strip())


def test_the_thread_count_is_always_explicit_and_positive():
    """Naming a count is what stops onnxruntime pinning threads to cores, which
    a VPS cgroup refuses:
        pthread_setaffinity_np failed for thread: ..., error code: 22"""
    assert _child_threads() >= 1
    assert _child_threads(CLOTHESAPP_REMBG_THREADS=0) >= 1
    assert _child_threads(OMP_NUM_THREADS=0) >= 1


def test_an_explicit_thread_count_is_honoured():
    assert _child_threads(CLOTHESAPP_REMBG_THREADS=2) == 2


def test_omp_num_threads_is_set_before_onnxruntime_is_imported():
    """Set afterwards it has no effect: the library reads it as it loads. Asserted
    by behaviour and not by reading the source, because an earlier version of
    this test matched the word 'import onnxruntime' in the module docstring."""
    r = subprocess.run(
        [sys.executable, "-c",
         "import sys, os, cutout;"
         "print('onnxruntime' in sys.modules, os.environ['OMP_NUM_THREADS'],"
         " cutout.THREADS)"],
        cwd=BACKEND, capture_output=True, text=True, timeout=180)
    assert r.returncode == 0, r.stderr
    loaded, omp, threads = r.stdout.split()
    assert loaded == "False", "onnxruntime loaded before the count was chosen"
    assert omp == threads, "the child's session and OpenMP disagree on threads"


def test_the_worker_count_divides_the_threads():
    """Each worker spawns its own child, so 'every core' per worker means
    workers x cores in total — the 30-second cut-out."""
    one = images._default_rembg_threads()
    os.environ["CLOTHESAPP_WORKERS"] = "8"
    try:
        many = images._default_rembg_threads()
    finally:
        os.environ.pop("CLOTHESAPP_WORKERS", None)
    assert 1 <= many <= one


def test_a_junk_worker_count_does_not_stop_the_server_starting(monkeypatch):
    monkeypatch.setenv("CLOTHESAPP_WORKERS", "three")
    assert images._default_rembg_threads() >= 1


def test_available_cpus_prefers_the_cgroup_quota_over_the_host(tmp_path,
                                                              monkeypatch):
    """os.cpu_count() reports the host: 12 cores on a VPS entitled to 2. Trusting
    it is how a 2-second cut-out became a 30-second one."""
    quota = tmp_path / "cpu.max"
    quota.write_text("200000 100000\n")  # 2 CPUs
    real_read = Path.read_text

    def fake_read(self, *a, **kw):
        if str(self) == "/sys/fs/cgroup/cpu.max":
            return real_read(quota, *a, **kw)
        return real_read(self, *a, **kw)

    monkeypatch.setattr(Path, "read_text", fake_read)
    monkeypatch.setattr(os, "cpu_count", lambda: 64)
    assert images._available_cpus() == 2


def test_an_unlimited_cgroup_falls_through_to_the_affinity_mask(tmp_path,
                                                               monkeypatch):
    unlimited = tmp_path / "cpu.max"
    unlimited.write_text("max 100000\n")
    real_read = Path.read_text

    def fake_read(self, *a, **kw):
        if str(self).startswith("/sys/fs/cgroup/cpu"):
            if str(self) == "/sys/fs/cgroup/cpu.max":
                return real_read(unlimited, *a, **kw)
            raise OSError("no cgroup v1 here")
        return real_read(self, *a, **kw)

    monkeypatch.setattr(Path, "read_text", fake_read)
    monkeypatch.setattr(os, "sched_getaffinity", lambda pid: {0, 1, 2, 3})
    assert images._available_cpus() == 4


# --- configuration -------------------------------------------------------

def test_an_unsupported_model_is_refused_not_approximated():
    """cutout.py hard-codes u2net's 320x320 / ImageNet preprocessing. Another
    model would return a plausible but wrong mask, which nothing would catch."""
    env = dict(os.environ, CLOTHESAPP_REMBG_MODEL="isnet-general-use")
    r = subprocess.run([sys.executable, "-c", "import cutout"],
                       cwd=BACKEND, env=env, capture_output=True, text=True,
                       timeout=180)
    assert r.returncode != 0
    assert "not supported" in r.stderr


def test_the_model_is_shared_with_rembgs_download():
    """Same path, so moving off rembg does not re-download 176 MB."""
    assert cutout.model_path().name == f"{cutout.MODEL_NAME}.onnx"
    assert cutout.model_path().exists(), "model missing; run the server once"


def test_the_launcher_names_a_thread_count_before_python_starts():
    src = (BACKEND / "run-prod.sh").read_text()
    assert "export OMP_NUM_THREADS" in src
    assert src.index("OMP_NUM_THREADS") < src.index("exec python3")
