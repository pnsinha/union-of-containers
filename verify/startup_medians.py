#!/usr/bin/env python3
"""Recompute the startup medians (poster: +26 ms for binding a second tree)
from evidence/logs/r4-startup-20509657-{1..5}.out.

Cold samples: one per array task, but the scheduler packed 5 tasks onto 3 nodes,
so only the first task on each node is a true cold start.
"""
import pathlib
import re
import statistics

LOGS = pathlib.Path(__file__).resolve().parent.parent / "evidence" / "logs"
arms = ("bare", "monolithic", "layered")
cold = {a: [] for a in arms}
warm = {a: [] for a in arms}
for f in sorted(LOGS.glob("r4-startup-20509657-*.out")):
    for line in f.read_text().splitlines():
        kind = "cold" if line.startswith("COLD_MS") else "warm" if line.startswith("WARM_MS") else None
        if kind:
            for a in arms:
                v = int(re.search(rf"{a}=(\d+)", line).group(1))
                (cold if kind == "cold" else warm)[a].append(v)
print(f"{'arm':12} {'cold median':>12} {'warm median':>12} {'n warm':>7}")
for a in arms:
    print(f"{a:12} {statistics.median(cold[a]):>10.0f} ms {statistics.median(warm[a]):>10.0f} ms {len(warm[a]):>7}")
d = statistics.median(warm["layered"]) - statistics.median(warm["monolithic"])
print(f"\nlayered - monolithic (warm): {d:+.0f} ms "
      f"({100*d/statistics.median(warm['monolithic']):+.0f}%)")
