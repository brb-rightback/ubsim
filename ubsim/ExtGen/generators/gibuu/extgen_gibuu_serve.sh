#!/bin/bash
#
# ExtGen step C with GiBUU: serves every request of requests.txt (step B) with
# GiBUU in request mode and writes served_events.txt and trial_stats.txt for
# ExtGenMerge (step D).
#
# Usage:
#   extgen_gibuu_serve.sh -g GIBUU_DIR -r requests.txt -s SEED -o OUT_DIR
#                         (-m MAX_TABLE [-k MARGIN] [-f FLOOR] | -F FLAT_MAX)
#                         [-e ENSEMBLES] [-R RETRIES]
#
#   GIBUU_DIR   unpacked GiBUU tarball (make_gibuu_tarball.sh)
#   SEED        positive; group k (in the order below) uses SEED + 100*k + attempt,
#               so SEED must be unique per grid job in steps of 100 * groups
#   MAX_TABLE   Max table of the scan campaign (extgen_gibuu_tables.py --max):
#               Max of a request = MARGIN (default 3) x the largest trial
#               weight of the table's points around its energy (the two
#               bracketing points and one more on each side), at least FLOOR
#               (default 50)
#   FLAT_MAX    one Max for every request (tests only)
#   ENSEMBLES   GiBUU ensembles (default 1000); a run makes A x ENSEMBLES trials
#   RETRIES     if GiBUU aborts because a weight exceeded Max, the group is run
#               again from scratch with twice the Max and a new seed, up to
#               RETRIES times (default 2); every retry is recorded
#
# One GiBUU run per group (target, neutrino, current), in OUT_DIR/groups/.
# Then extgen_gibuu_convert (ubsim, on PATH) checks every event against its
# request and writes OUT_DIR/served_events.txt and OUT_DIR/trial_stats.txt.
# OUT_DIR/serve_summary.txt records groups, Max, attempts and times.
# Exit code 0 only if every request was served and converted.

set -euo pipefail

die() { echo "extgen_gibuu_serve.sh: ERROR: $*" >&2; exit 1; }
log() { echo "extgen_gibuu_serve.sh: $*"; }
HERE=$(dirname "$(realpath "$0")")

GIBUU= REQ= SEED= OUT= MAXTAB= MARGIN=3 FLOOR=50 FLAT= ENS=1000 RETRIES=2
while getopts "g:r:s:o:m:k:f:F:e:R:" opt; do
  case $opt in
    g) GIBUU=$OPTARG ;; r) REQ=$OPTARG ;; s) SEED=$OPTARG ;; o) OUT=$OPTARG ;;
    m) MAXTAB=$OPTARG ;; k) MARGIN=$OPTARG ;; f) FLOOR=$OPTARG ;; F) FLAT=$OPTARG ;;
    e) ENS=$OPTARG ;; R) RETRIES=$OPTARG ;;
    *) die "bad option (see the header of this script)" ;;
  esac
done
for v in GIBUU REQ SEED OUT; do
  [ -n "${!v}" ] || die "missing option for $v"
done
[ -n "$MAXTAB" ] || [ -n "$FLAT" ] || die "give -m MAX_TABLE or -F FLAT_MAX"
[ -z "$MAXTAB" ] || [ -z "$FLAT" ] || die "-m and -F exclude each other"
[[ "$SEED" =~ ^[0-9]+$ ]] && [ "$SEED" -gt 0 ] || die "SEED must be a positive integer"
GIBUU=$(realpath "$GIBUU")
EXE=$GIBUU/release/objects/GiBUU.x
[ -x "$EXE" ] || die "$EXE not found"
[ -f "$REQ" ] || die "$REQ not found"
command -v extgen_gibuu_convert > /dev/null || die "extgen_gibuu_convert not on PATH (set up ubsim)"
[ -z "$MAXTAB" ] || [ -f "$MAXTAB" ] || die "Max table $MAXTAB not found"
REQ=$(realpath "$REQ")
mkdir -p "$OUT"
OUT=$(realpath "$OUT")
[ ! -e "$OUT/served_events.txt" ] || die "$OUT already holds served events"
GROUPS_DIR=$OUT/groups
mkdir -p "$GROUPS_DIR"
export LD_LIBRARY_PATH=$GIBUU/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

SUMMARY=$OUT/serve_summary.txt
{
  echo "# extgen-gibuu-serve v1"
  echo "requests $REQ"
  echo "gibuu_commit $(awk '/^commit:/ {print $2}' "$GIBUU/BUILD_INFO")"
  echo "gibuu_md5 $(awk '/^GiBUU.x md5:/ {print $3}' "$GIBUU/BUILD_INFO")"
  if [ -n "$MAXTAB" ]; then
    echo "max_table $(realpath "$MAXTAB") margin $MARGIN floor $FLOOR"
  else
    echo "max_flat $FLAT"
  fi
  echo "seed $SEED ensembles $ENS retries $RETRIES"
  echo "start $(date -u +%Y-%m-%dT%H:%M:%SZ) host $(hostname)"
  echo "# group target nu current n_requests max_min max_max attempts seconds"
} > "$SUMMARY"

