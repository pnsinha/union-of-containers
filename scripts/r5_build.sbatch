#!/bin/bash
#SBATCH --job-name=r5_build
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --output=logs/r5-build-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SCRATCH:?export UOC_SCRATCH (filesystem to bind into the container)}"
: "${UOC_SIF:?export UOC_SIF (path to e4s-cuda-26.06-cuda80.sif)}"

# R5 build phase (no GPU needed; nvcc cross-compiles sm_80).
# One parametrized CMakeLists; layered and E4S-native differ only in -D flags.
set +e
U=${UOC_ROOT}
SIF=${UOC_SIF}
PROV=$U/trees/e4s-provider-cpu
SPEC=$U/trees/e4s-specialized-amrex-sm80
ST=$U/stage/r5r6
mkdir -p "$ST"

cp $U/stage/r5r6/mfbench.cu $ST/mfbench.cu

cat > $ST/CMakeLists.txt <<'CML'
cmake_minimum_required(VERSION 3.21)
project(mfbench C CXX CUDA)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_ARCHITECTURES 80)
find_package(AMReX REQUIRED CONFIG)
find_path(FFTW3_INCLUDE_DIR fftw3.h REQUIRED)
find_library(FFTW3_LIB fftw3 REQUIRED)
add_executable(mfbench mfbench.cu)
target_include_directories(mfbench PRIVATE /opt/mpi/pkgs/mpich-4.3.2/include ${FFTW3_INCLUDE_DIR})
target_link_libraries(mfbench PRIVATE AMReX::amrex_3d ${FFTW3_LIB} /opt/mpi/pkgs/mpich-4.3.2/lib/libmpicxx.so /opt/mpi/pkgs/mpich-4.3.2/lib/libmpi.so)
target_compile_options(mfbench PRIVATE $<$<COMPILE_LANGUAGE:CUDA>:--extended-lambda>)
set_target_properties(mfbench PROPERTIES CUDA_SEPARABLE_COMPILATION ON)
CML

FFTW_INC=/tmp/e4s-provider-cpu/linux-x86_64_v3/fftw-3.3.11-v5yfeyr/include
FFTW_LIBDIR=/tmp/e4s-provider-cpu/linux-x86_64_v3/fftw-3.3.11-v5yfeyr/lib
BINDS="--bind ${UOC_SCRATCH} --bind $PROV:/tmp/e4s-provider-cpu --bind $SPEC:/tmp/e4s-specialized-amrex-sm80"

echo "=== R5 BUILD (layered) ==="
timeout 1200 apptainer exec $BINDS "$SIF" bash -c "
  set -eo pipefail
  export PATH=/tmp/e4s-provider-cpu/linux-x86_64_v3/cmake-3.31.11-brs7nmc/bin:\$PATH
  export CUDACXX=/usr/local/cuda-12.9/bin/nvcc
  MP=/opt/mpi/pkgs/mpich-4.3.2/bin; export CC=$MP/mpicc CXX=$MP/mpicxx FC=$MP/mpifort
  rm -rf $ST/build-layered
  cmake -S $ST -B $ST/build-layered \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=/tmp/e4s-specialized-amrex-sm80/linux-x86_64_v3/amrex-26.06-a2ugptk \
    -DFFTW3_INCLUDE_DIR=$FFTW_INC -DFFTW3_LIB=$FFTW_LIBDIR/libfftw3.so \
    -DCMAKE_BUILD_RPATH='$FFTW_LIBDIR;/tmp/e4s-provider-cpu/linux-x86_64_v3/gcc-runtime-13.3.0-p4x6yaa/lib' 2>&1 | tail -3
  cmake --build $ST/build-layered -j8 2>&1 | tail -3
"
if [ -x "$ST/build-layered/mfbench" ]; then echo "R5-LAYERED-BUILD OK"; else echo "R5-LAYERED-BUILD FAILED"; fi

echo "=== R5 BUILD (E4S-native comparator) ==="
IMG_AMREX_CFG=$(timeout 240 apptainer exec --bind ${UOC_SCRATCH} "$SIF" bash -c 'find /spack -name AMReXConfig.cmake 2>/dev/null | head -1')
IMG_FFTW_LIB=$(timeout 240 apptainer exec --bind ${UOC_SCRATCH} "$SIF" bash -c 'find /spack -name "libfftw3.so" 2>/dev/null | head -1')
echo "image AMReXConfig: $IMG_AMREX_CFG"
echo "image fftw lib:    $IMG_FFTW_LIB"
NAT_PREFIX=$(dirname "$(dirname "$(dirname "$IMG_AMREX_CFG")")")
NAT_FFTW=$(dirname "$IMG_FFTW_LIB")
if [ -n "$IMG_AMREX_CFG" ] && [ -n "$IMG_FFTW_LIB" ]; then
  timeout 1200 apptainer exec $BINDS "$SIF" bash -c "
    set -eo pipefail
    export PATH=/tmp/e4s-provider-cpu/linux-x86_64_v3/cmake-3.31.11-brs7nmc/bin:\$PATH
    export CUDACXX=/usr/local/cuda-12.9/bin/nvcc
    MP=/opt/mpi/pkgs/mpich-4.3.2/bin; export CC=$MP/mpicc CXX=$MP/mpicxx FC=$MP/mpifort
    rm -rf $ST/build-native
    cmake -S $ST -B $ST/build-native \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH=$NAT_PREFIX \
      -DFFTW3_INCLUDE_DIR=$NAT_FFTW/../include -DFFTW3_LIB=$IMG_FFTW_LIB \
      -DCMAKE_BUILD_RPATH='$NAT_FFTW' 2>&1 | tail -3
    cmake --build $ST/build-native -j8 2>&1 | tail -3
  "
  if [ -x "$ST/build-native/mfbench" ]; then echo "R5-NATIVE-BUILD OK"; else echo "R5-NATIVE-BUILD FAILED"; fi
else
  echo "R5-NATIVE-BUILD SKIPPED (image amrex/fftw not found)"
fi
echo "[R5 BUILD DONE $(date -u)]"
# gate: dependent run job only fires if both benchmarks exist
[ -x "$ST/build-layered/mfbench" ] || exit 1
[ -x "$ST/build-native/mfbench" ] || [ ! -f /tmp/placeholder ] || exit 1
