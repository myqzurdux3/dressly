#!/usr/bin/env python3
"""Explain why a cut-out is slow ON THIS MACHINE, stage by stage.

The same photo takes ~2 s on a laptop and was reported taking 30 s on a VPS.
That ratio is too large for "the server is a bit slower" and every plausible
cause leaves a different fingerprint, so this measures all of them at once
instead of guessing:

    swap        830 MB of peak memory on a 1 GB box means the kernel is moving
                pages to disk mid-inference. Shows up as pswpin/pswpout climbing
                and wall-clock time far above CPU time.
    steal       a shared vCPU that is oversold: the process is runnable and the
                hypervisor is running somebody else. Shows up in /proc/stat.
    threads     asking for more threads than the cgroup quota allows makes it
                slower, not faster (measured: 1.67 s at four, 1.82 s at twelve).
    throttling  cfs quota exhausted — the process is stopped for whole
                milliseconds at a time. Counted in cpu.stat.
    per-stage   if inference itself is fast and the model load is slow, the disk
                is the problem, not the CPU.

Run it on the server, from the install directory:

    python3 scripts/bench_cutout.py

It writes nothing outside a temporary directory and touches no database.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BACKEND = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BACKEND))


def _read(path, default=""):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return default


def _meminfo():
    out = {}
    for line in _read("/proc/meminfo").splitlines():
        key, _, rest = line.partition(":")
        out[key] = int(rest.split()[0]) // 1024  # MB
    return out


def _vmstat():
    return {k: int(v) for k, v in
            (l.split() for l in _read("/proc/vmstat").splitlines())}


def _cpu_times():
    """(total, steal) jiffies across all CPUs."""
    parts = _read("/proc/stat").splitlines()[0].split()[1:]
    nums = [int(p) for p in parts]
    steal = nums[7] if len(nums) > 7 else 0
    return sum(nums), steal


def _throttled():
    """(nr_throttled, throttled_time_ns) from the cgroup, v2 then v1."""
    v2 = _read("/sys/fs/cgroup/cpu.stat")
    if v2:
        d = dict(l.split() for l in v2.splitlines())
        if "nr_throttled" in d:
            return int(d["nr_throttled"]), int(d.get("throttled_usec", 0)) * 1000
    v1 = _read("/sys/fs/cgroup/cpu/cpu.stat")
    if v1:
        d = dict(l.split() for l in v1.splitlines())
        if "nr_throttled" in d:
            return int(d["nr_throttled"]), int(d.get("throttled_time", 0))
    return None, None


def _cpu_model():
    for line in _read("/proc/cpuinfo").splitlines():
        if line.startswith("model name"):
            return line.split(":", 1)[1].strip()
    return "unknown"


def section(title):
    print(f"\n--- {title} " + "-" * max(0, 62 - len(title)))


def show_machine():
    import images
    import cutout

    section("machine")
    mem = _meminfo()
    quota = _read("/sys/fs/cgroup/cpu.max") or _read(
        "/sys/fs/cgroup/cpu/cpu.cfs_quota_us")
    print(f"cpu               {_cpu_model()}")
    print(f"os.cpu_count()    {os.cpu_count()}   <- what the HOST claims")
    print(f"usable cpus       {images._available_cpus()}   <- quota/affinity, "
          "what this process may really use")
    print(f"cgroup cpu quota  {quota or 'none'}")
    print(f"threads chosen    {cutout.THREADS}")
    print(f"RAM total         {mem.get('MemTotal', 0)} MB")
    print(f"RAM available     {mem.get('MemAvailable', 0)} MB"
          "   <- a cut-out peaks near 830 MB")
    print(f"swap total        {mem.get('SwapTotal', 0)} MB")
    if mem.get("MemAvailable", 0) < 900:
        print("  ! less than 900 MB free. Inference will swap, or be killed.")
    nr, ns = _throttled()
    if nr is not None:
        print(f"cpu throttled     {nr} times, {ns / 1e9:.1f} s total so far")


def sample_photo(tmp: Path) -> Path:
    """A real photo from the install if there is one, else a synthetic stand-in.
    A real one matters: cut-out cost scales with pixels."""
    from config import IMAGES_DIR

    candidates = []
    for pattern in ("*/*front*.jpg", "*/*.jpg", "*/*.png"):
        candidates += [p for p in Path(IMAGES_DIR).glob(pattern)
                       if "cutout" not in p.name and p.stat().st_size > 200_000]
        if candidates:
            break
    if candidates:
        biggest = max(candidates, key=lambda p: p.stat().st_size)
        dst = tmp / biggest.name
        shutil.copy2(biggest, dst)
        print(f"photo             {biggest.name} "
              f"({biggest.stat().st_size // 1024} KB, from the wardrobe)")
        return dst

    from PIL import Image, ImageDraw

    dst = tmp / "synthetic.jpg"
    im = Image.new("RGB", (3000, 4000), (238, 238, 240))
    ImageDraw.Draw(im).ellipse((600, 800, 2400, 3200), fill=(38, 58, 138))
    im.save(dst, "JPEG", quality=95)
    print(f"photo             synthetic 3000x4000 "
          f"({dst.stat().st_size // 1024} KB; no wardrobe photo found)")
    return dst


def stages(photo: Path, tmp: Path):
    """Time the child's phases separately, in the child, where they happen."""
    section("where the time goes")
    code = r"""
import resource, sys, time
from pathlib import Path
t0 = time.perf_counter()
import cutout
t1 = time.perf_counter()
from PIL import Image, ImageOps
sess = cutout.new_session()
t2 = time.perf_counter()
with Image.open(sys.argv[1]) as img:
    img = ImageOps.exif_transpose(img) or img
    px = img.size
    t3 = time.perf_counter()
    result = cutout.cut_out(img, sess)
t4 = time.perf_counter()
import images
result = images._apply_tolerance(result, "medium")
result = images._trim_transparent(result)
result = images._downscale(result, images.CUTOUT_MAX_PX)
t5 = time.perf_counter()
data = images._encode_cutout(result, Path(sys.argv[2]))
t6 = time.perf_counter()
peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024
cpu = resource.getrusage(resource.RUSAGE_SELF)
print("\n".join(str(x) for x in [
    px[0], px[1], t1-t0, t2-t1, t3-t2, t4-t3, t5-t4, t6-t5, t6-t0,
    peak, len(data), cpu.ru_utime + cpu.ru_stime]))
"""
    before_swap, before_cpu = _vmstat(), _cpu_times()
    wall = time.perf_counter()
    r = subprocess.run([sys.executable, "-c", code, str(photo),
                        str(tmp / "out_cutout.webp")],
                       cwd=str(BACKEND), capture_output=True, text=True)
    wall = time.perf_counter() - wall
    if r.returncode != 0:
        print(f"the cut-out FAILED (exit {r.returncode}):")
        print((r.stderr or "").strip()[-1500:])
        if r.returncode < 0:
            print(f"\nkilled by signal {-r.returncode}. If that is 9, the kernel "
                  "ran out of memory:\n  dmesg | grep -i 'killed process'")
        return None
    after_swap, after_cpu = _vmstat(), _cpu_times()

    v = r.stdout.split()
    (w, h) = int(v[0]), int(v[1])
    imp, load, open_, infer, post, enc, total = (float(x) for x in v[2:9])
    peak, nbytes, cpu_s = int(v[9]), int(v[10]), float(v[11])

    print(f"input             {w}x{h} = {w * h / 1e6:.1f} megapixels")
    for label, secs in (("import python", imp), ("load model", load),
                        ("decode photo", open_), ("inference", infer),
                        ("trim + resize", post), ("encode webp", enc)):
        bar = "#" * max(1, round(40 * secs / max(total, 1e-6)))
        print(f"  {label:<15} {secs:6.2f}s  {bar}")
    print(f"  {'TOTAL (child)':<15} {total:6.2f}s")
    print(f"  {'wall clock':<15} {wall:6.2f}s  (includes process spawn)")
    print(f"peak memory       {peak} MB")
    print(f"output            {nbytes // 1024} KB")

    section("what was in the way")
    cpu_pct = 100 * cpu_s / max(wall, 1e-6)
    print(f"cpu actually used {cpu_s:.1f}s of {wall:.1f}s wall = {cpu_pct:.0f}%"
          f" of one core")
    swapped_in = after_swap.get("pswpin", 0) - before_swap.get("pswpin", 0)
    swapped_out = after_swap.get("pswpout", 0) - before_swap.get("pswpout", 0)
    print(f"swap during run   {swapped_in} pages in, {swapped_out} pages out")
    tot_d = after_cpu[0] - before_cpu[0]
    steal_d = after_cpu[1] - before_cpu[1]
    steal_pct = 100 * steal_d / tot_d if tot_d else 0
    print(f"cpu steal         {steal_pct:.1f}% "
          "(hypervisor running somebody else)")

    print()
    if swapped_in + swapped_out > 1000:
        print("VERDICT: swapping. The machine does not have the ~830 MB this")
        print("  needs, so it is going to disk mid-inference. Add RAM, or add")
        print("  swap and accept it being slow. Nothing in the code fixes this.")
    elif steal_pct > 20:
        print(f"VERDICT: the host is oversold ({steal_pct:.0f}% steal). The CPU")
        print("  is not yours. This is a hosting problem, not a code one.")
    elif cpu_pct < 60:
        print("VERDICT: not CPU-bound and not swapping — it spent its time")
        print("  waiting. Suspect disk (load model above) or throttling.")
    elif total > 8:
        print("VERDICT: genuinely CPU-bound and slow. This CPU is simply much")
        print("  slower than the one it was measured on, or too few cores.")
        print("  Try the thread sweep below and use the best value.")
    else:
        print(f"VERDICT: normal ({total:.1f}s). If the app still feels slow when")
        print("  adding a garment, the time is NOT in background removal —")
        print("  look at scripts/analyze_log.py for the request timings.")
    return total


