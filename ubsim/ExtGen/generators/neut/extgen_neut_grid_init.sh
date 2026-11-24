#!/bin/bash
#
# ExtGen with NEUT, grid job part 1: makes the generator file the overlay
# mixer reads (genfile.root.local) by running steps A-D:
#   A. GENIE request generation (EmptyEvent + GENIEGen, NEUT splines,
#      tune NE06_02a_00_000: extgen_requests_neut_*.fcl)
#   B. request file (extgen_dump_requests.fcl)
#   C. NEUT serving (extgen_neut_serve.sh) + in-job cross-section check V4
#      (extgen_gibuu_xsec_check.sh, which reads any generator's trial
#      statistics)
#   D. merge (extgen_merge.fcl)
# The NEUT counterpart of extgen_nuwro_grid_init.sh: the same steps, files
# and options, except the generator tarball and its checks, and no Max
# tables (NEUT events are unweighted at a given energy). NEUT runs with the
# e26 ROOT of its build in a clean subshell (extgen_neut_run.sh); the setup
# checks that environment before the job goes on.
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
#                    extgen_neut_grid_continue.sh runs this script with
#                    --continue: count the copy's events, then steps A-D.
#
# Usage:
#   extgen_neut_grid_init.sh --stepa-fcl FCL --nevents N|auto
#       --neut-tarball TARBALL --neut-md5 MD5
#       (--tables STEM | --spline XML [--xsec-table TXT])
#       [--retries 2]
#       [--warn-pull 4] [--fail-pull 8] [--allow-missing-xsec] [--allow-build-mismatch]
#       [--gen-flavors LIST] [--current CC|NC] [--top-volume VOL]
#       [--merge-fcl FCL --oversample F]
#       [--seeds GENIE,MERGE,NEUT] [--soft-fail]
#
#   FCL        step-A fcl, e.g. extgen_requests_neut_bnb.fcl
#   N          step-A events (= interactions, one per subrun); must be at least
#              the number of EXT events in an input file, as EXT events left
#              over when the generator events run out are dropped; or auto
#   TARBALL    NEUT tarball (make_neut_tarball.sh): taken from
#              $CONDOR_DIR_INPUT if passed with jobsub -f, else copied with
#              ifdh (/pnfs) or used in place (/cvmfs, local path)
#   MD5        md5sum of the tarball (checked)
#   STEM       table set, e.g. genie/neut/neut_<version>_<cardhash>: uses
#              STEM_xsec.xml (splines) and STEM_xsec.txt (V4)
#              (extgen_neut_tables.sh)
#   --spline, --xsec-table: the two files one by one (tests); without
#              --xsec-table the V4 check is skipped
#   --retries  NEUT attempts after a failed one (extgen_neut_serve.sh -R)
#   Files: a relative path is looked up along FW_SEARCH_PATH (uboonedata);
#   /pnfs paths are copied with ifdh.
#   --gen-flavors, --current, --top-volume: dedicated samples, set in step A
#              over the --stepa-fcl settings. LIST is comma separated PDG codes
#              (e.g. 12,-12 for an intrinsic nue sample; GENIE counts the POT of
#              the rays it skips). --current uses the generator list ExtGenCC or
#              ExtGenNC. VOL e.g. volTPCActive, as the GENIE nue overlays.
#              The cross-section tables hold every channel, so they do not change.
#   --merge-fcl, --oversample: filtered samples. FCL (extgen_merge_*pi0*.fcl) replaces
#              extgen_merge.fcl in step D and drops events; with --nevents auto,
#              N = F x the EXT events, so that about enough events survive. The
#              stage fcl must then be extgen_overlay_SimInfoMixer_filtered.fcl,
#              and step A one subrun for the job (extgen_requests_*_{nc,cc}pi0.fcl).
#   --seeds    reuse the seeds of an earlier job (from its extgen_job_summary.txt);
#              by default each job draws its seeds from /dev/urandom
#   --soft-fail exit 0 after a failure (see above); for the <initscript>
#   extgen_neut_grid_init.sh --continue
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

log() { echo "extgen_neut_grid_init.sh: $*"; }
note() { echo "$*" >> "$SUMMARY"; }

