#!/bin/bash
#SBATCH --job-name=r5c_mono80
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=00:45:00
#SBATCH --output=logs/r5c-mono80-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SCRATCH:?export UOC_SCRATCH (filesystem to bind into the container)}"
: "${UOC_SIF:?export UOC_SIF (path to e4s-cuda-26.06-cuda80.sif)}"

# R5c — mono-sm80 comparator benchmark: amrex (a2ugptk) from the R1
# monolithic tree (identical archive bytes to the specialized tree); fftw
# also linked from the provider (R1 env has no fftw; the timed MultiFab loop
# does not touch fftw beyond one malloc/free pair — noted in the record).
set +e
U=${UOC_ROOT}
SIF=${UOC_SIF}
PROV=$U/trees/e4s-provider-cpu
MONO80=$U/trees/e4s-monolithic-amrex-sm80
ST=$U/stage/r5r6
mkdir -p "$ST"

FFTW_INC=/tmp/e4s-provider-cpu/linux-x86_64_v3/fftw-3.3.11-v5yfeyr/include
FFTW_LIBDIR=/tmp/e4s-provider-cpu/linux-x86_64_v3/fftw-3.3.11-v5yfeyr/lib

timeout 1200 apptainer exec --bind ${UOC_SCRATCH} --bind $PROV:/tmp/e4s-provider-cpu --bind $MONO80:/tmp/e4s-monolithic-amrex-sm80 "$SIF" bash -c "
  set -eo pipefail
  export PATH=/tmp/e4s-provider-cpu/linux-x86_64_v3/cmake-3.31.11-brs7nmc/bin:\$PATH
  export CUDACXX=/usr/local/cuda-12.9/bin/nvcc
  MP=/opt/mpi/pkgs/mpich-4.3.2/bin; export CC=\$MP/mpicc CXX=\$MP/mpicxx FC=\$MP/mpifort
  rm -rf $ST/build-mono-sm80
  cmake -S $ST -B $ST/build-mono-sm80 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=/tmp/e4s-monolithic-amrex-sm80/linux-x86_64_v3/amrex-26.06-a2ugptk \
    -DFFTW3_INCLUDE_DIR=$FFTW_INC -DFFTW3_LIB=$FFTW_LIBDIR/libfftw3.so \
    -DCMAKE_BUILD_RPATH='$FFTW_LIBDIR;/tmp/e4s-monolithic-amrex-sm80/linux-x86_64_v3/amrex-26.06-a2ugptk/lib' 2>&1 | tail -2
  cmake --build $ST/build-mono-sm80 -j8 2>&1 | tail -2
"
[ -x "$ST/build-mono-sm80/mfbench" ] && echo "BUILD-MONO-SM80 OK" || echo "BUILD-MONO-SM80 FAILED"
[ -x "$ST/build-mono-sm80/mfbench" ] || exit 1
echo "[R5C DONE $(date -u)]"