def thread_sweep(photo: Path, tmp: Path):
    """More threads is not monotonically better, and the best value depends on
    the quota, which differs per machine. Measure it here."""
    section("thread sweep (pick the fastest, put it in .env)")
    import images

    usable = images._available_cpus()
    counts = sorted({1, 2, max(1, usable // 2), usable})
    code = ("import sys, time; from pathlib import Path; import images; "
            "t=time.perf_counter(); "
            "images.remove_background(Path(sys.argv[1]), Path(sys.argv[2])); "
            "print(f'{time.perf_counter()-t:.2f}')")
    best = (None, 1e9)
    for n in counts:
        env = dict(os.environ, CLOTHESAPP_REMBG_THREADS=str(n),
                   OMP_NUM_THREADS=str(n))
        r = subprocess.run(
            [sys.executable, "-c", code, str(photo),
             str(tmp / f"sweep{n}_cutout.webp")],
            cwd=str(BACKEND), env=env, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"  {n:>3} threads   FAILED (exit {r.returncode})")
            continue
        secs = float(r.stdout.strip().splitlines()[-1])
        print(f"  {n:>3} threads   {secs:6.2f}s")
        if secs < best[1]:
            best = (n, secs)
    if best[0]:
        print(f"\nfastest: {best[0]} threads at {best[1]:.2f}s")
        print(f"  CLOTHESAPP_REMBG_THREADS={best[0]}    <- add to backend/.env")


def main():
    print(__doc__.splitlines()[0])
    show_machine()
    with tempfile.TemporaryDirectory(prefix="bench-cutout-") as td:
        tmp = Path(td)
        section("photo")
        photo = sample_photo(tmp)
        if stages(photo, tmp) is not None:
            thread_sweep(photo, tmp)
    return 0


if __name__ == "__main__":
    sys.exit(main())