save_logs() {
  [ -d "$WORK" ] || return 0
  (cd "$WORK" && tar -czf "$TOP/extgen_logs.tgz" --ignore-failed-read \
     $(ls *.log 2>/dev/null) $(ls serve/card.toml serve/neut*.log serve/check.log serve/trial_stats_neut.txt 2>/dev/null)) \
     2> /dev/null || true
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
STEPA= NEV= TARBALL= MD5= STEM= SPLINE= XSEC=
RETRIES=2 WARN=4 FAILPULL=8
ALLOW_MISSING=0 ALLOW_MISMATCH=0 SEEDS= CONTINUE=0 SOFT=0
GENFLAVORS= CURRENT= TOPVOL= MERGE_FCL=extgen_merge.fcl OVERSAMPLE=1 NEXT=0
while [ $# -gt 0 ]; do
  case $1 in
    --continue) CONTINUE=1; shift ;;
    --soft-fail) SOFT=1; shift ;;
    --stepa-fcl) STEPA=$2; shift 2 ;;
    --nevents) NEV=$2; shift 2 ;;
    --neut-tarball) TARBALL=$2; shift 2 ;;
    --neut-md5) MD5=$2; shift 2 ;;
    --tables) STEM=$2; shift 2 ;;
    --spline) SPLINE=$2; shift 2 ;;
    --xsec-table) XSEC=$2; shift 2 ;;
    --retries) RETRIES=$2; shift 2 ;;
    --warn-pull) WARN=$2; shift 2 ;;
    --fail-pull) FAILPULL=$2; shift 2 ;;
    --allow-missing-xsec) ALLOW_MISSING=1; shift ;;
    --allow-build-mismatch) ALLOW_MISMATCH=1; shift ;;
    --seeds) SEEDS=$2; shift 2 ;;
    --gen-flavors) GENFLAVORS=$2; shift 2 ;;
    --current) CURRENT=$2; shift 2 ;;
    --top-volume) TOPVOL=$2; shift 2 ;;
    --merge-fcl) MERGE_FCL=$2; shift 2 ;;
    --oversample) OVERSAMPLE=$2; shift 2 ;;
    *) echo "extgen_neut_grid_init.sh: bad option $1 (see the header of this script)" >&2; exit 1 ;;
  esac
done

if [ "$CONTINUE" -eq 0 ]; then
rm -rf "$WORK"
mkdir -p "$WORK"
{
  echo "# extgen-neut-job v1"
  echo "start $(date -u +%Y-%m-%dT%H:%M:%SZ) host $(hostname) cluster ${CLUSTER:-} process ${PROCESS:-}"
  echo "ubsim ${UBSIM_VERSION:-?} uboonecode ${UBOONECODE_VERSION:-?}"
} > "$SUMMARY"

[ -n "$STEPA" ] || fail "--stepa-fcl missing"
[ -z "$CURRENT" ] || [ "$CURRENT" = CC ] || [ "$CURRENT" = NC ] || fail "--current must be CC or NC"
[[ "$OVERSAMPLE" =~ ^[1-9][0-9]*$ ]] || fail "--oversample must be a positive integer"
[[ "$GENFLAVORS" =~ ^(-?[0-9]+(,-?[0-9]+)*)?$ ]] || fail "--gen-flavors must be a comma separated list of PDG codes"
[ "$NEV" = auto ] || { [[ "$NEV" =~ ^[0-9]+$ ]] && [ "$NEV" -gt 0 ]; } \
  || fail "--nevents must be a positive integer or auto"
[ -n "$TARBALL" ] && [ -n "$MD5" ] || fail "--neut-tarball and --neut-md5 are required"
[[ "$RETRIES" =~ ^[0-9]+$ ]] || fail "--retries must be a number"
if [ -n "$STEM" ]; then
  SPLINE=${SPLINE:-${STEM}_xsec.xml}
  XSEC=${XSEC:-${STEM}_xsec.txt}
fi
[ -n "$SPLINE" ] || fail "give --tables or --spline"
for c in lar extgen_neut_serve.sh extgen_neut_run.sh extgen_gibuu_xsec_check.sh; do
  command -v $c > /dev/null || fail "$c not on PATH"
done

# --- seeds: GENIE (step A), merge (azimuth), NEUT (serve adds 1 per retry;
# neut_extgen derives NEUT's three generator seeds from it). All below 9e8
# (HepJamesRandom, RM48, RANMAR).
if [ -n "$SEEDS" ]; then
  IFS=, read -r SEED_GENIE SEED_MERGE SEED_NEUT <<< "$SEEDS"
