#!/bin/bash
#
# Grid job of the GiBUU scan campaign: runs line $PROCESS (+ JOB_OFFSET) of
# the job list (extgen_gibuu_scan_jobs.py) and copies the result,
# scan_<job_index>.tgz, to OUTPUT_DIR with ifdh.
#
# Usage (as the jobsub executable):
#   extgen_gibuu_scan_grid.sh OUTPUT_DIR [JOB_OFFSET]
#
# Input files, passed with jobsub -f (found in $CONDOR_DIR_INPUT):
#   the GiBUU tarball (make_gibuu_tarball.sh; the only *.tar.gz)
#   scan_jobs.txt (the job list)
#
# Example (SL7 container, as the GiBUU binary is built for SL7):
#   jobsub_submit -G uboone -N <number of jobs> \
#     --resource-provides=usage_model=DEDICATED,OPPORTUNISTIC \
#     --singularity-image /cvmfs/singularity.opensciencegrid.org/fermilab/fnal-wn-sl7:latest \
#     --expected-lifetime=4h --memory=2000MB --disk=4GB \
#     -f dropbox://$PWD/gibuu_scan.tar.gz -f dropbox://$PWD/scan_jobs.txt \
#     file://$PWD/extgen_gibuu_scan_grid.sh /pnfs/uboone/scratch/users/$USER/gibuu_scan
# For more than 10000 jobs submit in blocks and pass JOB_OFFSET.

set -uo pipefail

log() { echo "extgen_gibuu_scan_grid.sh: $*"; }
die() { log "ERROR: $*"; exit 1; }

OUTDIR=${1:-}
OFFSET=${2:-0}
[ -n "$OUTDIR" ] || die "usage: $0 OUTPUT_DIR [JOB_OFFSET]"
[ -n "${PROCESS:-}" ] || die "PROCESS not set (not a jobsub job?)"
IDX=$(( PROCESS + OFFSET ))
log "job $IDX (PROCESS $PROCESS) on $(hostname) at $(date -u)"

IN=${CONDOR_DIR_INPUT:-$PWD}
TARBALL=$(ls "$IN"/*.tar.gz 2>/dev/null | head -1)
[ -n "$TARBALL" ] || die "no GiBUU tarball in $IN"
[ -f "$IN/scan_jobs.txt" ] || die "no scan_jobs.txt in $IN"

LINE=$(awk -v i="$IDX" '!/^#/ && $1 == i' "$IN/scan_jobs.txt")
[ -n "$LINE" ] || die "job $IDX not in scan_jobs.txt"
read -r _ TGT NU CUR TRIALS SEED <<< "$LINE"
log "target $TGT nu $NU $CUR, $TRIALS trials per energy, seed $SEED"

if ! command -v ifdh > /dev/null; then
  set +u  # the UPS scripts use unset variables
  source /cvmfs/fermilab.opensciencegrid.org/products/common/etc/setups || die "no UPS"
  setup ifdhc || die "cannot set up ifdhc"
  set -u
fi

WORK=${_CONDOR_SCRATCH_DIR:-$PWD}/extgen_scan_work
mkdir -p "$WORK/gibuu" && tar -xzf "$TARBALL" -C "$WORK/gibuu" || die "cannot unpack $TARBALL"
export TMPDIR=$WORK
G=$WORK/gibuu
NAME=scan_$IDX

"$G/extgen/extgen_gibuu_scan.sh" -g "$G" -t "$TGT" -n "$NU" -c "$CUR" \
  -e "$G/extgen/extgen_gibuu_energies.txt" -N "$TRIALS" -s "$SEED" -o "$WORK/$NAME" \
  || die "scan failed"
echo "job_index $IDX" >> "$WORK/$NAME/extgen_scan.info"
tar -czf "$WORK/$NAME.tgz" -C "$WORK" "$NAME" || die "cannot pack the result"

for attempt in 1 2 3; do
  ifdh cp "$WORK/$NAME.tgz" "$OUTDIR/$NAME.tgz" && { log "copied $NAME.tgz to $OUTDIR"; exit 0; }
  log "ifdh cp failed (attempt $attempt)"
  sleep $(( 30 * attempt ))
done
die "could not copy $NAME.tgz to $OUTDIR"
