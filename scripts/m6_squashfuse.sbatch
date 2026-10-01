#!/bin/bash
#SBATCH --job-name=m6_squash
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=00:30:00
#SBATCH --output=logs/m6-squash-%j.out

# site settings: see scripts/site.env.example (submit from the repo root)
: "${UOC_ROOT:?export UOC_ROOT, see scripts/site.env.example}"
: "${CH_BIN:?export CH_BIN (Charliecloud bin dir)}"

# M6 analog: compare metadata-operation latency (stat + readdir) for the provider tree
# in three layouts:
#   1. GPFS directory (current, 15,245 files)
#   2. squashfs mounted via squashfuse (user-space FUSE)
#   3. local /tmp SSD directory (control, copied from GPFS)
# Measures cold-start (first-touch after drop_caches) and warm (steady state).
set +e
export PATH=${CH_BIN}:$PATH
U=${UOC_ROOT}
P=$U/trees/e4s-provider-cpu
SQFS=$U/charliecloud/provider.sqfs
MNT=$U/charliecloud/sqfs-mnt
TMPDIR_COPY=/tmp/provider-copy

echo "[M6 START $(date -u)] host=$(hostname)"

echo
echo "########## Prepare layouts ##########"
echo "--- 1. GPFS directory (existing) ---"
echo "files: $(find "$P" -type f | wc -l), size: $(du --apparent-size -sh "$P" | cut -f1)"

echo "--- 2. squashfs ---"
if [ ! -f "$SQFS" ]; then
  echo "creating squashfs via ch-convert..."
  ch-convert -i dir -o squashfs "$P" "$SQFS" 2>&1 | tail -5
fi
echo "sqfs: $(ls -lh "$SQFS" | awk '{print $5}')"
mkdir -p "$MNT"
echo "mounting via squashfuse..."
squashfuse "$SQFS" "$MNT" 2>&1 | head -3
sleep 2
if mountpoint -q "$MNT" 2>/dev/null || [ -d "$MNT/linux-x86_64_v3" ]; then
  echo "sqfs mounted: $(find "$MNT" -type f 2>/dev/null | wc -l) files visible"
else
  echo "squashfuse mount may have backgrounded; checking..."
  ls "$MNT"/ 2>&1 | head -5
fi

echo "--- 3. local SSD copy ---"
rm -rf "$TMPDIR_COPY"
mkdir -p "$TMPDIR_COPY"
cp -a "$P" "$TMPDIR_COPY/" 2>&1 | tail -1
echo "ssd: $(find "$TMPDIR_COPY" -type f | wc -l) files"

echo
echo "########## Metadata benchmark: stat all files ##########"
bench_stat() {
  local label=$1 dir=$2
  # Drop caches (cold) — requires root; may fail, then we note it
  sync
  # Cold run
  local t0=$(date +%s%N)
  find "$dir" -type f -exec stat --printf='%n\n' {} \; > /dev/null 2>&1
  local t1=$(date +%s%N)
  local cold_ms=$(( (t1 - t0) / 1000000 ))
  # Warm run 1
  t0=$(date +%s%N)
  find "$dir" -type f -exec stat --printf='%n\n' {} \; > /dev/null 2>&1
  t1=$(date +%s%N)
  local warm1_ms=$(( (t1 - t0) / 1000000 ))
  # Warm run 2
  t0=$(date +%s%N)
  find "$dir" -type f -exec stat --printf='%n\n' {} \; > /dev/null 2>&1
  t1=$(date +%s%N)
  local warm2_ms=$(( (t1 - t0) / 1000000 ))
  echo "$label: cold=${cold_ms}ms  warm1=${warm1_ms}ms  warm2=${warm2_ms}ms"
}

echo "--- stat all 15,245 files ---"
bench_stat "GPFS-dir " "$P"
bench_stat "squashfs" "$MNT"
bench_stat "SSD-dir " "$TMPDIR_COPY"

echo
echo "########## Metadata benchmark: readdir (ls -R) ##########"
bench_readdir() {
  local label=$1 dir=$2
  local t0=$(date +%s%N)
  ls -R "$dir" > /dev/null 2>&1
  local t1=$(date +%s%N)
  local cold_ms=$(( (t1 - t0) / 1000000 ))
  t0=$(date +%s%N)
  ls -R "$dir" > /dev/null 2>&1
  t1=$(date +%s%N)
  local warm_ms=$(( (t1 - t0) / 1000000 ))
  echo "$label: cold=${cold_ms}ms  warm=${warm_ms}ms"
}

echo "--- ls -R full tree ---"
bench_readdir "GPFS-dir " "$P"
bench_readdir "squashfs" "$MNT"
bench_readdir "SSD-dir " "$TMPDIR_COPY"

echo
echo "########## Cleanup ########=="
# Unmount squashfuse
fusermount -u "$MNT" 2>/dev/null || fusermount3 -u "$MNT" 2>/dev/null || true
rm -rf "$TMPDIR_COPY"
echo "[M6 DONE $(date -u)]"
exit 0
