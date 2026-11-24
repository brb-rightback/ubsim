#!/bin/bash
#
# ExtGen step C with NEUT: serves every request of requests.txt (step B) with
# ExtGen's NEUT driver (neut_extgen -m serve) and writes served_events.txt and
# trial_stats.txt for ExtGenMerge (step D) and the in-job cross-section check
# (V4). The NEUT counterpart of extgen_nuwro_serve.sh, but simpler: NEUT
# events are unweighted at a given energy, so there are no Max tables, and
# one process serves all requests of the job (any target, neutrino and
# current; neut_extgen.cc).
#
# Usage:
#   extgen_neut_serve.sh -d NEUT_DIR -r requests.txt -s SEED -o OUT_DIR [-R RETRIES]
#                        [-x XSEC_TABLE]
#
#   NEUT_DIR   unpacked NEUT tarball (make_neut_tarball.sh)
#   SEED       2..899999990; attempt k (0, 1, ...) uses SEED + k
#   RETRIES    if neut_extgen fails, or ends without serving every request
#              (NEUT stops with Fortran STOP, which can exit 0), it runs again
#              from scratch with the next seed, up to RETRIES times (default 2);
#              every attempt is recorded
#   XSEC_TABLE the cross-section table of the splines (extgen_neut_tables.sh);
#              with it, trial_stats.txt is written for the in-job check V4 as
#              below, and the Pauli-blocked events are checked
#
# trial_stats.txt and the Pauli-blocked events. neut_extgen's own statistics
# (trial_stats_neut.txt) have, per request, one trial per NEUT event, weight
# sigma_NEUT(E) if served and 0 if Pauli blocked (dropped). Most requests then
# have one trial, from which V4 (extgen_gibuu_xsec_check.sh: variance from
# requests with more than one trial) cannot see the binomial fluctuation of
# the blocked events (f_PB ~ 1%): a channel with a few requests and no blocked
# event shows obs/exp = 1/(1 - f_PB) with a large pull. With -x, the two parts
# are checked separately:
#   * trial_stats.txt (V4): per request one trial of weight
#     sigma_NEUT(E) x (1 - f_PB(E)), sigma_NEUT exact at the request's energy
#     (neut_extgen's max_w), f_PB from the table (linear in E): V4 then
#     compares NEUT's cross section in the job with the table's (same build
#     and card, interpolation), within the table's rel_err;
#   * the blocked events: the number dropped against its expectation,
#     sum over requests of f/(1 - f) (variance f/(1 - f)^2), in
#     serve_summary.txt ("pauli_blocking ... pull"), with a warning beyond 4.
# Without -x, trial_stats.txt is neut_extgen's.
#
# The card comes from extgen_neut_card.sh next to this script (the grid job
# checks its md5 against the cross-section tables). OUT_DIR gets card.toml,
# served_events.txt, trial_stats.txt, neut.log (of the last attempt) and
# serve_summary.txt. The outputs are checked: every request served exactly
# once, at its energy (identical string), and one trial-statistics line per
# request. Exit code 0 only if every request was served.

set -euo pipefail

die() { echo "extgen_neut_serve.sh: ERROR: $*" >&2; exit 1; }
log() { echo "extgen_neut_serve.sh: $*"; }
HERE=$(dirname "$(realpath "$0")")

NEUT= REQ= SEED= OUT= RETRIES=2 XS=
while getopts "d:r:s:o:R:x:" opt; do
  case $opt in
    d) NEUT=$OPTARG ;;
    r) REQ=$OPTARG ;;
    s) SEED=$OPTARG ;;
    o) OUT=$OPTARG ;;
    R) RETRIES=$OPTARG ;;
    x) XS=$OPTARG ;;
    *) die "bad option (see the header of this script)" ;;
  esac
done
[ -n "$NEUT" ] && [ -n "$REQ" ] && [ -n "$SEED" ] && [ -n "$OUT" ] || die "give -d, -r, -s and -o"
[[ "$SEED" =~ ^[0-9]+$ ]] && [ "$SEED" -gt 1 ] && [ $(( SEED + RETRIES )) -lt 900000000 ] \
  || die "seed must be in 2..$(( 899999999 - RETRIES ))"
[[ "$RETRIES" =~ ^[0-9]+$ ]] || die "-R must be a number"
NEUT=$(realpath "$NEUT")
REQ=$(realpath "$REQ")
[ -f "$REQ" ] || die "no $REQ"
if [ -n "$XS" ]; then XS=$(realpath "$XS"); [ -f "$XS" ] || die "no $XS"; fi
RUN=$HERE/extgen_neut_run.sh
CARD=$HERE/extgen_neut_card.sh
[ -x "$RUN" ] && [ -x "$CARD" ] || die "extgen_neut_run.sh or extgen_neut_card.sh missing next to $0"

