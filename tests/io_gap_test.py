#!/usr/bin/env python3
"""Write-gap test for /mnt/data.

Writes fixed-size buffered (page-cache) writes at a fixed rate for a fixed
duration, on the same schedule the camera capture pipeline needs, and
reports any iteration that fell behind its scheduled slot. This reproduces
the conditions from the 2026-08-12 UniversitySidney2 drop-hunt finding
(default vm.dirty_* thresholds letting 400-800 MB of dirty pages build up
before flushing, causing 1.8-2.7 s stalls) so the 99-notavis-writeback.conf
tuning can be proven to prevent it rather than just assumed to.

Files are written into a small ring buffer (default 120 slots) so disk
usage stays bounded regardless of test duration, and cleaned up afterwards
unless --keep-files is given.
"""
import argparse
import os
import statistics
import sys
import time


def read_dirty_writeback_kb():
    dirty = writeback = None
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("Dirty:"):
                dirty = int(line.split()[1])
            elif line.startswith("Writeback:"):
                writeback = int(line.split()[1])
    return dirty, writeback


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dir", default="/mnt/data/io_gap_test")
    ap.add_argument("--rate-hz", type=float, default=60.0)
    ap.add_argument("--duration-sec", type=float, default=600.0)
    ap.add_argument("--size-bytes", type=int, default=1024 * 1024)
    ap.add_argument("--ring", type=int, default=120,
                     help="number of files cycled through, so disk usage stays bounded")
    ap.add_argument("--gap-threshold-ms", type=float, default=50.0,
                     help="scheduling lag beyond this counts as a gap")
    ap.add_argument("--keep-files", action="store_true")
    ap.add_argument("--progress-every-sec", type=float, default=30.0)
    args = ap.parse_args()

    os.makedirs(args.dir, exist_ok=True)
    period = 1.0 / args.rate_hz
    n_iters = int(args.duration_sec * args.rate_hz)
    buf = os.urandom(args.size_bytes)

    durations = []
    gaps = []
    start = time.monotonic()
    next_slot = start
    next_progress = start + args.progress_every_sec

    print(f"Writing {n_iters} x {args.size_bytes / 1024 / 1024:.2f} MiB "
          f"to {args.dir} at {args.rate_hz:.1f} Hz for {args.duration_sec:.0f}s "
          f"(ring={args.ring} files)", flush=True)

    for i in range(n_iters):
        now = time.monotonic()
        if next_slot > now:
            time.sleep(next_slot - now)

        iter_start = time.monotonic()
        path = os.path.join(args.dir, f"frame_{i % args.ring:05d}.bin")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
        try:
            os.write(fd, buf)
        finally:
            os.close(fd)
        iter_end = time.monotonic()

        write_dur = iter_end - iter_start
        durations.append(write_dur)

        lag = iter_end - next_slot
        if lag * 1000.0 > args.gap_threshold_ms:
            dirty_kb, wb_kb = read_dirty_writeback_kb()
            gaps.append((i, iter_start - start, write_dur, lag, dirty_kb, wb_kb))

        next_slot += period

        if iter_end >= next_progress:
            elapsed = iter_end - start
            print(f"  [{elapsed:6.1f}s] {i + 1}/{n_iters} writes, "
                  f"{len(gaps)} gaps so far", flush=True)
            next_progress += args.progress_every_sec

    total = time.monotonic() - start

    if not args.keep_files:
        for j in range(min(args.ring, n_iters)):
            try:
                os.remove(os.path.join(args.dir, f"frame_{j:05d}.bin"))
            except FileNotFoundError:
                pass
        try:
            os.rmdir(args.dir)
        except OSError:
            pass

    durations_ms = sorted(d * 1000 for d in durations)

    def pct(p):
        idx = min(len(durations_ms) - 1, int(len(durations_ms) * p))
        return durations_ms[idx]

    print()
    print(f"Done: {n_iters} writes over {total:.1f}s "
          f"(target {args.duration_sec:.0f}s at {args.rate_hz:.1f} Hz)")
    print(f"Write duration ms: min={min(durations_ms):.2f} "
          f"mean={statistics.mean(durations_ms):.2f} "
          f"p50={pct(0.50):.2f} p95={pct(0.95):.2f} p99={pct(0.99):.2f} "
          f"max={max(durations_ms):.2f}")
    print(f"Gaps (scheduling lag > {args.gap_threshold_ms:.0f} ms): {len(gaps)}")
    if gaps:
        worst = max(gaps, key=lambda g: g[3])
        print(f"Worst gap: iter={worst[0]} t={worst[1]:.2f}s "
              f"write={worst[2] * 1000:.2f}ms lag={worst[3] * 1000:.2f}ms "
              f"(~{worst[3] / period:.1f} frame periods) "
              f"Dirty={worst[4]}kB Writeback={worst[5]}kB")
        print()
        print(f"{'iter':>6} {'t(s)':>8} {'write(ms)':>10} {'lag(ms)':>9} "
              f"{'frames':>7} {'Dirty(kB)':>10} {'Writeback(kB)':>13}")
        for i, t, wd, lag, dkb, wbkb in gaps[:100]:
            print(f"{i:6d} {t:8.2f} {wd * 1000:10.2f} {lag * 1000:9.2f} "
                  f"{lag / period:7.1f} {str(dkb):>10} {str(wbkb):>13}")
        if len(gaps) > 100:
            print(f"  ... and {len(gaps) - 100} more")

    sys.exit(1 if gaps else 0)


if __name__ == "__main__":
    main()
