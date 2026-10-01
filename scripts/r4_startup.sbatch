#!/bin/bash
#SBATCH --job-name=r4_startup
#SBATCH --array=1-5
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=00:20:00
#SBATCH --output=logs/r4-startup-%A-%a.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SCRATCH:?export UOC_SCRATCH (filesystem to bind into the container)}"
: "${UOC_SIF:?export UOC_SIF (path to e4s-cuda-26.06-cuda80.sif)}"

# R4 — Startup cost, cold and warm. Each array task lands on a fresh node
# (verify via hostname) => one cold sample per task; warm = 10 in-task repeats.
# Order: COLD bare (container start) first, then COLD layered / COLD monolithic
# (tree pages still cold, container start warm). Record and report as such.
set +e
U=${UOC_ROOT}
SIF=${UOC_SIF}
PROV=$U/trees/e4s-provider-cpu
HEF=$U/trees/e4s-specialized-heffte-sm80
MONO=$U/trees/e4s-monolithic-amrex-sm80
HEF_CANON=$(cd $HEF && find . -name libheffte.so.2.4.1 | head -1 | sed "s|^\./|/tmp/e4s-specialized-heffte-sm80/|")
MONO_CANON=$(cd $MONO && find . -name "libz.so*" -type f | head -1 | sed "s|^\./|/tmp/e4s-monolithic-amrex-sm80/|")

ms() { local s e; s=$(date +%s%N); "$@" >/dev/null 2>&1; e=$(date +%s%N); echo $(( (e-s)/1000000 )); }
exec_bare()    { apptainer exec --bind ${UOC_SCRATCH} "$SIF" true; }
exec_layered() { apptainer exec --bind ${UOC_SCRATCH} --bind "$PROV":/tmp/e4s-provider-cpu --bind "$HEF":/tmp/e4s-specialized-heffte-sm80 "$SIF" ldd "$HEF_CANON"; }
exec_mono()    { apptainer exec --bind ${UOC_SCRATCH} --bind "$MONO":/tmp/e4s-monolithic-amrex-sm80 "$SIF" ldd "$MONO_CANON"; }

echo "[R4 task $SLURM_ARRAY_TASK_ID node=$(hostname) start=$(date -u)]"
echo "heflib=$HEF_CANON  monolib=$MONO_CANON"
RES=$(apptainer exec --bind ${UOC_SCRATCH} --bind "$PROV":/tmp/e4s-provider-cpu --bind "$HEF":/tmp/e4s-specialized-heffte-sm80 "$SIF" ldd "$HEF_CANON" 2>/dev/null | grep -c "/tmp/e4s-provider-cpu")
echo "provider-resolved-deps=$RES (sanity, expect >=2)"

C_BARE=$(ms exec_bare); C_LAYERED=$(ms exec_layered); C_MONO=$(ms exec_mono)
echo "COLD_MS bare=$C_BARE layered=$C_LAYERED monolithic=$C_MONO"
for i in $(seq 1 10); do
  echo "WARM_MS i=$i bare=$(ms exec_bare) layered=$(ms exec_layered) monolithic=$(ms exec_mono)"
done
echo "[R4 task $SLURM_ARRAY_TASK_ID done $(date -u)]"