else
  SEED_GENIE=$(random_seed 899999999)
  SEED_MERGE=$(random_seed 899999999)
  SEED_NEUT=$(( 1 + $(random_seed 899999899) ))   # NEUT seeds must be > 1
fi
for s in "$SEED_GENIE" "$SEED_MERGE" "$SEED_NEUT"; do
  [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -gt 0 ] && [ "$s" -lt 900000000 ] || fail "bad seed '$s'"
done
[ "$SEED_NEUT" -gt 1 ] && [ $(( SEED_NEUT + RETRIES )) -lt 900000000 ] || fail "bad NEUT seed $SEED_NEUT"
note "seeds $SEED_GENIE,$SEED_MERGE,$SEED_NEUT"
log "seeds GENIE $SEED_GENIE, merge $SEED_MERGE, NEUT $SEED_NEUT"

# --- input files
SPLINE_F=$(fetch "$SPLINE") || fail "spline file $SPLINE not found"
note "spline $SPLINE -> $SPLINE_F"
XSEC_F=
if [ -n "$XSEC" ]; then
  XSEC_F=$(fetch "$XSEC") || fail "cross-section table $XSEC not found"
  note "xsec_table $XSEC -> $XSEC_F"
fi
TAR_F=$(fetch "$TARBALL") || fail "NEUT tarball $TARBALL not found"
md5=$(md5sum "$TAR_F" | awk '{print $1}')
[ "$md5" = "$MD5" ] || fail "NEUT tarball md5 $md5, expected $MD5"
mkdir -p "$WORK/neut"
tar -xzf "$TAR_F" -C "$WORK/neut" || fail "cannot unpack $TAR_F"
[ "$TAR_F" != "$WORK/$(basename "$TAR_F")" ] || rm -f "$TAR_F"
# condor_lar.sh copies every jobsub -f file into its work directory, from
# where it would go into the job's log tarball
[ ! -f "$TOP/$(basename "$TAR_F")" ] || rm -f "$TOP/$(basename "$TAR_F")"
NEUT_COMMIT=$(awk '/^commit:/ {print $2}' "$WORK/neut/BUILD_INFO")
NEUT_MD5=$(awk '/^neut_extgen md5:/ {print $3}' "$WORK/neut/BUILD_INFO")
note "neut_tarball $TARBALL md5 $md5 commit $NEUT_COMMIT binary_md5 $NEUT_MD5"
note "neut_products $(awk '/^ups products:/ {sub(/^ups products: */, ""); print}' "$WORK/neut/BUILD_INFO")"
[[ "$NEUT_MD5" =~ ^[0-9a-f]{32}$ ]] || fail "no neut_extgen md5 in the tarball's BUILD_INFO"
[ "$(md5sum "$WORK/neut/bin/neut_extgen" | cut -c1-32)" = "$NEUT_MD5" ] \
  || fail "bin/neut_extgen does not match the tarball's BUILD_INFO"
# NEUT's e26 environment (CVMFS) must work here, before the job goes on
extgen_neut_run.sh --check "$WORK/neut" > "$WORK/neut_check.log" 2>&1 \
  || { cat "$WORK/neut_check.log"; fail "NEUT environment not usable (extgen_neut_run.sh --check)"; }