# --- groups: (target, nu, current), in a fixed order
awk '!/^#/ && NF == 16 { print $8, $6, $7 }' "$REQ" | sort -u -k1,1n -k2,2n -k3,3 > "$OUT/groups.txt"
NG=$(wc -l < "$OUT/groups.txt")
NR=$(awk '!/^#/ && NF == 16' "$REQ" | wc -l)
[ "$NG" -gt 0 ] || die "no requests in $REQ"
log "$NR requests in $NG groups"

# Max per request of a group: writes "req_id E Max" (factor scales Max)
make_group_requests() {  # tgt nu cur factor out
  local tgt=$1 nu=$2 cur=$3 factor=$4 out=$5
  if [ -n "$FLAT" ]; then
    awk -v t="$tgt" -v n="$nu" -v c="$cur" -v m="$FLAT" -v f="$factor" \
      '!/^#/ && NF == 16 && $8 == t && $6 == n && $7 == c { print $1, $9, m * f }' "$REQ" > "$out"
  else
    awk -v t="$tgt" -v n="$nu" -v c="$cur" -v k="$MARGIN" -v fl="$FLOOR" -v f="$factor" '
      FNR == NR {  # Max table: nu cur tgt E max_w n
        if ($0 !~ /^#/ && NF >= 5 && $1 == n && $2 == c && $3 == t) { np++; e[np] = $4; w[np] = $5 }
        next
      }
      !/^#/ && NF == 16 && $8 == t && $6 == n && $7 == c {
        if (np < 2) { print "no Max table for " t " " n " " c > "/dev/stderr"; exit 1 }
        E = $9 + 0
        i = 1
        while (i < np && e[i + 1] <= E) i++   # e[i] <= E < e[i+1] (or an end)
        lo = i - 1; hi = i + 2
        if (lo < 1) lo = 1
        if (hi > np) hi = np
        mx = 0
        for (j = lo; j <= hi; j++) if (w[j] > mx) mx = w[j]
        M = k * mx
        if (M < fl) M = fl
        printf "%s %s %.6g\n", $1, $9, M * f
      }' "$MAXTAB" "$REQ" > "$out"
  fi
  [ -s "$out" ] || return 1
}

GROUP_DIRS=()
g=0
while read -r TGT NU CUR; do
  NAME=$(printf "g%02d_%s_%s_%s" "$g" "$TGT" "$NU" "$CUR")
  GD=$GROUPS_DIR/$NAME
  attempt=0
  factor=1
  t0=$(date +%s)
  while :; do
    rm -rf "$GD"
    mkdir -p "$GD"
    make_group_requests "$TGT" "$NU" "$CUR" "$factor" "$GD/requests.in" \
      || die "group $NAME: cannot set Max (no Max table entry?)"
    NREQ=$(wc -l < "$GD/requests.in")
    read -r MMIN MMAX < <(awk 'NR == 1 { a = b = $3 } { if ($3 < a) a = $3; if ($3 > b) b = $3 } END { print a, b }' "$GD/requests.in")
    S=$(( SEED + 100 * g + attempt ))
    "$HERE/extgen_gibuu_card.sh" --mode serve --target "$TGT" --nu "$NU" --current "$CUR" \
      --requests "$GD/requests.in" --buuinput "$GIBUU/buuinput" --seed "$S" \
      --ensembles "$ENS" --runs 100000 > "$GD/gibuu.job"
    log "group $NAME: $NREQ requests, Max $MMIN-$MMAX, seed $S (attempt $attempt)"
    status=0
    (cd "$GD" && "$EXE" < gibuu.job > gibuu.log 2>&1) || status=$?
    if [ "$status" -eq 0 ] && grep -q "request mode: all" "$GD/gibuu.log"; then
      break
    fi
    if grep -q "increase 'equalWeights_Max'" "$GD/gibuu.log" && [ "$attempt" -lt "$RETRIES" ]; then
      log "group $NAME: a trial weight exceeded Max; retrying with twice the Max"
      grep -A1 "totalWeight > equalWeights_Max" "$GD/gibuu.log" | head -2 >&2 || true
      gzip -c "$GD/gibuu.log" > "$GROUPS_DIR/$NAME.attempt$attempt.log.gz"
      attempt=$(( attempt + 1 ))
      factor=$(( factor * 2 ))
      continue
    fi
    gzip -f "$GD/gibuu.log"
    die "group $NAME: GiBUU failed (exit $status), see $GD/gibuu.log.gz"
  done
  t1=$(date +%s)
  # keep what the converter and later checks need
  find "$GD" -maxdepth 1 -type f ! -name gibuu.job ! -name gibuu.log ! -name requests.in \
       ! -name EventOutput.Pert.hepmc3 ! -name uboone_request_stats.dat -delete
  gzip -f "$GD/gibuu.log"
  echo "$NAME $TGT $NU $CUR $NREQ $MMIN $MMAX $(( attempt + 1 )) $(( t1 - t0 ))" >> "$SUMMARY"
  GROUP_DIRS+=("$GD")
  g=$(( g + 1 ))
done < "$OUT/groups.txt"

log "converting $NG groups"
extgen_gibuu_convert -r "$REQ" -o "$OUT/served_events.txt" -t "$OUT/trial_stats.txt" "${GROUP_DIRS[@]}" \
  || die "extgen_gibuu_convert failed"
echo "end $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SUMMARY"
log "done: $(grep -c '^EVENT' "$OUT/served_events.txt") events in $OUT/served_events.txt"
