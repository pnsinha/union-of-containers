#!/bin/bash
#SBATCH --job-name=r5r6_h100
#SBATCH --partition=ai
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --gres=gpu:1
#SBATCH --time=00:15:00
#SBATCH --output=logs/r5r6-h100-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SCRATCH:?export UOC_SCRATCH (filesystem to bind into the container)}"
: "${UOC_SIF:?export UOC_SIF (path to e4s-cuda-26.06-cuda80.sif)}"

# R5/R6 (H100 lane) — parity: layered (provider + specialized-sm90) vs
# monolithic-sm90, identical recipes/hashes, only variable = arrangement.
# R6: two containers (mfbench GPU + numpy FFT via provider) live against ONE
# provider concurrently, --contain per-invocation /tmp isolation.
set +e
U=${UOC_ROOT}
SIF=${UOC_SIF}
PROV=$U/trees/e4s-provider-cpu
SPEC90=$U/trees/e4s-specialized-amrex-sm90
MONO90=$U/trees/e4s-monolithic-amrex-sm90
ST=$U/stage/r5r6-sm90

echo "[R5/R6-H100 START $(date -u)] host=$(hostname) job=$SLURM_JOB_ID"
nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader || true

BINDS="--bind ${UOC_SCRATCH} --bind $PROV:/tmp/e4s-provider-cpu --bind $SPEC90:/tmp/e4s-specialized-amrex-sm90"

echo "=== R5 RUN layered-sm90 (5 reps) ==="
for i in 1 2 3 4 5; do
  timeout 180 apptainer exec --nv $BINDS "$SIF" $ST/build-layered-sm90/mfbench 256 500 2>&1 | grep -E "MF-BENCH|rror" | sed "s/^/L-rep$i /"
done
echo "--- resolution evidence (layered) ---"
apptainer exec $BINDS "$SIF" ldd $ST/build-layered-sm90/mfbench 2>/dev/null | grep -E "fftw|amrex|not found" | head -4

echo "=== R5 RUN mono-sm90 (5 reps) ==="
for i in 1 2 3 4 5; do
  timeout 180 apptainer exec --nv --bind ${UOC_SCRATCH} --bind $MONO90:/tmp/e4s-monolithic-amrex-sm90 "$SIF" $ST/build-mono-sm90/mfbench 256 500 2>&1 | grep -E "MF-BENCH|rror" | sed "s/^/M-rep$i /"
done
echo "--- resolution evidence (mono) ---"
apptainer exec --bind ${UOC_SCRATCH} --bind $MONO90:/tmp/e4s-monolithic-amrex-sm90 "$SIF" ldd $ST/build-mono-sm90/mfbench 2>/dev/null | grep -E "fftw|amrex|not found" | head -4

echo "=== R6 CONCURRENCY (two containers, one provider) ==="
cat > $ST/r6-A.sh <<'EOS'
echo "A: pid $$ start=$(date -u +%T)"
touch /tmp/A.marker
ldd ${UOC_ROOT}/stage/r5r6-sm90/build-layered-sm90/mfbench 2>/dev/null | grep -cE "e4s-provider-cpu" | xargs echo "A: cross-tree (provider) resolved deps:"
MFB_STEPS=4000 ${UOC_ROOT}/stage/r5r6-sm90/build-layered-sm90/mfbench
echo "A: rc=$? end=$(date -u +%T)"
EOS
cat > $ST/r6-B.sh <<'EOS'
echo "B: pid $$ start=$(date -u +%T)"
if [ -e /tmp/A.marker ]; then echo "B: TMP-NOT-ISOLATED (/tmp shared with A)"; else echo "B: TMP-ISOLATED (--contain private /tmp)"; fi
SP=$(ls -d /tmp/e4s-provider-cpu/linux-x86_64_v3/py-numpy-*/lib/python3.12/site-packages 2>/dev/null | head -1)
PY=$(command -v python3.12 || command -v python3)
echo "B: python=$PY numpy=$SP"
PYTHONPATH=$SP $PY - <<'PYEOF'
import numpy as np, time
a = np.random.random((2048, 2048))
t0 = time.time()
for _ in range(40):
    b = np.fft.fft2(a)
print("B: NUMPY-FFT ok seconds=%.2f checksum=%.3e" % (time.time() - t0, float(abs(b).sum())))
PYEOF
echo "B: rc=$? end=$(date -u +%T)"
EOS

apptainer exec --contain --nv $BINDS "$SIF" bash $ST/r6-A.sh > $U/logs/r6-A-${SLURM_JOB_ID}.out 2>&1 &
APID=$!
sleep 3
apptainer exec --contain --nv $BINDS "$SIF" bash $ST/r6-B.sh > $U/logs/r6-B-${SLURM_JOB_ID}.out 2>&1 &
BPID=$!
sleep 5
echo "overlap-check:"; ps -o pid,etime,cmd -p $APID,$BPID 2>/dev/null
wait $APID; ARC=$?
wait $BPID; BRC=$?
echo "R6: A rc=$ARC B rc=$BRC"
echo "--- A log ---"; cat $U/logs/r6-A-${SLURM_JOB_ID}.out
echo "--- B log ---"; cat $U/logs/r6-B-${SLURM_JOB_ID}.out
echo "[R5/R6-H100 DONE $(date -u)]"
