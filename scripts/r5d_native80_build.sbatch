#!/bin/bash
#SBATCH --job-name=r5d_native
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=00:45:00
#SBATCH --output=logs/r5d-native-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SCRATCH:?export UOC_SCRATCH (filesystem to bind into the container)}"
: "${UOC_SIF:?export UOC_SIF (path to e4s-cuda-26.06-cuda80.sif)}"

# R5d — rebuild E4S-native comparator with patched mfbench (known-good manual
# procedure: image paths discovered first, unquoted RPATH, full error output).
set +e
U=${UOC_ROOT}
SIF=${UOC_SIF}
PROV=$U/trees/e4s-provider-cpu
ST=$U/stage/r5r6

IMG_AMREX_CFG=$(timeout 240 apptainer exec --bind ${UOC_SCRATCH} "$SIF" bash -c 'find /spack -name AMReXConfig.cmake 2>/dev/null | head -1')
IMG_FFTW_LIB=$(timeout 240 apptainer exec --bind ${UOC_SCRATCH} "$SIF" bash -c 'find /spack -name "libfftw3.so" 2>/dev/null | head -1')
NAT_PREFIX=$(dirname "$(dirname "$(dirname "$IMG_AMREX_CFG")")")
NAT_FFTW=$(dirname "$IMG_FFTW_LIB")
echo "AMReXConfig=$IMG_AMREX_CFG"; echo "fftw=$IMG_FFTW_LIB"

timeout 1200 apptainer exec --bind ${UOC_SCRATCH} --bind $PROV:/tmp/e4s-provider-cpu "$SIF" bash -c "
  set -eo pipefail
  export PATH=/tmp/e4s-provider-cpu/linux-x86_64_v3/cmake-3.31.11-brs7nmc/bin:\$PATH
  export CUDACXX=/usr/local/cuda-12.9/bin/nvcc
  MP=/opt/mpi/pkgs/mpich-4.3.2/bin; export CC=\$MP/mpicc CXX=\$MP/mpicxx FC=\$MP/mpifort
  rm -rf $ST/build-native
  cmake -S $ST -B $ST/build-native \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=$NAT_PREFIX \
    -DFFTW3_INCLUDE_DIR=$NAT_FFTW/../include -DFFTW3_LIB=$IMG_FFTW_LIB \
    -DCMAKE_BUILD_RPATH=$NAT_FFTW 2>&1 | tail -4
  cmake --build $ST/build-native -j8 2>&1 | tail -4
"
[ -x "$ST/build-native/mfbench" ] && echo "BUILD-NATIVE OK" || echo "BUILD-NATIVE FAILED"