mkdir -p "$OUT"
OUT=$(realpath "$OUT")
cd "$OUT"
"$CARD" > card.toml
NREQ=$(awk '!/^#/ && NF >= 9' "$REQ" | wc -l)
[ "$NREQ" -gt 0 ] || die "no requests in $REQ"
{
  echo "# extgen-neut-serve v1 requests=$REQ n_requests=$NREQ card_md5=$(md5sum "$CARD" | cut -c1-32)"
  echo "# attempt seed exit served seconds"
} > serve_summary.txt

# 0 if served_events.txt and trial_stats.txt cover every request exactly once
check() {
  awk -v req="$REQ" '
    FNR == NR { if ($0 !~ /^#/ && NF >= 9) { want[$1] = $9; n++ } next }
    FILENAME ~ /served_events/ && $1 == "EVENT" {
      if (!($2 in want)) { print "served unknown request " $2; bad = 1 }
      else if ($3 != want[$2]) { print "request " $2 " served at " $3 ", requested " want[$2]; bad = 1 }
      if (seen[$2]++) { print "request " $2 " served twice"; bad = 1 }
      nev++
    }
    FILENAME ~ /trial_stats/ && $0 !~ /^#/ { if (ts[$1]++) { print "two trial lines for " $1; bad = 1 } nts++ }
    END {
      if (nev != n) { print "served " nev " of " n " requests"; bad = 1 }
      if (nts != n) { print nts " trial-statistics lines for " n " requests"; bad = 1 }
      exit bad
    }' "$REQ" served_events.txt trial_stats.txt
}

ok=0
for (( k = 0; k <= RETRIES; k++ )); do
  s=$(( SEED + k ))
  rm -f served_events.txt trial_stats.txt
  t0=$(date +%s)
  log "attempt $k: neut_extgen serving $NREQ requests, seed $s ($(date -u))"
  set +e
  "$RUN" "$NEUT" -m serve -c card.toml -r "$REQ" -s served_events.txt -t trial_stats.txt -S "$s" \
    > neut.log 2>&1
  rc=$?
  set -e
  nserved=$(grep -c '^EVENT ' served_events.txt 2>/dev/null || true)
  echo "$k $s $rc ${nserved:-0} $(( $(date +%s) - t0 ))" >> serve_summary.txt
  if [ "$rc" -eq 0 ] && [ -f served_events.txt ] && [ -f trial_stats.txt ] && check > check.log 2>&1; then
    ok=1
    break
  fi
  log "attempt $k failed (exit $rc, $nserved of $NREQ served):"
  grep -a "ERROR\|rror\|STOP" neut.log | tail -5 >&2 || true
  [ -f check.log ] && head -5 check.log >&2
  cp neut.log "neut_attempt$k.log"
done
[ "$ok" -eq 1 ] || { echo "status FAIL" >> serve_summary.txt; die "NEUT did not serve every request in $(( RETRIES + 1 )) attempts"; }
grep -a "^neut_extgen: served" neut.log >> serve_summary.txt || true

if [ -n "$XS" ]; then
  mv trial_stats.txt trial_stats_neut.txt
  awk -v ts=trial_stats.txt -v sum=pb_check.txt '
    FNR == NR {   # table: nu cur tgt E sigma # rel_err sigma_NEUT f_PB (sorted by E per channel)
      if ($0 ~ /^#/ || NF < 9) next
      c = $3 " " $1 " " $2
      n[c]++; te[c, n[c]] = $4 + 0; tf[c, n[c]] = $9 + 0
      next
    }
    /^#/ { if (FNR <= 2) print > ts; next }
    NF >= 10 {   # req_id tgt nu ccnc E n sum_w sum_w2 max_w n_dropped
      c = $2 " " $3 " " $4
      if (!(c in n)) { print "no table channel " c > "/dev/stderr"; bad = 1; next }
      E = $5 + 0; k = n[c]
      if (E <= te[c, 1]) f = tf[c, 1]
      else if (E >= te[c, k]) f = tf[c, k]
      else { for (i = 1; te[c, i + 1] < E; i++) ; t = (E - te[c, i]) / (te[c, i + 1] - te[c, i]); f = (1 - t) * tf[c, i] + t * tf[c, i + 1] }
      w = $9 * (1 - f)
      printf "%s %s %s %s %s 1 %.17g %.17g %.17g %s\n", $1, $2, $3, $4, $5, w, w * w, w, $10 > ts
      if (f < 1) { ex += f / (1 - f); va += f / (1 - f) ^ 2 }
      dr += $10
    }
    END {
      pull = va > 0 ? (dr - ex) / sqrt(va) : 0
      printf "pauli_blocking dropped %d expected %.2f pull %+.2f%s\n", dr, ex, pull, (pull > 4 || pull < -4) ? " WARN" : "" > sum
      exit bad
    }' "$XS" trial_stats_neut.txt || die "cannot make trial_stats.txt from $XS"
  sed -i '1s/generator=NEUT/generator=NEUT (w = sigma_NEUT x (1 - f_PB of the table), extgen_neut_serve.sh)/' trial_stats.txt
  cat pb_check.txt >> serve_summary.txt
  log "$(cat pb_check.txt)"
fi
echo "status OK" >> serve_summary.txt
log "served $NREQ requests ($(tail -2 serve_summary.txt | head -1))"
