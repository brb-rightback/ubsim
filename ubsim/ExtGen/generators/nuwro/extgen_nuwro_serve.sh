#!/bin/bash
#
# ExtGen step C with NuWro: serves every request of requests.txt (step B) with
# NuWro's request-mode program (nuwro_extgen) and writes served_events.txt and
# trial_stats.txt for ExtGenMerge (step D). The NuWro counterpart of
# extgen_gibuu_serve.sh; nuwro_extgen writes the ExtGen formats itself, so
# there is no converter.
#
# Usage:
#   extgen_nuwro_serve.sh -d NUWRO_DIR -r requests.txt -s SEED -o OUT_DIR
#                         (-m MAX_TABLE [-k MARGIN] [-f FLOOR] | -F FLAT_MAX)
#                         [-R RETRIES]
#
#   NUWRO_DIR   unpacked NuWro tarball (make_nuwro_tarball.sh)
#   SEED        2..; group k (in the order below) uses SEED + 100*k + attempt,
#               so SEED must be unique per grid job in steps of 100 * groups
#   MAX_TABLE   per-channel Max table of the scan campaign
#               (extgen_nuwro_tables.py --max): the Max of channel c for a
#               request = MARGIN (default 3) x the largest weight of channel c
#               at the table's points around its energy (the two bracketing
#               points and one more on each side), at least FLOOR (default 0)
#               where that is > 0; a channel with no weight there stays closed
#               (Max 0, never generated)
#   FLAT_MAX    one Max for every channel and request (tests only)
#   RETRIES     if nuwro_extgen stops because a weight exceeded its Max (exit
#               code 3), the group is run again from scratch with twice the
#               Max values and a new seed, up to RETRIES times (default 2);
#               every retry is recorded
#
# One nuwro_extgen run per group (target, neutrino, current), in
# OUT_DIR/groups/, through extgen_nuwro_run.sh (clean environment with the
# products of the NuWro build). The groups' outputs are then joined into
# OUT_DIR/served_events.txt and OUT_DIR/trial_stats.txt and checked: every
# request served exactly once, at its energy, with its current.
# OUT_DIR/serve_summary.txt records groups, Max, attempts and times.
# Exit code 0 only if every request was served.

set -euo pipefail

die() { echo "extgen_nuwro_serve.sh: ERROR: $*" >&2; exit 1; }
log() { echo "extgen_nuwro_serve.sh: $*"; }
HERE=$(dirname "$(realpath "$0")")

NUWRO= REQ= SEED= OUT= MAXTAB= MARGIN=3 FLOOR=0 FLAT= RETRIES=2
while getopts "d:r:s:o:m:k:f:F:R:" opt; do
  case $opt in
    d) NUWRO=$OPTARG ;; r) REQ=$OPTARG ;; s) SEED=$OPTARG ;; o) OUT=$OPTARG ;;
    m) MAXTAB=$OPTARG ;; k) MARGIN=$OPTARG ;; f) FLOOR=$OPTARG ;; F) FLAT=$OPTARG ;;
    R) RETRIES=$OPTARG ;;
    *) die "bad option (see the header of this script)" ;;
  esac
done
for v in NUWRO REQ SEED OUT; do
  [ -n "${!v}" ] || die "missing option for $v"
done
[ -n "$MAXTAB" ] || [ -n "$FLAT" ] || die "give -m MAX_TABLE or -F FLAT_MAX"
[ -z "$MAXTAB" ] || [ -z "$FLAT" ] || die "-m and -F exclude each other"
[[ "$SEED" =~ ^[0-9]+$ ]] && [ "$SEED" -gt 1 ] || die "SEED must be an integer > 1"
NUWRO=$(realpath "$NUWRO")
[ -f "$NUWRO/BUILD_INFO" ] || die "$NUWRO/BUILD_INFO not found"
[ -f "$REQ" ] || die "$REQ not found"
[ -z "$MAXTAB" ] || [ -f "$MAXTAB" ] || die "Max table $MAXTAB not found"
REQ=$(realpath "$REQ")
mkdir -p "$OUT"
OUT=$(realpath "$OUT")
[ ! -e "$OUT/served_events.txt" ] || die "$OUT already holds served events"
GROUPS_DIR=$OUT/groups
mkdir -p "$GROUPS_DIR"

