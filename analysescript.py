import os, re, statistics, subprocess, sys
from pathlib import Path

THROTTLE_BITS = {
    0:  "Under-voltage detected",
    1:  "Arm frequency capped",
    2:  "Currently throttled",
    3:  "Soft temperature limit active",
    16: "Under-voltage has occurred",
    17: "Arm frequency capping has occurred",
    18: "Throttling has occurred",
    19: "Soft temperature limit has occurred",
}

def vcgencmd(*args):
    try:
        out = subprocess.run(["vcgencmd", *args], capture_output=True, text=True, timeout=2)
        return out.stdout.strip() if out.returncode == 0 else None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None

def read_temp_c():
    raw = vcgencmd("measure_temp")
    if raw and "=" in raw:
        return float(raw.split("=")[1].rstrip("'C"))
    return None

def read_throttled():
    raw = vcgencmd("get_throttled")
    if not raw or "=" not in raw:
        return None
    mask = int(raw.split("=")[1], 16)
    return mask, [msg for bit, msg in THROTTLE_BITS.items() if mask & (1 << bit)]

folder = Path(sys.argv[1] if len(sys.argv) > 1 else "/mnt/data")
pat = re.compile(r"^frame_(\d+)_(\d{6})\.(?:jpg|jpeg|png|bmp)$", re.I)

ts = []
skipped = 0
for e in os.scandir(folder):
    if not e.is_file():
        continue
    m = pat.match(e.name)
    if m:
        ts.append(int(m.group(1)) + int(m.group(2)) / 1_000_000)
    else:
        skipped += 1

if len(ts) < 2:
    print(f"ERROR: need >=2 frame files in {folder} (found {len(ts)})")
    sys.exit(2)

ts.sort()
diffs = [ts[i+1] - ts[i] for i in range(len(ts) - 1)]
med = statistics.median(diffs)
gap_thr = max(0.050, med * 2.5)

normal = [d for d in diffs if d < gap_thr]
gaps   = [d for d in diffs if d >= gap_thr]
mean = statistics.fmean(normal) if normal else med
sd   = statistics.pstdev(normal) if len(normal) > 1 else 0.0

span   = ts[-1] - ts[0]
active = span - sum(max(0.0, g - med) for g in gaps)
gross  = (len(ts) - 1) / span if span > 0 else 0
eff    = (len(ts) - 1) / active if active > 0 else 0
nom    = 1 / med if med > 0 else 0
dropped = sum(max(0, round(g/med) - 1) for g in gaps)

print(f"Folder:       {folder}")
print(f"Files:        {len(ts)}  (skipped {skipped} non-matching)")
print(f"Time span:    {span:.3f} s  ({ts[0]:.3f} .. {ts[-1]:.3f})")
print()
print(f"Nominal FPS:  {nom:6.2f}   (median interval {med*1000:.2f} ms)")
print(f"Effective FPS:{eff:6.2f}   (excl. drop windows)")
print(f"Gross FPS:    {gross:6.2f}   (files / total span)")
print()
print(f"Interval:     mean {mean*1000:.2f} ms  sigma {sd*1000:.2f} ms  "
      f"min {min(diffs)*1000:.2f}  max {max(diffs)*1000:.2f}")
print(f"Gaps > {gap_thr*1000:.0f} ms: {len(gaps)}  "
      f"(dropped ~{dropped} frames, total {sum(gaps)*1000:.0f} ms)")
if gaps:
    top = sorted(gaps, reverse=True)[:5]
    print(f"Top gaps:     " + ", ".join(f"{g*1000:.0f} ms" for g in top))

print()
temp = read_temp_c()
print(f"SoC temp:     {temp:.1f} C" if temp is not None else "SoC temp:     n/a (vcgencmd not available)")

throttled = read_throttled()
if throttled is None:
    print("Throttled:    n/a (vcgencmd not available)")
else:
    mask, flags = throttled
    print(f"Throttled:    0x{mask:x}" + ("  (clean)" if not flags else ""))
    for flag in flags:
        print(f"              - {flag}")
