"""Background removal: u2net through onnxruntime, in a process that then exits.

Two problems forced this module, both reported as "the server dies when it cuts
out an image" (`INFO: Child process [13583] died.`):

1. Memory is never given back. Measured here: a worker that has run one cut-out
   holds ~660 MB for the rest of its life. Dropping the session and calling
   gc.collect() moved RSS by 1 MB — onnxruntime's allocations do not return to
   the OS. With three uvicorn workers, all three eventually pay it, and on a
   small VPS the kernel kills them. Running it in a child process that exits is
   the only thing that actually releases the memory.

2. rembg is expensive to be near. `import rembg` costs 0.94 s and 227 MB, of
   which 0.46 s is pymatting — an alpha-matting library this app never uses,
   pulled in unconditionally. `import onnxruntime` is 0.11 s and 43 MB. Since
   the point of (1) is to pay import cost on every cut-out, that difference is
   the difference between the idea working and not.

So inference happens here instead, and it is deliberately a transcription of
rembg's own u2net path rather than an improvement on it: same 320x320 LANCZOS
resize, same ImageNet mean/std, same min-max normalisation of the prediction,
same LANCZOS upscale of the mask, same composite. test_cutout_parity.py asserts
the output is pixel-identical to rembg's, so this stays honest if rembg is ever
consulted again.

rembg is still installed, and still the source of the model file: it is imported
only to download u2net.onnx the first time, which happens once per machine.
"""
import os
import sys
from pathlib import Path

# Must precede onnxruntime: naming a thread count is what stops it trying to pin
# threads to cores, which a VPS cgroup refuses —
#   pthread_setaffinity_np failed for thread: ..., error code: 22
# The SessionOptions below say it again explicitly, which is the part that
# actually binds; this covers the OpenMP runtime that loads with the library.
THREADS = max(1, int(os.environ.get("CLOTHESAPP_REMBG_THREADS")
                     or os.environ.get("OMP_NUM_THREADS") or 4))
os.environ["OMP_NUM_THREADS"] = str(THREADS)

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

# u2netp is the same network, smaller weights, so the preprocessing below holds
# for both. Anything else (isnet, sam) preprocesses differently and would give a
# silently wrong mask, so it is refused rather than approximated.
MODEL_NAME = os.environ.get("CLOTHESAPP_REMBG_MODEL", "u2net")
if MODEL_NAME not in ("u2net", "u2netp"):
    raise SystemExit(
        f"CLOTHESAPP_REMBG_MODEL={MODEL_NAME!r} is not supported here: cutout.py "
        "implements u2net's preprocessing only. Use u2net or u2netp.")

# Values baked into u2net, not tunables: 320x320 is the network's input size and
# the mean/std are the ImageNet statistics it was trained against.
_INPUT_SIZE = (320, 320)
_MEAN = (0.485, 0.456, 0.406)
_STD = (0.229, 0.224, 0.225)


# Where rembg keeps its models, by version. It was ~/.u2net up to 2.0.x and
# ~/.rembg after; both are checked rather than guessed, because the version
# installed decides and requirements.txt does not pin one.
_MODEL_DIRS = (".u2net", ".rembg")


def model_dirs() -> list[Path]:
    """Every directory a rembg version might hold the model in, likeliest first.

    U2NET_HOME, when set, is the whole answer — every version honours it.
    Otherwise the directory sits under XDG_DATA_HOME if that is set, and under
    the home directory if it is not, and its name depends on the rembg version:
    ".u2net" historically, ".rembg" (or "rembg" beneath XDG_DATA_HOME) since.
    """
    if home := os.environ.get("U2NET_HOME"):
        return [Path(os.path.expanduser(home))]
    xdg = os.environ.get("XDG_DATA_HOME")
    if xdg:
        base = Path(os.path.expanduser(xdg))
        return [base / name for name in (*_MODEL_DIRS, "rembg")]
    base = Path.home()
    return [base / name for name in _MODEL_DIRS]