note "neut_env $(tail -1 "$WORK/neut_check.log")"
# the table must come from this NEUT build: one of the commit/md5 entries of
# its build line has exactly this binary md5
for t in $XSEC_F; do
  if grep -q "^# NEUT build(s):" "$t"; then
    if ! awk -v m="$NEUT_MD5" '/^# NEUT build\(s\):/ {
           for (i = 4; i <= NF; i++) { x = $i; gsub(/,/, "", x); sub(/.*\//, "", x); if (x == m) f = 1 } }
         END { exit !f }' "$t"; then
      [ "$ALLOW_MISMATCH" -eq 1 ] || fail "$t was made with another NEUT build than $NEUT_MD5"
      note "warning: $t from another NEUT build (--allow-build-mismatch)"
    fi
  else
    note "warning: $t has no NEUT build line"
  fi
done
# ... and from the card script the serving uses (installed next to the serve script)
CARD_MD5=$(md5sum "$(dirname "$(realpath "$(which extgen_neut_serve.sh)")")/extgen_neut_card.sh" \
           | awk '{print $1}')
note "card_md5 $CARD_MD5"
for t in $XSEC_F; do
  tcard=$(awk '/^# NEUT card md5:/ {print $5}' "$t")
  if [ -z "$tcard" ]; then
    note "warning: $t has no card md5 line"
  elif [ "$tcard" != "$CARD_MD5" ]; then
    [ "$ALLOW_MISMATCH" -eq 1 ] || fail "$t was made with card md5 $tcard, serving uses $CARD_MD5"
    note "warning: $t from another card (--allow-build-mismatch)"
  fi
done

if [ "$NEV" = auto ]; then
  # the rest runs from the copy stage's <endscript> (--continue)
  declare -p STEPA SPLINE_F XSEC_F RETRIES WARN FAILPULL ALLOW_MISSING \
             SEED_GENIE SEED_MERGE SEED_NEUT GENFLAVORS CURRENT TOPVOL MERGE_FCL OVERSAMPLE > "$WORK/job.env"
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
  NEXT=$NEV
  NEV=$(( NEXT * OVERSAMPLE ))
  [ "$OVERSAMPLE" -eq 1 ] || note "oversample $OVERSAMPLE: $NEV generator events for $NEXT EXT events"
fi

cd "$WORK" || fail "no $WORK"

# --- A: requests
cat > stepA.fcl <<EOF
#include "$STEPA"
physics.producers.generator.RandomSeed: $SEED_GENIE
physics.producers.generator.XSecTable:  "$SPLINE_F"
services.scheduler.wantSummary: true   # event count for the check below
EOF
[ -z "$GENFLAVORS" ] || echo "physics.producers.generator.GenFlavors: [$GENFLAVORS]" >> stepA.fcl
[ -z "$CURRENT" ] || echo "physics.producers.generator.EventGeneratorList: \"ExtGen$CURRENT\"" >> stepA.fcl
[ -z "$TOPVOL" ] || echo "physics.producers.generator.TopVolume: \"$TOPVOL\"" >> stepA.fcl
[ -z "$GENFLAVORS$CURRENT$TOPVOL" ] || note "dedicated sample: flavors ${GENFLAVORS:-all} current ${CURRENT:-all} top volume ${TOPVOL:-from the fcl}"
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
# a filtered sample has one subrun; else one event per subrun
[ "$MERGE_FCL" != extgen_merge.fcl ] || [ "$nsub" -eq "$NEV" ] || fail "requests cover $nsub subruns, not $NEV"
note "requests $NREQ"

# --- C: NEUT, then the cross-section check
log "step C: NEUT serving $NREQ requests ($(date -u))"
t0=$(date +%s)
xsopt=()
[ -z "$XSEC_F" ] || xsopt=(-x "$XSEC_F")   # V4 statistics and the Pauli-blocking check
extgen_neut_serve.sh -d "$WORK/neut" -r requests.txt -s "$SEED_NEUT" -o serve \
  -R "$RETRIES" "${xsopt[@]}" > serve.log 2>&1 || fail "step C failed (serve.log)"
note "serve_seconds $(( $(date +%s) - t0 )) attempts $(awk '!/^#/ && NF == 5' serve/serve_summary.txt | wc -l)"
note "$(grep -h '^pauli_blocking' serve/serve_summary.txt 2>/dev/null || echo 'pauli_blocking not checked (no table)')"
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
#include "$MERGE_FCL"
physics.producers.generator.Seed: $SEED_MERGE
services.scheduler.wantSummary: true
EOF
log "step D: merge ($(date -u))"
lar -c merge.fcl -s stepA.root -o merged.root > merge.log 2>&1 || fail "step D failed (merge.log)"
n=$(lar_events merge.log)
[ "$n" -eq "$NEV" ] || fail "merge read $n events, not $NEV"
if [ "$MERGE_FCL" = extgen_merge.fcl ]; then
  KEPT=$NEV
else
  KEPT=$(awk '/TrigReport Events total =/ { k = $8 } END { print k + 0 }' merge.log)
  [ "$KEPT" -gt 0 ] || fail "the filter of $MERGE_FCL kept no events"
  note "filter $MERGE_FCL kept $KEPT of $NEV events"
  [ "$NEXT" -eq 0 ] || [ "$KEPT" -ge "$NEXT" ] \
    || note "warning: $KEPT events kept for $NEXT EXT events: the rest of the EXT events are dropped"
fi
mv merged.root "$TOP/genfile.root.local" || fail "cannot move the merged file"
rm -f stepA.root

cd "$TOP"
save_logs
note "status OK"
note "end $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "done: genfile.root.local with $KEPT events ($(date -u))"
exit 0
