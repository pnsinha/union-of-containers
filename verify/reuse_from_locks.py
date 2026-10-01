#!/usr/bin/env python3
"""Recompute the poster's reuse figures from the committed spack.lock files.

For each specialized (or monolithic) environment, a concrete spec counts as
  external  if Spack marks it external (supplied by the base image),
  reused    if the provider lock has the same DAG hash,
  built     otherwise (compiled in this layer).
Reuse = reused / (reused + built), i.e. over buildable packages only.

Usage:  python3 verify/reuse_from_locks.py        (from the repository root)
"""
import json
import pathlib
import sys

ENVS = pathlib.Path(__file__).resolve().parent.parent / "envs"


def specs(env):
    lock = json.loads((ENVS / env / "spack.lock").read_text())
    return lock["concrete_specs"]


def is_external(spec):
    return bool(spec.get("external"))


provider = specs("provider-cpu")
prov_hashes = set(provider)
p_ext = sum(is_external(s) for s in provider.values())
print(f"provider-cpu: {len(provider)} concrete specs = "
      f"{len(provider) - p_ext} buildable + {p_ext} external")
print()
print(f"{'environment':28} {'specs':>5} {'ext':>4} {'reused':>6} {'built':>5}  reuse   built packages")

rc = 0
for env in sorted(p.name for p in ENVS.iterdir() if (p / "spack.lock").exists()):
    if env == "provider-cpu":
        continue
    cs = specs(env)
    ext = [h for h, s in cs.items() if is_external(s)]
    reused = [h for h, s in cs.items() if not is_external(s) and h in prov_hashes]
    built = [h for h, s in cs.items() if not is_external(s) and h not in prov_hashes]
    buildable = len(reused) + len(built)
    pct = 100 * len(reused) / buildable if buildable else 0
    names = ", ".join(sorted(cs[h]["name"] for h in built))
    if env.startswith("monolithic"):
        # no upstream is configured, so every buildable spec is compiled in
        # this tree even where its hash matches the provider's
        print(f"{env:28} {len(cs):>5} {len(ext):>4} {0:>6} {buildable:>5}    0.0%  "
              f"all {buildable} buildable (comparator; {len(reused)} hash-identical to provider)")
        continue
    print(f"{env:28} {len(cs):>5} {len(ext):>4} {len(reused):>6} {len(built):>5}  "
          f"{pct:5.1f}%  {names}")
sys.exit(rc)
