#!/bin/bash
#SBATCH --job-name=r1b_mono90
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=02:00:00
#SBATCH --output=logs/r1b-mono90-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SCRATCH:?export UOC_SCRATCH (filesystem to bind into the container)}"
: "${UOC_SIF:?export UOC_SIF (path to e4s-cuda-26.06-cuda80.sif)}"

# R1b — monolithic sm_90 comparator (H100 lane): amrex+cuda:90 + fftw in ONE
# tree, no upstreams. Deps must hash-match the provider (arch-invariant).
set +e
U=${UOC_ROOT}
SIF=${UOC_SIF}
ENV=$U/configuration/e4s-26.06/monolithic-amrex-sm90
PROV_LOCK=$U/configuration/e4s-26.06/provider-cpu/spack.lock
MONO_GPFS=$U/trees/e4s-monolithic-amrex-sm90

mkdir -p "$U/logs"
echo "[R1b START $(date -u)] host=$(hostname) job=$SLURM_JOB_ID"
echo "[PROVENANCE] spack=$(git -C $U/spack-v1.2.1 rev-parse --short HEAD 2>/dev/null) spack-packages=$(git -C $U/spack-packages-e4s-26.06.1 rev-parse --short HEAD 2>/dev/null)"
START=$SECONDS

apptainer exec --bind ${UOC_SCRATCH} "$SIF" bash -lc '
  set -e
  . "'"$U"'/spack-v1.2.1/share/spack/setup-env.sh"
  echo "=== CONCRETIZE monolithic sm90 (fresh, no upstreams) ==="
  spack -e "'"$ENV"'" concretize -f 2>&1 | tail -4
  echo "=== HASH CHECK vs provider lock (deps should match) ==="
  python3 - <<PYEOF
import json
a = json.load(open("'"$ENV"'/spack.lock"))["concrete_specs"]
b = json.load(open("'"$PROV_LOCK"'"))["concrete_specs"]
buildable = {h: s for h, s in a.items() if not s.get("external")}
nonamrex = {h: s for h, s in buildable.items() if s["name"] != "amrex"}
matched = sum(1 for h in nonamrex if h in b)
print(f"mono-sm90 nodes={len(a)} buildable={len(buildable)} non-amrex={len(nonamrex)} provider-matched={matched}")
PYEOF
  echo "=== INSTALL monolithic sm90 ==="
  spack -e "'"$ENV"'" install -v
'
IR=$?
echo "[INSTALL rc=$IR elapsed=$((SECONDS-START))s]"
if [ $IR -eq 0 ]; then
  rm -rf "$MONO_GPFS"
  apptainer exec --bind ${UOC_SCRATCH} "$SIF" bash -lc '
    cp -a /tmp/e4s-monolithic-amrex-sm90 "'"$MONO_GPFS"'"
  '
  echo "files: $(find $MONO_GPFS -type f | wc -l)  all-entries: $(find $MONO_GPFS | wc -l)  apparent: $(du -sh --apparent-size $MONO_GPFS | cut -f1)"
fi
echo "[R1b DONE $(date -u)] rc=$IR"
exit $IR