SUMMARY=$OUT/serve_summary.txt
{
  echo "# extgen-nuwro-serve v1"
  echo "requests $REQ"
  echo "nuwro_commit $(awk '/^commit:/ {print $2}' "$NUWRO/BUILD_INFO")"
  echo "nuwro_md5 $(awk '/^nuwro_extgen md5:/ {print $3}' "$NUWRO/BUILD_INFO")"
  echo "nuwro_products $(awk -F': *' '/^ups products:/ {print $2}' "$NUWRO/BUILD_INFO")"
  if [ -n "$MAXTAB" ]; then
    echo "max_table $(realpath "$MAXTAB") margin $MARGIN floor $FLOOR"
  else
    echo "max_flat $FLAT"
  fi
  echo "seed $SEED retries $RETRIES"
  echo "start $(date -u +%Y-%m-%dT%H:%M:%SZ) host $(hostname)"
  echo "# group target nu current n_requests max_min max_max attempts seconds"
} > "$SUMMARY"

# --- groups: (target, nu, current), in a fixed order
awk '!/^#/ && NF == 16 { print $8, $6, $7 }' "$REQ" | sort -u -k1,1n -k2,2n -k3,3 > "$OUT/groups.txt"
NG=$(wc -l < "$OUT/groups.txt")
NREQ_ALL=$(awk '!/^#/ && NF == 16' "$REQ" | wc -l)
[ "$NG" -gt 0 ] || die "no requests in $REQ"
log "$NREQ_ALL requests in $NG groups"

# nuwro_extgen's channels (NuWro dyn codes) of a current, in its order
channels_of() { [ "$1" = CC ] && echo "0,2,4,6,8,10" || echo "1,3,5,7,9"; }

