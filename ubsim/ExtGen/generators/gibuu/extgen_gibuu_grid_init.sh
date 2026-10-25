#!/bin/bash
#
# ExtGen with GiBUU, grid job part 1: makes the generator file the overlay
# mixer reads (genfile.root.local) by running steps A-D:
#   A. GENIE request generation (EmptyEvent + GENIEGen, GiBUU splines)
#   B. request file (extgen_dump_requests.fcl)
#   C. GiBUU serving (extgen_gibuu_serve.sh) + in-job cross-section check V4
#      (extgen_gibuu_xsec_check.sh)
#   D. merge (extgen_merge.fcl)
# Run as a project.py <initscript> (condor_lar.sh --init-script): it runs in
# the job's work directory after the release is set up and before the stage
# fcls (extgen_overlay_SimInfoMixer.fcl, g4, ...). Any failure exits non-zero,
# or with --soft-fail (grid XMLs) exits 0: condor_lar.sh ends a job at once,
# without its log tarball, when the <initscript> fails; with --soft-fail there
# is no genfile.root.local, so the mixer stage fails and the job ends the
# normal way, logs (extgen_job_summary.txt) included.
#
# Two ways to set the number of generator events N:
#   --nevents N      fixed: everything runs in the <initscript>. N must be at
#                    least the EXT events of every input file (the init script
#                    runs before the job knows its file).
#   --nevents auto   N = the events of this job's EXT file. The <initscript>
#                    only sets up and checks (tarball, tables, seeds) and saves
#                    its settings in ./extgen/; the first stage copies the EXT
#                    file (extgen_ext_copy.fcl), and its <endscript>
#                    extgen_gibuu_grid_continue.sh runs this script with
#                    --continue: count the copy's events, then steps A-D.
#
# Usage:
#   extgen_gibuu_grid_init.sh --stepa-fcl FCL --nevents N|auto
#       --gibuu-tarball TARBALL --gibuu-md5 MD5
#       (--tables STEM | --spline XML [--xsec-table TXT] (--max-table TXT | --flat-max MAX))
#       [--margin 3] [--floor 50] [--ensembles 1000] [--retries 2]
#       [--warn-pull 4] [--fail-pull 8] [--allow-missing-xsec] [--allow-build-mismatch]
#       [--seeds GENIE,MERGE,GIBUU] [--soft-fail]
#
#   FCL        step-A fcl, e.g. extgen_requests_bnb_run4c.fcl
#   N          step-A events (= interactions, one per subrun); must be at least
#              the number of EXT events in an input file, as EXT events left
#              over when the generator events run out are dropped; or auto
#   TARBALL    GiBUU tarball (make_gibuu_tarball.sh): taken from
#              $CONDOR_DIR_INPUT if passed with jobsub -f, else copied with
#              ifdh (/pnfs) or used in place (/cvmfs, local path)
#   MD5        md5sum of the tarball (checked)
#   STEM       table set, e.g. genie/gibuu/gibuu_<version>_<cardhash>: uses
#              STEM_xsec.xml (splines), STEM_xsec.txt (V4) and STEM_max.txt
#   --spline, --xsec-table, --max-table: the three files one by one (tests);
#              without --xsec-table the V4 check is skipped
#   --flat-max MAX: one Max for every request instead of the Max table (tests)
#   Files: a relative path is looked up along FW_SEARCH_PATH (uboonedata);
#   /pnfs paths are copied with ifdh.
#   --seeds    reuse the seeds of an earlier job (from its extgen_job_summary.txt);
#              by default each job draws its seeds from /dev/urandom
#   --soft-fail exit 0 after a failure (see above); for the <initscript>
#   extgen_gibuu_grid_init.sh --continue
#              second half of --nevents auto (see above); N = events of the
#              newest art file in the work directory, counted by the copy
#              stage (TrigReport in the newest larStage*.out) and compared with
#              its sam event_count when samweb is available
#
# Results in the work directory (condor_lar saves them in the job's log
# tarball): genfile.root.local, extgen_job_summary.txt, extgen_requests.txt.gz,
# extgen_served_events.txt.gz, extgen_trial_stats.txt, extgen_serve_summary.txt,
# extgen_xsec_check.txt, extgen_logs.tgz. Intermediate files stay in ./extgen/,
# which condor_lar does not copy.

