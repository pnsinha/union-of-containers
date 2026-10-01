#!/bin/bash
#SBATCH --job-name=u_specialized
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=01:30:00
#SBATCH --output=logs/specialized-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SCRATCH:?export UOC_SCRATCH (filesystem to bind into the container)}"
: "${UOC_SIF:?export UOC_SIF (path to e4s-cuda-26.06-cuda80.sif)}"

# Stage 2 — Build GPU specialized (Layer 2), reuses CPU provider via upstreams.
# cuda_arch=80 (A100). Canonical /tmp/e4s-specialized-amrex-sm80; persisted to GPFS.
set +e
U=${UOC_ROOT}
SIF=${UOC_SIF}
ENV=$U/configuration/e4s-26.06/specialized-amrex-sm80
PROV_GPFS=$U/trees/e4s-provider-cpu
SPEC_GPFS=$U/trees/e4s-specialized-amrex-sm80

mkdir -p "$U/logs" "$U/stage"

echo "[SPECIALIZED START $(date -u)] host=$(hostname) SLURM_JOB_ID=$SLURM_JOB_ID"
# Bind: GPFS provider copy -> canonical /tmp/e4s-provider-cpu so upstream DB + RPATH resolve.
apptainer exec --bind ${UOC_SCRATCH} --bind "$PROV_GPFS":/tmp/e4s-provider-cpu "$SIF" bash -lc '
  set -e
  . "'"$U"'/spack-v1.2.1/share/spack/setup-env.sh"
  spack compiler find >/dev/null 2>&1 || true
  echo "=== upstream check: provider readable at /tmp/e4s-provider-cpu ==="
  ls /tmp/e4s-provider-cpu/.spack-db/index.json 2>&1
  echo "=== CONCRETIZE (specialized, upstreams -> provider) ==="
  spack -e "'"$ENV"'" concretize -f 2>&1 | tee ${UOC_ROOT}/logs/concretize-specialized.txt | tail -8
  echo "=== INSTALL (specialized) ==="
  spack -e "'"$ENV"'" install -v
  IR=$?
  echo "=== spack install exit=$IR ==="
  echo "=== footprint (inodes/size) ==="
  find /tmp/e4s-specialized-amrex-sm80 -type f | wc -l | xargs echo "files:"
  du -sh /tmp/e4s-specialized-amrex-sm80 2>/dev/null
  exit $IR
'
IR=$?
echo "[INSTALL rc=$IR $(date -u)]"

# Persist specialized tree to GPFS immediately on success.
if [ $IR -eq 0 ]; then
  echo "=== persist /tmp/e4s-specialized-amrex-sm80 -> $SPEC_GPFS ==="
  rm -rf "$SPEC_GPFS"
  apptainer exec --bind ${UOC_SCRATCH} --bind "$PROV_GPFS":/tmp/e4s-provider-cpu "$SIF" bash -lc '
    cp -a /tmp/e4s-specialized-amrex-sm80 "'"$SPEC_GPFS"'"
    echo "GPFS copy: $(du -sh '"$SPEC_GPFS"' | cut -f1), $(find '"$SPEC_GPFS"' -type f | wc -l) files"
  '
fi

# Non-fatal verify: amrex CUDA device code + cross-tree RPATH.
if [ $IR -eq 0 ]; then
  echo "=== VERIFY: amrex lib (CUDA build, RPATH -> both trees) ==="
  apptainer exec --bind ${UOC_SCRATCH} --bind "$PROV_GPFS":/tmp/e4s-provider-cpu "$SIF" bash -lc '
    BIN=$(find '"$SPEC_GPFS"' -name "libamrex_*.so" 2>/dev/null | head -1)
    echo "binary: $BIN"
    [ -n "$BIN" ] && readelf -d "$BIN" | grep -iE "runpath|rpath" || echo "(no libamrex .so found)"
  ' || echo "(verify non-fatal)"
fi

echo "[SPECIALIZED DONE $(date -u)] rc=$IR"
exit $IR
