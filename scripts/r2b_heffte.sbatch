#!/bin/bash
#SBATCH --job-name=r2b_heffte
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=01:30:00
#SBATCH --output=logs/r2b-heffte-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${UOC_SCRATCH:?export UOC_SCRATCH (filesystem to bind into the container)}"
: "${UOC_SIF:?export UOC_SIF (path to e4s-cuda-26.06-cuda80.sif)}"

# R2b — Second application specialized layer: heFFTe GPU build reusing the
# 36-package CPU provider. Converts provider breadth (heffte/py-numpy chains)
# from liability into the point: ONE provider serving TWO applications.
# HASH GUARD: every buildable non-heffte node must hash-match the provider lock.
set +e
U=${UOC_ROOT}
SIF=${UOC_SIF}
ENV=$U/configuration/e4s-26.06/specialized-heffte-sm80
PROV_LOCK=$U/configuration/e4s-26.06/provider-cpu/spack.lock
PROV_GPFS=$U/trees/e4s-provider-cpu
SPEC_GPFS=$U/trees/e4s-specialized-heffte-sm80

mkdir -p "$U/logs"
echo "[R2b START $(date -u)] host=$(hostname) job=$SLURM_JOB_ID"
echo "[PROVENANCE] spack=$(git -C $U/spack-v1.2.1 rev-parse --short HEAD 2>/dev/null) spack-packages=$(git -C $U/spack-packages-e4s-26.06.1 rev-parse --short HEAD 2>/dev/null)"
echo "[PROVENANCE] sif_sha16=$(sha256sum $SIF | cut -c1-16)"
START=$SECONDS

apptainer exec --bind ${UOC_SCRATCH} --bind "$PROV_GPFS":/tmp/e4s-provider-cpu "$SIF" bash -lc '
  set -e
  . "'"$U"'/spack-v1.2.1/share/spack/setup-env.sh"
  echo "=== CONCRETIZE heffte+cuda (upstreams -> provider) ==="
  spack -e "'"$ENV"'" concretize -f 2>&1 | tail -6
  echo "=== HASH GUARD vs provider lock ==="
  python3 - <<PYEOF
import json, sys
a = json.load(open("'"$ENV"'/spack.lock"))["concrete_specs"]
b = json.load(open("'"$PROV_LOCK"'"))["concrete_specs"]
sa, sb = set(a), set(b)
buildable = {h: s for h, s in a.items() if not s.get("external")}
new = [s["name"] for h, s in buildable.items() if h not in sb]
ext = sorted({s["name"] for s in a.values() if s.get("external")})
print(f"r2b nodes={len(a)} buildable={len(buildable)} shared-with-provider={len(sa & sb)} externals={ext}")
print(f"buildable nodes NOT in provider lock: {new}")
if [n for n in new if n != "heffte"]:
    print("HASH GUARD FAILED: unexpected new buildable nodes"); sys.exit(1)
print("HASH GUARD PASS")
PYEOF
  echo "=== INSTALL heffte specialized ==="
  spack -e "'"$ENV"'" install -v
'
IR=$?
echo "[INSTALL rc=$IR elapsed=$((SECONDS-START))s]"

if [ $IR -eq 0 ]; then
  echo "=== persist -> $SPEC_GPFS ==="
  rm -rf "$SPEC_GPFS"
  apptainer exec --bind ${UOC_SCRATCH} --bind "$PROV_GPFS":/tmp/e4s-provider-cpu "$SIF" bash -lc '
    cp -a /tmp/e4s-specialized-heffte-sm80 "'"$SPEC_GPFS"'"
  '
  echo "files: $(find $SPEC_GPFS -type f | wc -l)  all-entries: $(find $SPEC_GPFS | wc -l)  dirs: $(find $SPEC_GPFS -type d | wc -l)  symlinks: $(find $SPEC_GPFS -type l | wc -l)  apparent: $(du -sh --apparent-size $SPEC_GPFS | cut -f1)"
  echo "=== reuse markers from this log ([^] reused / [-] built / [e] external) ==="
  grep -cE "^\[\^\]" "$U/logs/r2b-heffte-${SLURM_JOB_ID}.out" | xargs echo "reused [^]:"
  grep -cE "^-  " "$U/logs/r2b-heffte-${SLURM_JOB_ID}.out" | xargs echo "new [-]:"
  grep -cE "^\[e\]" "$U/logs/r2b-heffte-${SLURM_JOB_ID}.out" | xargs echo "external [e]:"
fi
echo "[R2b DONE $(date -u)] rc=$IR"
exit $IR
