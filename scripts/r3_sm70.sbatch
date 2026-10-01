#!/bin/bash
#SBATCH --job-name=r3_sm70
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=01:30:00
#SBATCH --output=logs/r3-sm70-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SCRATCH:?export UOC_SCRATCH (filesystem to bind into the container)}"
: "${UOC_SIF:?export UOC_SIF (path to e4s-cuda-26.06-cuda80.sif)}"

# R3 — sm_70 specialized layer against the same CPU provider (upstreams).
# Only variable vs the sm_80 tree: cuda_arch. Post-run content-diff isolates
# cuda_arch as the sole differing input (same site, same base image, same recipes).
# HASH GUARD: aborts before install unless 23/24 lock hashes match the sm80 lock.
set +e
U=${UOC_ROOT}
SIF=${UOC_SIF}
ENV=$U/configuration/e4s-26.06/specialized-amrex-sm70
SM80_LOCK=$U/configuration/e4s-26.06/specialized-amrex-sm80/spack.lock
PROV_GPFS=$U/trees/e4s-provider-cpu
SPEC_GPFS=$U/trees/e4s-specialized-amrex-sm70

mkdir -p "$U/logs"
echo "[R3 START $(date -u)] host=$(hostname) job=$SLURM_JOB_ID"
echo "[PROVENANCE] spack=$(git -C $U/spack-v1.2.1 rev-parse --short HEAD 2>/dev/null) spack-packages=$(git -C $U/spack-packages-e4s-26.06.1 rev-parse --short HEAD 2>/dev/null)"
echo "[PROVENANCE] sif_sha16=$(sha256sum $SIF | cut -c1-16)"
START=$SECONDS

# NOTE: concretize IN-CONTAINER (os=ubuntu24.04 is hash-relevant; login node
# concretizes os=rocky8 and would silently break upstream reuse).
apptainer exec --bind ${UOC_SCRATCH} --bind "$PROV_GPFS":/tmp/e4s-provider-cpu "$SIF" bash -lc '
  set -e
  . "'"$U"'/spack-v1.2.1/share/spack/setup-env.sh"
  echo "=== CONCRETIZE sm70 (upstreams -> provider) ==="
  spack -e "'"$ENV"'" concretize -f 2>&1 | tail -6
  echo "=== HASH GUARD vs sm80 lock ==="
  python3 - <<PYEOF
import json, sys
a = json.load(open("'"$ENV"'/spack.lock"))["concrete_specs"]
b = json.load(open("'"$SM80_LOCK"'"))["concrete_specs"]
sa, sb = set(a), set(b)
amx = {h for h, s in a.items() if s["name"] == "amrex"}
amx80 = {h for h, s in b.items() if s["name"] == "amrex"}
print(f"sm70 nodes={len(a)} sm80 nodes={len(b)} shared={len(sa & sb)}")
print(f"amrex sm70={sorted(amx)} amrex sm80={sorted(amx80)}")
if not (len(sa & sb) == len(sb) - 1 and amx and not (amx & sb)):
    print("HASH GUARD FAILED: sm70 does not share the sm80 dependency set"); sys.exit(1)
print("HASH GUARD PASS")
PYEOF
  echo "=== INSTALL sm70 ==="
  spack -e "'"$ENV"'" install -v
'
IR=$?
echo "[INSTALL rc=$IR elapsed=$((SECONDS-START))s]"

if [ $IR -eq 0 ]; then
  echo "=== persist -> $SPEC_GPFS ==="
  rm -rf "$SPEC_GPFS"
  apptainer exec --bind ${UOC_SCRATCH} --bind "$PROV_GPFS":/tmp/e4s-provider-cpu "$SIF" bash -lc '
    cp -a /tmp/e4s-specialized-amrex-sm70 "'"$SPEC_GPFS"'"
  '
  echo "files: $(find $SPEC_GPFS -type f | wc -l)  all-entries: $(find $SPEC_GPFS | wc -l)  dirs: $(find $SPEC_GPFS -type d | wc -l)  symlinks: $(find $SPEC_GPFS -type l | wc -l)  apparent: $(du -sh --apparent-size $SPEC_GPFS | cut -f1)"
  echo "=== reuse markers from install log ==="
  grep -cE "^\[\^\]" "$U/logs/r3-sm70-${SLURM_JOB_ID}.out" || true
fi
echo "[R3 DONE $(date -u)] rc=$IR"
exit $IR
