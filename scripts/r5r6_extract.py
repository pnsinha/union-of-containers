#!/usr/bin/env python3
"""Extract R5/R6 results from an r5r6_a100 job log into a markdown block.

Usage: r5r6_extract.py <jobid>
Reads r5r6-a100-<jobid>.out plus logs/r6-{A,B}-<jobid>.out
"""
import os
import re
import statistics
import sys
from pathlib import Path

# logs directory: $UOC_LOGS if set, else this repository's evidence/logs
LOGS = Path(os.environ.get("UOC_LOGS", Path(__file__).resolve().parent.parent / "evidence" / "logs"))
job = sys.argv[1]
main = (LOGS / f"r5r6-a100-{job}.out").read_text(errors="replace")

print(f"## R5/R6 results — job {job}\n")
host = re.search(r"host=(\S+)", main)
gpu = re.search(r"NVIDIA [^,]+, [^,]+, [^,\n]+", main)
print(f"- Host: {host.group(1) if host else '?'}; GPU: {gpu.group(0) if gpu else '?'}\n")

arm_re = re.compile(r"^([LMN])-rep(\d) .*MF-BENCH n=(\d+) steps=(\d+) time_s=([0-9.eE+-]+) checksum=([0-9.eE+-]+)")
arms = {}
for line in main.splitlines():
    m = arm_re.match(line)
    if m:
        arms.setdefault(m.group(1), []).append(
            (int(m.group(3)), int(m.group(4)), float(m.group(5)), float(m.group(6)))
        )

names = {"L": "layered-sm80", "M": "mono-sm80", "N": "E4S-native"}
print("| arm | reps | n | steps | median time_s | times | checksums match |")
print("|---|---|---|---|---|---|---|")
for arm in "LMN":
    rs = arms.get(arm, [])
    if not rs:
        print(f"| {arm} ({names[arm]}) | **NO DATA** | | | | | |")
        continue
    ts = [r[2] for r in rs]
    sums = {round(r[3], 3) for r in rs}
    ok = "yes" if len(sums) == 1 else f"NO ({sorted(sums)})"
    print(
        f"| {arm} ({names[arm]}) | {len(rs)} | {rs[0][0]} | {rs[0][1]} "
        f"| **{statistics.median(ts):.3f}** | {', '.join(f'{t:.3f}' for t in ts)} | {ok} |"
    )

# cross-arm checksum equality (same computation must give same result)
if all(a in arms for a in "LM") and arms["L"] and arms["M"]:
    cl = round(arms["L"][0][3], 3)
    cm = round(arms["M"][0][3], 3)
    print(f"\nL vs M checksum: {cl} vs {cm} -> {'IDENTICAL computation' if cl == cm else 'DIFFER — investigate'}")

print("\n### R6 concurrency")
overlap = re.search(r"overlap-check:.*?(?=R6:)", main, re.S)
if overlap:
    seg = overlap.group(0)
    pids = re.findall(r"^\s*(\d+)\s+(\S+)\s+Apptainer", seg, re.M)
    print(f"- Overlap check: {len(pids)} apptainer processes visible simultaneously"
          + (f" (pids {', '.join(p for p, _ in pids)})" if pids else ""))
rcs = re.search(r"R6: A rc=(\d+) B rc=(\d+)", main)
if rcs:
    print(f"- A rc={rcs.group(1)}, B rc={rcs.group(2)}")

for tag in "AB":
    f = LOGS / f"r6-{tag}-{job}.out"
    if f.exists():
        for line in f.read_text(errors="replace").splitlines():
            if re.match(r"^[AB]: ", line) or "MF-BENCH" in line:
                print(f"- {line.strip()}")