# request file of a group: header with the channels, then "req_id E M_1 ... M_K"
# (factor scales every Max)
make_group_requests() {  # tgt nu cur factor out
  local tgt=$1 nu=$2 cur=$3 factor=$4 out=$5 ch
  ch=$(channels_of "$cur")
  echo "# extgen-nuwro-requests v1 channels=$ch" > "$out"
  if [ -n "$FLAT" ]; then
    awk -v t="$tgt" -v n="$nu" -v c="$cur" -v m="$FLAT" -v f="$factor" -v ch="$ch" '
      BEGIN { K = split(ch, d, ",") }
      !/^#/ && NF == 16 && $8 == t && $6 == n && $7 == c {
        s = $1 " " $9
        for (k = 1; k <= K; k++) s = s " " sprintf("%.6g", m * f)
        print s
      }' "$REQ" >> "$out"
  else
    awk -v t="$tgt" -v n="$nu" -v c="$cur" -v kk="$MARGIN" -v fl="$FLOOR" -v f="$factor" -v ch="$ch" '
      BEGIN { K = split(ch, d, ","); for (k = 1; k <= K; k++) col[d[k]] = k }
      FNR == NR {  # Max table: nu cur tgt E dyn max_w n
        if ($0 ~ /^#/ || NF < 7 || $1 != n || $2 != c || $3 != t) next
        if (!($5 in col)) { print "Max table channel " $5 " not in " ch > "/dev/stderr"; exit 1 }
        if (!($4 in eidx)) { eidx[$4] = ++np; e[np] = $4 + 0 }
        w[eidx[$4], col[$5]] = $6 + 0
        seen[col[$5]] = 1
        next
      }
      !/^#/ && NF == 16 && $8 == t && $6 == n && $7 == c {
        if (np < 2) { print "no Max table for " t " " n " " c > "/dev/stderr"; exit 1 }
        for (k = 1; k <= K; k++)
          if (!(k in seen)) { print "Max table has no channel " d[k] " for " t " " n " " c > "/dev/stderr"; exit 1 }
        E = $9 + 0
        i = 1
        while (i < np && e[i + 1] <= E) i++   # e[i] <= E < e[i+1] (or an end)
        lo = i - 1; hi = i + 2
        if (lo < 1) lo = 1
        if (hi > np) hi = np
        s = $1 " " $9
        for (k = 1; k <= K; k++) {
          mx = 0
          for (j = lo; j <= hi; j++) if (w[j, k] > mx) mx = w[j, k]
          M = kk * mx
          if (M > 0 && M < fl) M = fl
          s = s " " sprintf("%.6g", M * f)
        }
        print s
      }' <(sort -t' ' -k4,4g "$MAXTAB") "$REQ" >> "$out"
  fi
  [ "$(grep -vc '^#' "$out")" -gt 0 ] || return 1
}

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
    NREQ=$(grep -vc '^#' "$GD/requests.in")
    read -r MMIN MMAX < <(awk '!/^#/ { for (i = 3; i <= NF; i++) { if (n++ == 0) a = b = $i; if ($i < a) a = $i; if ($i > b) b = $i } }
                               END { print a, b }' "$GD/requests.in")
    S=$(( SEED + 100 * g + attempt ))
    [ "$S" -lt 900000000 ] || die "group $NAME: seed $S too large"
    "$HERE/extgen_nuwro_card.sh" --target "$TGT" --nu "$NU" --current "$CUR" > "$GD/card.txt"
    log "group $NAME: $NREQ requests, Max $MMIN-$MMAX, seed $S (attempt $attempt)"
    status=0
    (cd "$GD" && "$HERE/extgen_nuwro_run.sh" "$NUWRO" -m serve -r requests.in -s served.txt \
       -t stats.txt -i card.txt -o group -p "random_seed=$S" > nuwro.log 2>&1) || status=$?
    [ "$status" -eq 0 ] && break
    if [ "$status" -eq 3 ] && [ "$attempt" -lt "$RETRIES" ]; then
      log "group $NAME: a weight exceeded its Max; retrying with twice the Max"
      grep "OVERWEIGHT" "$GD/nuwro.log" >&2 || true
      gzip -c "$GD/nuwro.log" > "$GROUPS_DIR/$NAME.attempt$attempt.log.gz"
      attempt=$(( attempt + 1 ))
      factor=$(( factor * 2 ))
      continue
    fi
    gzip -f "$GD/nuwro.log"
    die "group $NAME: NuWro failed (exit $status), see $GD/nuwro.log.gz"
  done
  t1=$(date +%s)
  rm -f "$GD/random_seed" "$GD/group.par"
  gzip -f "$GD/nuwro.log"
  echo "$NAME $TGT $NU $CUR $NREQ $MMIN $MMAX $(( attempt + 1 )) $(( t1 - t0 ))" >> "$SUMMARY"
  g=$(( g + 1 ))
done < "$OUT/groups.txt"

# --- join the groups' outputs (the header lines of the first group once)
first=$(ls -d "$GROUPS_DIR"/g*/ | head -1)
{
  grep '^#' "$first/served.txt"
  for d in "$GROUPS_DIR"/g*/; do grep -v '^#' "$d/served.txt"; done
} > "$OUT/served_events.txt"
{
  grep '^#' "$first/stats.txt"
  for d in "$GROUPS_DIR"/g*/; do grep -v '^#' "$d/stats.txt"; done
} > "$OUT/trial_stats.txt"

# --- every request served exactly once, at its energy, with its current
awk '
  FNR == NR {
    if ($0 !~ /^#/ && NF == 16) { want[$1] = $9 + 0; cur[$1] = $7; nwant++ }
    next
  }
  $1 == "EVENT" {
    id = $2
    if (!(id in want)) { print "event for unknown request " id; bad = 1; next }
    if (id in got) { print "request " id " served twice"; bad = 1 }
    got[id] = 1
    if ($3 + 0 != want[id]) { print "request " id ": energy " $3 ", requested " want[id]; bad = 1 }
    if ((($4 % 100) % 2 == 0 ? "CC" : "NC") != cur[id]) { print "request " id ": NuWro channel " $4 " for a " cur[id] " request"; bad = 1 }
  }
  END {
    n = 0
    for (id in got) n++
    if (n != nwant) { print n " of " nwant " requests served"; bad = 1 }
    exit bad
  }' "$REQ" "$OUT/served_events.txt" >&2 || die "served_events.txt does not match $REQ"
nst=$(grep -vc '^#' "$OUT/trial_stats.txt")
[ "$nst" -eq "$NREQ_ALL" ] || die "trial_stats.txt has $nst lines for $NREQ_ALL requests"

echo "end $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SUMMARY"
log "done: $(grep -c '^EVENT' "$OUT/served_events.txt") events in $OUT/served_events.txt"
