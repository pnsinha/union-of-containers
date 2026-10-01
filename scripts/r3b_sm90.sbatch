#!/bin/bash
#SBATCH --job-name=r3b_sm90
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=01:00:00
#SBATCH --output=logs/r3b-sm90-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SCRATCH:?export UOC_SCRATCH (filesystem to bind into the container)}"
: "${UOC_SIF:?export UOC_SIF (path to e4s-cuda-26.06-cuda80.sif)}"

# R3b — sm_90 specialized layer (H100 lane) against the CPU provider.
# HASH GUARD: every buildable non-amrex node must hash-match the provider lock.
set +e
U=${UOC_ROOT}
SIF=${UOC_SIF}
ENV=$U/configuration/e4s-26.06/specialized-amrex-sm90
PROV_LOCK=$U/configuration/e4s-26.06/provider-cpu/spack.lock
PROV_GPFS=$U/trees/e4s-provider-cpu
SPEC_GPFS=$U/trees/e4s-specialized-amrex-sm90

mkdir -p "$U/logs"
echo "[R3b START $(date -u)] host=$(hostname) job=$SLURM_JOB_ID"
echo "[PROVENANCE] spack=$(git -C $U/spack-v1.2.1 rev-parse --short HEAD 2>/dev/null) spack-packages=$(git -C $U/spack-packages-e4s-26.06.1 rev-parse --short HEAD 2>/dev/null)"
START=$SECONDS

apptainer exec --bind ${UOC_SCRATCH} --bind "$PROV_GPFS":/tmp/e4s-provider-cpu "$SIF" bash -lc '
  set -e
  . "'"$U"'/spack-v1.2.1/share/spack/setup-env.sh"
  echo "=== CONCRETIZE sm90 (upstreams -> provider) ==="
  spack -e "'"$ENV"'" concretize -f 2>&1 | tail -4
  echo "=== HASH GUARD vs provider lock ==="
  python3 - <<PYEOF
import json, sys
a = json.load(open("'"$ENV"'/spack.lock"))["concrete_specs"]
b = json.load(open("'"$PROV_LOCK"'"))["concrete_specs"]
buildable = {h: s for h, s in a.items() if not s.get("external")}
new = [s["name"] for h, s in buildable.items() if h not in b]
print(f"sm90 nodes={len(a)} buildable={len(buildable)} not-in-provider={new}")
if [n for n in new if n != "amrex"]:
    print("HASH GUARD FAILED"); sys.exit(1)
print("HASH GUARD PASS")
PYEOF
  echo "=== INSTALL sm90 ==="
  spack -e "'"$ENV"'" install -v
'
IR=$?
echo "[INSTALL rc=$IR elapsed=$((SECONDS-START))s]"
if [ $IR -eq 0 ]; then
  rm -rf "$SPEC_GPFS"
  apptainer exec --bind ${UOC_SCRATCH} --bind "$PROV_GPFS":/tmp/e4s-provider-cpu "$SIF" bash -lc '
    cp -a /tmp/e4s-specialized-amrex-sm90 "'"$SPEC_GPFS"'"
  '
  echo "files: $(find $SPEC_GPFS -type f | wc -l)  all-entries: $(find $SPEC_GPFS | wc -l)  apparent: $(du -sh --apparent-size $SPEC_GPFS | cut -f1)"
fi
echo "[R3b DONE $(date -u)] rc=$IR"
exit $IR
