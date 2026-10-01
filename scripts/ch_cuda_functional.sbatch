#!/bin/bash
#SBATCH --job-name=ch_cu_fn
#SBATCH --partition=gpu-debug
#SBATCH --qos=gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --gres=gpu:1
#SBATCH --time=00:15:00
#SBATCH --output=logs/ch-cuda-fn-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SQSH:?export UOC_SQSH (E4S image as squashfs, for Charliecloud)}"
: "${CH_BIN:?export CH_BIN (Charliecloud bin dir)}"

# Charliecloud functional GPU test — bundled libcuda (Julia 610) vs host driver (580).
set +e
export PATH=${CH_BIN}:$PATH
U=${UOC_ROOT}
SQSH=${UOC_SQSH}
JULIA_LIB=/opt/julia-central/depot/artifacts/2c8e4324b86fc70a7c041ce8dc72b5f9b41a7a98/lib

mkdir -p "$U/logs"

# Stage smoke source into the provider tree (already bound at /tmp/e4s-provider-cpu)
cp "$U/apps/gpu-check/cuda_smoke.cu" "$U/trees/e4s-provider-cpu/cuda_smoke.cu"

echo "[START $(date -u)] host=$(hostname)"
echo "=== host GPU + driver ==="
nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader 2>&1
echo "host libcuda: $(readlink -f /usr/lib64/libcuda.so.1 2>/dev/null)"

echo
echo "########## A. bundled libcuda (Julia 610.43.02) ##########"
ch-run -W -t "$SQSH" \
  --bind="$U/trees/e4s-provider-cpu":/tmp/e4s-provider-cpu \
  --bind="$U/trees/e4s-specialized-amrex-sm80":/tmp/e4s-specialized-amrex-sm80 \
  -- /bin/bash -c "unset LD_PRELOAD; cp /tmp/e4s-provider-cpu/cuda_smoke.cu /tmp/smoke.cu; export LD_LIBRARY_PATH=$JULIA_LIB; echo libcuda: \$(ls $JULIA_LIB/libcuda.so* 2>&1 | head -1); /usr/local/cuda-12.9/bin/nvcc -arch=sm_80 -o /tmp/smoke /tmp/smoke.cu 2>&1 | tail -3; echo compile_rc=\$?; echo '--- RUN (bundled 610) ---'; /tmp/smoke 2>&1; echo smoke_exit=\$?" 2>&1 | grep -vE "xalt|LD_PRELOAD.*ignored"

echo
echo "########## B. host driver libcuda (580.105.08) ##########"
HOSTLIB=$(mktemp -d ${UOC_ROOT}/hostcuda.XXXXXX)
cp -a /usr/lib64/libcuda.so.580.105.08 "$HOSTLIB/"
ln -sf libcuda.so.580.105.08 "$HOSTLIB/libcuda.so.1"
ln -sf libcuda.so.580.105.08 "$HOSTLIB/libcuda.so"
ch-run -W -t "$SQSH" \
  --bind="$U/trees/e4s-provider-cpu":/tmp/e4s-provider-cpu \
  --bind="$U/trees/e4s-specialized-amrex-sm80":/tmp/e4s-specialized-amrex-sm80 \
  --bind="$HOSTLIB":/hostlibs \
  -- /bin/bash -c "unset LD_PRELOAD; cp /tmp/e4s-provider-cpu/cuda_smoke.cu /tmp/smoke.cu; export LD_LIBRARY_PATH=/hostlibs; echo libcuda: \$(ls /hostlibs/libcuda.so* 2>&1 | head -1); /usr/local/cuda-12.9/bin/nvcc -arch=sm_80 -o /tmp/smoke /tmp/smoke.cu 2>&1 | tail -3; echo compile_rc=\$?; echo '--- RUN (host 580) ---'; /tmp/smoke 2>&1; echo smoke_exit=\$?" 2>&1 | grep -vE "xalt|LD_PRELOAD.*ignored"
rm -rf "$HOSTLIB"

# Cleanup staged file
rm -f "$U/trees/e4s-provider-cpu/cuda_smoke.cu"
echo "[DONE $(date -u)]"
exit 0
