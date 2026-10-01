#!/bin/bash
#SBATCH --job-name=r1_mono
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=02:00:00
#SBATCH --output=logs/r1-monolithic-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SCRATCH:?export UOC_SCRATCH (filesystem to bind into the container)}"
: "${UOC_SIF:?export UOC_SIF (path to e4s-cuda-26.06-cuda80.sif)}"

# R1 — Same-scope monolithic baseline on Anvil.
# Lock-copied from specialized-amrex-sm80 (identical 24-spec DAG, identical hashes),
# built standalone in ONE tree with no upstreams. Answers the "~5k inode delta"
# reviewer item: after this run, layered-vs-monolithic differs only in arrangement.
set +e
U=${UOC_ROOT}
SIF=${UOC_SIF}
ENV=$U/configuration/e4s-26.06/monolithic-amrex-sm80
MONO_GPFS=$U/trees/e4s-monolithic-amrex-sm80

mkdir -p "$U/logs"
echo "[R1 START $(date -u)] host=$(hostname) job=$SLURM_JOB_ID"
echo "[PROVENANCE] spack=$(git -C $U/spack-v1.2.1 rev-parse --short HEAD 2>/dev/null) spack-packages=$(git -C $U/spack-packages-e4s-26.06.1 rev-parse --short HEAD 2>/dev/null)"
echo "[PROVENANCE] sif_sha16=$(sha256sum $SIF | cut -c1-16)"
START=$SECONDS

apptainer exec --bind ${UOC_SCRATCH} "$SIF" bash -lc '
  set -e
  . "'"$U"'/spack-v1.2.1/share/spack/setup-env.sh"
  echo "=== spack $(spack --version), in-container $(grep PRETTY_NAME /etc/os-release) ==="
  echo "=== INSTALL monolithic (lock-copied, no upstreams) ==="
  spack -e "'"$ENV"'" install -v
'
IR=$?
echo "[INSTALL rc=$IR elapsed=$((SECONDS-START))s]"

if [ $IR -eq 0 ]; then
  echo "=== persist /tmp/e4s-monolithic-amrex-sm80 -> $MONO_GPFS ==="
  rm -rf "$MONO_GPFS"
  apptainer exec --bind ${UOC_SCRATCH} "$SIF" bash -lc '
    cp -a /tmp/e4s-monolithic-amrex-sm80 "'"$MONO_GPFS"'"
  '
  echo "=== footprint (files convention + full breakdown) ==="
  for t in "$MONO_GPFS"; do
    echo "tree: $t"
    echo "  files:        $(find $t -type f | wc -l)"
    echo "  all-entries:  $(find $t | wc -l)"
    echo "  dirs:         $(find $t -type d | wc -l)"
    echo "  symlinks:     $(find $t -type l | wc -l)"
    echo "  apparent:     $(du -sh --apparent-size $t | cut -f1)"
    echo "  tar-sum:      $(tar -C $t -cf - . | wc -c)"
  done
  echo "=== per-prefix file counts ==="
  for d in "$MONO_GPFS"/linux-x86_64_v3/*/; do
    printf "%s %s\n" "$(basename $d)" "$(find $d -type f | wc -l)"
  done | sort -k2 -n | tee "$U/logs/r1-prefixes-${SLURM_JOB_ID}.txt"
  echo "=== metadata (non-prefix entries) ==="
  echo "  .spack-db files: $(find $MONO_GPFS/.spack-db -type f 2>/dev/null | wc -l)"
fi
echo "[R1 DONE $(date -u)] rc=$IR"
exit $IR