set -uo pipefail

TOP=$PWD
WORK=$TOP/extgen
SUMMARY=$TOP/extgen_job_summary.txt

log() { echo "extgen_gibuu_grid_init.sh: $*"; }
note() { echo "$*" >> "$SUMMARY"; }

save_logs() {
  [ -d "$WORK" ] || return 0
  (cd "$WORK" && tar -czf "$TOP/extgen_logs.tgz" --ignore-failed-read \
     $(ls *.log 2>/dev/null) $(ls serve/groups/*/gibuu.job serve/groups/*/gibuu.log.gz \
                                   serve/groups/*.log.gz 2>/dev/null)) 2> /dev/null || true
  [ -f "$WORK/serve/serve_summary.txt" ] && cp "$WORK/serve/serve_summary.txt" "$TOP/extgen_serve_summary.txt"
  [ -f "$WORK/serve/trial_stats.txt" ] && cp "$WORK/serve/trial_stats.txt" "$TOP/extgen_trial_stats.txt"
  [ -f "$WORK/requests.txt" ] && gzip -c "$WORK/requests.txt" > "$TOP/extgen_requests.txt.gz"
  [ -f "$WORK/served_events.txt" ] && gzip -c "$WORK/served_events.txt" > "$TOP/extgen_served_events.txt.gz"
  return 0
}

fail() {
  log "ERROR: $*"
  note "status FAIL $*"
  note "end $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rm -f "$TOP/genfile.root.local"
  save_logs
  [ "${SOFT:-0}" -eq 1 ] && { log "--soft-fail: exit 0, the mixer stage will fail"; exit 0; }
  exit 1
}

# local path of a file given as a jobsub -f input, /pnfs path, absolute path,
# or path relative to FW_SEARCH_PATH
fetch() {
  local spec=$1 name
  name=$(basename "$spec")
  if [ -n "${CONDOR_DIR_INPUT:-}" ] && [ -f "$CONDOR_DIR_INPUT/$name" ]; then
    echo "$CONDOR_DIR_INPUT/$name"; return 0
  fi
  case $spec in
    /pnfs/*)
      local a
      for a in 1 2 3; do
        ifdh cp "$spec" "$WORK/$name" >&2 && { echo "$WORK/$name"; return 0; }
        log "ifdh cp $spec failed (attempt $a)" >&2
        sleep $(( 30 * a ))
      done
      return 1 ;;
    /*)
      [ -f "$spec" ] && { echo "$spec"; return 0; }
      return 1 ;;
    *)
      local d
      for d in $(echo "${FW_SEARCH_PATH:-}" | tr ':' ' '); do
        [ -f "$d/$spec" ] && { echo "$d/$spec"; return 0; }
      done
      return 1 ;;
  esac
}

random_seed() {  # in [1, $1]
  local r
  r=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
  echo $(( 1 + r % $1 ))
}

lar_events() {  # number of events lar processed, from its log
  awk '/TrigReport Events total =/ { n = $5 } END { print n + 0 }' "$1"
}

# --- options
STEPA= NEV= TARBALL= MD5= STEM= SPLINE= XSEC= MAXTAB= FLAT=
MARGIN=3 FLOOR=50 ENS=1000 RETRIES=2 WARN=4 FAILPULL=8
ALLOW_MISSING=0 ALLOW_MISMATCH=0 SEEDS= CONTINUE=0 SOFT=0
while [ $# -gt 0 ]; do
  case $1 in
    --continue) CONTINUE=1; shift ;;
    --soft-fail) SOFT=1; shift ;;
    --stepa-fcl) STEPA=$2; shift 2 ;;
    --nevents) NEV=$2; shift 2 ;;
    --gibuu-tarball) TARBALL=$2; shift 2 ;;
    --gibuu-md5) MD5=$2; shift 2 ;;
    --tables) STEM=$2; shift 2 ;;
    --spline) SPLINE=$2; shift 2 ;;
    --xsec-table) XSEC=$2; shift 2 ;;
    --max-table) MAXTAB=$2; shift 2 ;;
    --flat-max) FLAT=$2; shift 2 ;;
    --margin) MARGIN=$2; shift 2 ;;
    --floor) FLOOR=$2; shift 2 ;;
    --ensembles) ENS=$2; shift 2 ;;
    --retries) RETRIES=$2; shift 2 ;;
    --warn-pull) WARN=$2; shift 2 ;;
    --fail-pull) FAILPULL=$2; shift 2 ;;
    --allow-missing-xsec) ALLOW_MISSING=1; shift ;;
    --allow-build-mismatch) ALLOW_MISMATCH=1; shift ;;
    --seeds) SEEDS=$2; shift 2 ;;
    *) echo "extgen_gibuu_grid_init.sh: bad option $1 (see the header of this script)" >&2; exit 1 ;;
  esac
done

if [ "$CONTINUE" -eq 0 ]; then
rm -rf "$WORK"
mkdir -p "$WORK"
{
  echo "# extgen-gibuu-job v1"
  echo "start $(date -u +%Y-%m-%dT%H:%M:%SZ) host $(hostname) cluster ${CLUSTER:-} process ${PROCESS:-}"
  echo "ubsim ${UBSIM_VERSION:-?} uboonecode ${UBOONECODE_VERSION:-?}"
} > "$SUMMARY"

[ -n "$STEPA" ] || fail "--stepa-fcl missing"
[ "$NEV" = auto ] || { [[ "$NEV" =~ ^[0-9]+$ ]] && [ "$NEV" -gt 0 ]; } \
  || fail "--nevents must be a positive integer or auto"
[ -n "$TARBALL" ] && [ -n "$MD5" ] || fail "--gibuu-tarball and --gibuu-md5 are required"
if [ -n "$STEM" ]; then
  SPLINE=${SPLINE:-${STEM}_xsec.xml}
  XSEC=${XSEC:-${STEM}_xsec.txt}
  [ -n "$FLAT" ] || MAXTAB=${MAXTAB:-${STEM}_max.txt}
fi
[ -n "$SPLINE" ] || fail "give --tables or --spline"
[ -n "$MAXTAB" ] || [ -n "$FLAT" ] || fail "give --tables, --max-table or --flat-max"
[ -z "$MAXTAB" ] || [ -z "$FLAT" ] || fail "--max-table and --flat-max exclude each other"
for c in lar extgen_gibuu_serve.sh extgen_gibuu_xsec_check.sh extgen_gibuu_convert; do
  command -v $c > /dev/null || fail "$c not on PATH"
done

# --- seeds: GENIE (step A), merge (azimuth), GiBUU base (serve adds 100 per
# group and 1 per retry). All below 9e8 (HepJamesRandom, PYTHIA's PYR).
if [ -n "$SEEDS" ]; then
  IFS=, read -r SEED_GENIE SEED_MERGE SEED_GIBUU <<< "$SEEDS"
else
  SEED_GENIE=$(random_seed 899999999)
  SEED_MERGE=$(random_seed 899999999)
  SEED_GIBUU=$(random_seed 899900000)
fi
for s in "$SEED_GENIE" "$SEED_MERGE" "$SEED_GIBUU"; do
  [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -gt 0 ] && [ "$s" -lt 900000000 ] || fail "bad seed '$s'"
done
note "seeds $SEED_GENIE,$SEED_MERGE,$SEED_GIBUU"
log "seeds GENIE $SEED_GENIE, merge $SEED_MERGE, GiBUU $SEED_GIBUU"

# --- input files
SPLINE_F=$(fetch "$SPLINE") || fail "spline file $SPLINE not found"
note "spline $SPLINE -> $SPLINE_F"
XSEC_F=
if [ -n "$XSEC" ]; then
  XSEC_F=$(fetch "$XSEC") || fail "cross-section table $XSEC not found"
  note "xsec_table $XSEC -> $XSEC_F"
fi
MAXOPT=()
if [ -n "$MAXTAB" ]; then
  MAX_F=$(fetch "$MAXTAB") || fail "Max table $MAXTAB not found"
  MAXOPT=(-m "$MAX_F" -k "$MARGIN" -f "$FLOOR")
  note "max_table $MAXTAB -> $MAX_F margin $MARGIN floor $FLOOR"
else
  MAXOPT=(-F "$FLAT")
  note "max_flat $FLAT"
fi
TAR_F=$(fetch "$TARBALL") || fail "GiBUU tarball $TARBALL not found"
md5=$(md5sum "$TAR_F" | awk '{print $1}')
[ "$md5" = "$MD5" ] || fail "GiBUU tarball md5 $md5, expected $MD5"
mkdir -p "$WORK/gibuu"
tar -xzf "$TAR_F" -C "$WORK/gibuu" || fail "cannot unpack $TAR_F"
[ "$TAR_F" != "$WORK/$(basename "$TAR_F")" ] || rm -f "$TAR_F"
# condor_lar.sh copies every jobsub -f file into its work directory, from
# where it would go into the job's log tarball (64 MB per job)
[ ! -f "$TOP/$(basename "$TAR_F")" ] || rm -f "$TOP/$(basename "$TAR_F")"
GIBUU_COMMIT=$(awk '/^commit:/ {print $2}' "$WORK/gibuu/BUILD_INFO")
GIBUU_MD5=$(awk '/^GiBUU.x md5:/ {print $3}' "$WORK/gibuu/BUILD_INFO")
note "gibuu_tarball $TARBALL md5 $md5 commit $GIBUU_COMMIT binary_md5 $GIBUU_MD5"
[[ "$GIBUU_MD5" =~ ^[0-9a-f]{32}$ ]] || fail "no GiBUU.x md5 in the tarball's BUILD_INFO"
# the tables must come from this GiBUU build: one of the commit/md5 entries of
# their build line has exactly this binary md5
for t in ${MAX_F:-} $XSEC_F; do
  if grep -q "^# GiBUU build(s):" "$t"; then
    if ! awk -v m="$GIBUU_MD5" '/^# GiBUU build\(s\):/ {
           for (i = 4; i <= NF; i++) { x = $i; gsub(/,/, "", x); sub(/.*\//, "", x); if (x == m) f = 1 } }
         END { exit !f }' "$t"; then
      [ "$ALLOW_MISMATCH" -eq 1 ] || fail "$t was made with another GiBUU build than $GIBUU_MD5"
      note "warning: $t from another GiBUU build (--allow-build-mismatch)"
    fi
  else
    note "warning: $t has no GiBUU build line"
  fi
done
# ... and from the job card script the serving uses (installed next to the serve script)
CARD_MD5=$(md5sum "$(dirname "$(realpath "$(which extgen_gibuu_serve.sh)")")/extgen_gibuu_card.sh" \
           | awk '{print $1}')
note "card_md5 $CARD_MD5"
for t in ${MAX_F:-} $XSEC_F; do
  tcard=$(awk '/^# GiBUU card md5:/ {print $5}' "$t")
  if [ -z "$tcard" ]; then
    note "warning: $t has no card md5 line"
  elif [ "$tcard" != "$CARD_MD5" ]; then
    [ "$ALLOW_MISMATCH" -eq 1 ] || fail "$t was made with job card md5 $tcard, serving uses $CARD_MD5"
    note "warning: $t from another job card (--allow-build-mismatch)"
  fi
done

if [ "$NEV" = auto ]; then
  # the rest runs from the copy stage's <endscript> (--continue)
  declare -p STEPA SPLINE_F XSEC_F MAXOPT ENS RETRIES WARN FAILPULL ALLOW_MISSING \
             SEED_GENIE SEED_MERGE SEED_GIBUU > "$WORK/job.env"
  note "nevents auto (counted after the EXT copy stage)"
  log "setup done; steps A-D follow the EXT copy stage ($(date -u))"
  exit 0
fi

else  # --continue
  [ -f "$WORK/job.env" ] || fail "--continue without a setup (no $WORK/job.env)"
  . "$WORK/job.env"
  log "continuing after the EXT copy stage ($(date -u))"
  EXT=$(ls -t1 *.root 2>/dev/null | egrep -v 'celltree|hist|larlite|larcv|Supplemental|TGraphs' | head -n1)
  [ -n "$EXT" ] || fail "no EXT copy (*.root) in $TOP"
  stagelog=$(ls -t1 larStage*.out 2>/dev/null | head -n1)
  [ -n "$stagelog" ] || fail "no larStage*.out of the copy stage"
  NEV=$(lar_events "$stagelog")
  [ "$NEV" -gt 0 ] || fail "copy stage $stagelog processed no events"
  note "nevents $NEV (copy stage $stagelog, file $EXT)"
  # cross-check with sam (the copy has a new name; the consumed file has the original)
  if command -v samweb > /dev/null && [ -s consumed_files.list ]; then
    for f in $(cat consumed_files.list); do
      sc=$(samweb get-metadata "$f" 2> /dev/null | awk '/^ *Event Count:/ {print $3}')
      if ! [[ "$sc" =~ ^[0-9]+$ ]]; then
        note "sam_event_count $f unknown ('$sc')"
      elif [ "$sc" -ne "$NEV" ]; then
        note "warning: sam event_count $sc for $f, the copy has $NEV (using $NEV)"
      else
        note "sam_event_count $f $sc (agrees)"
      fi
    done
  fi
fi

cd "$WORK" || fail "no $WORK"

# --- A: requests
cat > stepA.fcl <<EOF
#include "$STEPA"
physics.producers.generator.RandomSeed: $SEED_GENIE
physics.producers.generator.XSecTable:  "$SPLINE_F"
services.scheduler.wantSummary: true   # event count for the check below
EOF
note "stepA $STEPA nevents $NEV"
log "step A: lar -c $STEPA -n $NEV ($(date -u))"
lar -c stepA.fcl -n "$NEV" -o stepA.root > stepA.log 2>&1 || fail "step A failed (stepA.log)"
n=$(lar_events stepA.log)
[ "$n" -eq "$NEV" ] || fail "step A made $n events, not $NEV"

# --- B: request file
log "step B: requests.txt"
lar -c extgen_dump_requests.fcl -s stepA.root > dump.log 2>&1 || fail "step B failed (dump.log)"
[ -f requests.txt ] || fail "no requests.txt"
NREQ=$(awk '!/^#/ && NF == 16' requests.txt | wc -l)
nsub=$(awk '!/^#/ && NF == 16 { print $2, $3 }' requests.txt | sort -u | wc -l)
[ "$nsub" -eq "$NEV" ] || fail "requests cover $nsub subruns, not $NEV"
note "requests $NREQ"

# --- C: GiBUU, then the cross-section check
log "step C: GiBUU serving $NREQ requests ($(date -u))"
t0=$(date +%s)
extgen_gibuu_serve.sh -g "$WORK/gibuu" -r requests.txt -s "$SEED_GIBUU" -o serve \
  "${MAXOPT[@]}" -e "$ENS" -R "$RETRIES" > serve.log 2>&1 || fail "step C failed (serve.log)"
note "serve_seconds $(( $(date +%s) - t0 )) groups $(grep -c '^g[0-9]' serve/serve_summary.txt)"
cp serve/served_events.txt served_events.txt
if [ -n "$XSEC_F" ]; then
  xopt=(-w "$WARN" -f "$FAILPULL")
  [ "$ALLOW_MISSING" -eq 0 ] || xopt+=(--allow-missing)
  extgen_gibuu_xsec_check.sh -t serve/trial_stats.txt -x "$XSEC_F" -o "$TOP/extgen_xsec_check.txt" \
    "${xopt[@]}" > xsec_check.log 2>&1
  xs=$?
  cat xsec_check.log
  [ "$xs" -eq 0 ] || fail "cross-section check V4 failed (extgen_xsec_check.txt)"
  note "xsec_check ok"
else
  note "xsec_check skipped (no table)"
fi

# --- D: merge
cat > merge.fcl <<EOF
#include "extgen_merge.fcl"
physics.producers.generator.Seed: $SEED_MERGE
services.scheduler.wantSummary: true
EOF
log "step D: merge ($(date -u))"
lar -c merge.fcl -s stepA.root -o merged.root > merge.log 2>&1 || fail "step D failed (merge.log)"
n=$(lar_events merge.log)
[ "$n" -eq "$NEV" ] || fail "merge wrote $n events, not $NEV"
mv merged.root "$TOP/genfile.root.local" || fail "cannot move the merged file"
rm -f stepA.root

cd "$TOP"
save_logs
note "status OK"
note "end $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "done: genfile.root.local with $NEV events ($(date -u))"
exit 0