def model_path() -> Path:
    """Where u2net.onnx already is, or where the first candidate would put it.

    Sharing rembg's location means switching to this module does not
    re-download 176 MB. Getting it wrong does not break cut-outs — ensure_model
    falls back to rembg, which returns its real path — it just misses the cache
    on every call, so each cut-out re-imports rembg for 0.94 s, which is the one
    cost this module exists to avoid.
    """
    candidates = [d / f"{MODEL_NAME}.onnx" for d in model_dirs()]
    for path in candidates:
        if path.exists():
            return path
    return candidates[0]


def ensure_model() -> Path:
    """Return the model path, downloading it through rembg if absent.

    The import is inside the function on purpose: it is the one thing rembg is
    still needed for, it happens once per machine, and paying 0.94 s for it on
    every cut-out is exactly what this module exists to avoid.
    """
    path = model_path()
    if path.exists():
        return path
    from rembg.session_factory import sessions_class

    cls = next(c for c in sessions_class if c.name() == MODEL_NAME)
    return Path(cls.download_models())


def new_session():
    import onnxruntime as ort

    opts = ort.SessionOptions()
    # Explicit counts, so onnxruntime does not choose its own and pin them.
    opts.inter_op_num_threads = THREADS
    opts.intra_op_num_threads = THREADS
    # The CPU arena pre-reserves a large pool and keeps it. Off, this process
    # peaks at 831 MB instead of 1092 MB and the cut-out runs in 1.08 s instead
    # of 1.70 s — faster AND smaller, because there is no pool to grow.
    opts.enable_cpu_mem_arena = False
    return ort.InferenceSession(str(ensure_model()), sess_options=opts,
                                providers=["CPUExecutionProvider"])


def alpha_mask(img: Image.Image, session=None) -> Image.Image:
    """Greyscale mask, white where the garment is, at ``img``'s size."""
    session = session or new_session()

    small = img.convert("RGB").resize(_INPUT_SIZE, Image.Resampling.LANCZOS)
    arr = np.array(small) / max(np.max(np.array(small)), 1e-6)
    norm = np.zeros_like(arr, dtype=np.float64)
    for c in range(3):
        norm[:, :, c] = (arr[:, :, c] - _MEAN[c]) / _STD[c]
    batch = np.expand_dims(norm.transpose((2, 0, 1)), 0).astype(np.float32)

    pred = session.run(None, {session.get_inputs()[0].name: batch})[0][:, 0, :, :]
    lo, hi = np.min(pred), np.max(pred)
    # u2net emits unbounded logits, so the mask is only meaningful after being
    # stretched to its own range.
    pred = np.squeeze((pred - lo) / (hi - lo))
    mask = Image.fromarray((pred.clip(0, 1) * 255).astype("uint8"), mode="L")
    return mask.resize(img.size, Image.Resampling.LANCZOS)


def cut_out(img: Image.Image, session=None) -> Image.Image:
    """The garment on transparency, same size as ``img``."""
    mask = alpha_mask(img, session)
    return Image.composite(img.convert("RGBA"),
                           Image.new("RGBA", img.size, 0), mask)


def main(argv=None) -> int:
    """Entry point for the child process: read an image, write the finished
    cut-out, exit — which is what returns the memory.

    Usage: python -m cutout <src> <dst> [tolerance]

    The whole pipeline runs here, not just inference: the parent would otherwise
    have to load a full-resolution RGBA back to trim and encode it, and the
    point is to keep the parent small.
    """
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) < 2:
        print(__doc__.splitlines()[0], file=sys.stderr)
        print("usage: python -m cutout <src> <dst> [tolerance]", file=sys.stderr)
        return 2
    src, dst = Path(argv[0]), Path(argv[1])
    tolerance = argv[2] if len(argv) > 2 else "medium"

    # Imported here, after the argument check, so a bad invocation fails fast.
    import images
    from PIL import ImageOps

    with Image.open(src) as img:
        img = ImageOps.exif_transpose(img) or img
        result = cut_out(img)
    result = images._apply_tolerance(result, tolerance)
    result = images._trim_transparent(result)
    result = images._downscale(result, images.CUTOUT_MAX_PX)
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(images._encode_cutout(result, dst))
    return 0


if __name__ == "__main__":
    sys.exit(main())
