#!/bin/bash
#SBATCH --job-name=r6_overlap
#SBATCH --partition=gpu
#SBATCH --qos=gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --gres=gpu:1
#SBATCH --time=00:10:00
#SBATCH --output=logs/r6-overlap-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SCRATCH:?export UOC_SCRATCH (filesystem to bind into the container)}"
: "${UOC_SIF:?export UOC_SIF (path to e4s-cuda-26.06-cuda80.sif)}"

# R6-overlap: prove SIMULTANEOUS execution of two containers against one
# provider. A runs long enough (~55 s: 250k steps at ~0.22 us/step on A100)
# that B provably runs inside A's lifetime; ps snapshots every 5 s.
set +e
U=${UOC_ROOT}
SIF=${UOC_SIF}
PROV=$U/trees/e4s-provider-cpu
SPEC=$U/trees/e4s-specialized-amrex-sm80
ST=$U/stage/r5r6

BINDS="--bind ${UOC_SCRATCH} --bind $PROV:/tmp/e4s-provider-cpu --bind $SPEC:/tmp/e4s-specialized-amrex-sm80"

cat > $ST/r6-A2.sh <<'EOS'
echo "A: pid $$ start=$(date -u +%T)"
touch /tmp/A.marker
ldd ${UOC_ROOT}/stage/r5r6/build-layered/mfbench 2>/dev/null | grep -cE "e4s-provider-cpu" | xargs echo "A: cross-tree (provider) resolved deps:"
MFB_N=256 MFB_STEPS=250000 ${UOC_ROOT}/stage/r5r6/build-layered/mfbench
echo "A: rc=$? end=$(date -u +%T)"
EOS
cat > $ST/r6-B2.sh <<'EOS'
echo "B: pid $$ start=$(date -u +%T)"
[ -e /tmp/A.marker ] && echo "B: TMP-NOT-ISOLATED" || echo "B: TMP-ISOLATED (--contain private /tmp)"
SP=$(ls -d /tmp/e4s-provider-cpu/linux-x86_64_v3/py-numpy-*/lib/python3.12/site-packages 2>/dev/null | head -1)
PY=$(command -v python3.12 || command -v python3)
echo "B: python=$PY numpy=$SP"
for r in 1 2 3; do
  PYTHONPATH=$SP $PY - <<'PYEOF'
import numpy as np, time
a = np.random.random((2048, 2048))
t0 = time.time()
for _ in range(40):
    b = np.fft.fft2(a)
print("B: NUMPY-FFT round ok seconds=%.2f checksum=%.3e" % (time.time() - t0, float(abs(b).sum())))
PYEOF
  sleep 8
done
echo "B: rc=$? end=$(date -u +%T)"
EOS

echo "[R6-OVERLAP START $(date -u)] host=$(hostname) job=$SLURM_JOB_ID"
nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader || true

apptainer exec --contain --nv $BINDS "$SIF" bash $ST/r6-A2.sh > $U/logs/r6-A2-${SLURM_JOB_ID}.out 2>&1 &
APID=$!
sleep 5
apptainer exec --contain --nv $BINDS "$SIF" bash $ST/r6-B2.sh > $U/logs/r6-B2-${SLURM_JOB_ID}.out 2>&1 &
BPID=$!

BOTH=0
for s in $(seq 1 14); do
  sleep 5
  A_ALIVE=$(ps -p $APID -o pid= 2>/dev/null | wc -l)
  B_ALIVE=$(ps -p $BPID -o pid= 2>/dev/null | wc -l)
  echo "sample $s (+$((s*5+5))s): A_alive=$A_ALIVE B_alive=$B_ALIVE"
  [ "$A_ALIVE" = "1" ] && [ "$B_ALIVE" = "1" ] && BOTH=$((BOTH+1))
done
wait $APID; ARC=$?
wait $BPID; BRC=$?
echo "R6-OVERLAP: both-alive samples=$BOTH/14  A rc=$ARC B rc=$BRC"
[ "$BOTH" -ge 3 ] && echo "OVERLAP-CONFIRMED" || echo "OVERLAP-NOT-CONFIRMED"
echo "--- A log ---"; grep -E "^A:|MF-BENCH" $U/logs/r6-A2-${SLURM_JOB_ID}.out
echo "--- B log ---"; grep -E "^B:" $U/logs/r6-B2-${SLURM_JOB_ID}.out
echo "[R6-OVERLAP DONE $(date -u)]"
