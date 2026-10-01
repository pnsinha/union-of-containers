#!/bin/bash
#SBATCH --job-name=r5b_build
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --output=logs/r5b-build-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SCRATCH:?export UOC_SCRATCH (filesystem to bind into the container)}"
: "${UOC_SIF:?export UOC_SIF (path to e4s-cuda-26.06-cuda80.sif)}"

# R5 (H100 lane) build phase: two mfbench variants for sm_90.
#   layered-sm90: amrex from specialized-sm90 tree + fftw from PROVIDER tree
#   mono-sm90:    amrex + fftw from the monolithic-sm90 tree
set +e
U=${UOC_ROOT}
SIF=${UOC_SIF}
PROV=$U/trees/e4s-provider-cpu
SPEC90=$U/trees/e4s-specialized-amrex-sm90
MONO90=$U/trees/e4s-monolithic-amrex-sm90
ST=$U/stage/r5r6-sm90
mkdir -p "$ST"
cp $U/stage/r5r6/mfbench.cu $ST/mfbench.cu

cat > $ST/CMakeLists.txt <<'CML'
cmake_minimum_required(VERSION 3.21)
project(mfbench C CXX CUDA)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_ARCHITECTURES 90)
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
BINDS="--bind ${UOC_SCRATCH} --bind $PROV:/tmp/e4s-provider-cpu --bind $SPEC90:/tmp/e4s-specialized-amrex-sm90"

SPEC90_AMREX=$(ls -d $SPEC90/linux-x86_64_v3/amrex-* | head -1 | xargs basename)
MONO90_AMREX=$(ls -d $MONO90/linux-x86_64_v3/amrex-* | head -1 | xargs basename)
MONO90_FFTW=$(ls -d $MONO90/linux-x86_64_v3/fftw-* | head -1 | xargs basename)
echo "spec90 amrex prefix: $SPEC90_AMREX"
echo "mono90 amrex prefix: $MONO90_AMREX  fftw prefix: $MONO90_FFTW"

echo "=== BUILD layered-sm90 ==="
timeout 1200 apptainer exec $BINDS "$SIF" bash -c "
  set -eo pipefail
  export PATH=/tmp/e4s-provider-cpu/linux-x86_64_v3/cmake-3.31.11-brs7nmc/bin:\$PATH
  export CUDACXX=/usr/local/cuda-12.9/bin/nvcc
  MP=/opt/mpi/pkgs/mpich-4.3.2/bin; export CC=\$MP/mpicc CXX=\$MP/mpicxx FC=\$MP/mpifort
  rm -rf $ST/build-layered-sm90
  cmake -S $ST -B $ST/build-layered-sm90 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=/tmp/e4s-specialized-amrex-sm90/linux-x86_64_v3/$SPEC90_AMREX \
    -DFFTW3_INCLUDE_DIR=$FFTW_INC -DFFTW3_LIB=$FFTW_LIBDIR/libfftw3.so \
    -DCMAKE_BUILD_RPATH='$FFTW_LIBDIR;/tmp/e4s-provider-cpu/linux-x86_64_v3/gcc-runtime-13.3.0-p4x6yaa/lib' 2>&1 | tail -2
  cmake --build $ST/build-layered-sm90 -j8 2>&1 | tail -2
"
[ -x "$ST/build-layered-sm90/mfbench" ] && echo "BUILD-LAYERED-SM90 OK" || echo "BUILD-LAYERED-SM90 FAILED"

echo "=== BUILD mono-sm90 ==="
timeout 1200 apptainer exec --bind ${UOC_SCRATCH} --bind $MONO90:/tmp/e4s-monolithic-amrex-sm90 --bind $PROV:/tmp/e4s-provider-cpu "$SIF" bash -c "
  set -eo pipefail
  export PATH=/tmp/e4s-provider-cpu/linux-x86_64_v3/cmake-3.31.11-brs7nmc/bin:\$PATH
  export CUDACXX=/usr/local/cuda-12.9/bin/nvcc
  MP=/opt/mpi/pkgs/mpich-4.3.2/bin; export CC=\$MP/mpicc CXX=\$MP/mpicxx FC=\$MP/mpifort
  rm -rf $ST/build-mono-sm90
  cmake -S $ST -B $ST/build-mono-sm90 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=/tmp/e4s-monolithic-amrex-sm90/linux-x86_64_v3/$MONO90_AMREX \
    -DFFTW3_INCLUDE_DIR=/tmp/e4s-monolithic-amrex-sm90/linux-x86_64_v3/$MONO90_FFTW/include \
    -DFFTW3_LIB=/tmp/e4s-monolithic-amrex-sm90/linux-x86_64_v3/$MONO90_FFTW/lib/libfftw3.so \
    -DCMAKE_BUILD_RPATH='/tmp/e4s-monolithic-amrex-sm90/linux-x86_64_v3/$MONO90_FFTW/lib;/tmp/e4s-monolithic-amrex-sm90/linux-x86_64_v3/$MONO90_AMREX/lib' 2>&1 | tail -2
  cmake --build $ST/build-mono-sm90 -j8 2>&1 | tail -2
"
[ -x "$ST/build-mono-sm90/mfbench" ] && echo "BUILD-MONO-SM90 OK" || echo "BUILD-MONO-SM90 FAILED"

[ -x "$ST/build-layered-sm90/mfbench" ] && [ -x "$ST/build-mono-sm90/mfbench" ] || exit 1
echo "[R5B BUILD DONE $(date -u)]"
