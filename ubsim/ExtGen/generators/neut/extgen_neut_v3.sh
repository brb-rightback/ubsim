#!/bin/bash
#
# Validation V3 for NEUT: request mode (neut_extgen -m serve, as in grid jobs)
# against stock NEUT (neutroot2) at one fixed energy, same physics card
# (extgen_neut_card.sh; --stock for neutroot2).
#
# Usage:
#   extgen_neut_v3.sh -d NEUT_DIR -t TARGET_PDG -n NU_PDG -c CC|NC -E E_GeV
#                     -N EVENTS -s SEED -o OUT_DIR
#
#   NEUT_DIR   unpacked NEUT tarball (make_neut_tarball.sh)
#   TARGET     a nucleus generated directly (not H1, the free neutron or a
#              substituted nucleus; see neut_extgen.cc)
#   EVENTS     request-mode events; stock NEUT makes events of both currents
#              (all modes, as stock NEUT does), of which the requested current
#              is kept: it runs 2 x EVENTS (CC) or 5 x EVENTS (NC) events
#   SEED       request mode SEED; stock NEUT's seed file "SEED+1 SEED+2 SEED+3 0 0"
#
# The stock events are converted to the served format by neut_extgen -m
# convert with the same particle rules, and both samples are compared by
# extgen_served_compare.py (processes, struck nucleon, multiplicities, lepton
# and hadron kinematics). The Pauli-blocked fractions (events without final
# state; request mode: dropped trials, stock: events without a lepton) are
# compared too (pull). OUT_DIR gets the cards, both event samples
# (request.txt, stock.txt), the request-mode trial statistics, the logs and
# v3_result.txt; the exit code is that of extgen_served_compare.py (1 if a
# test is flagged), or 1 if |pull| of the blocked fractions exceeds 4.

set -euo pipefail

die() { echo "extgen_neut_v3.sh: ERROR: $*" >&2; exit 2; }
HERE=$(dirname "$(realpath "$0")")

NEUT= TGT= NU= CUR= E= N= SEED= OUT=
while getopts "d:t:n:c:E:N:s:o:" opt; do
  case $opt in
    d) NEUT=$OPTARG ;; t) TGT=$OPTARG ;; n) NU=$OPTARG ;; c) CUR=$OPTARG ;;
    E) E=$OPTARG ;; N) N=$OPTARG ;; s) SEED=$OPTARG ;; o) OUT=$OPTARG ;;
    *) die "bad option (see the header of this script)" ;;
  esac
done
for v in NEUT TGT NU CUR E N SEED OUT; do [ -n "${!v}" ] || die "missing option for $v"; done
[ "$CUR" = CC ] || [ "$CUR" = NC ] || die "-c must be CC or NC"
[[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -gt 0 ] || die "-N must be a positive number"
[[ "$SEED" =~ ^[0-9]+$ ]] && [ "$SEED" -gt 1 ] && [ "$SEED" -lt 899999990 ] || die "bad seed"
NEUT=$(realpath "$NEUT")
RUN=$HERE/extgen_neut_run.sh
CARD=$HERE/extgen_neut_card.sh
CMP=$(command -v extgen_served_compare.py || true)
[ -n "$CMP" ] || CMP=$(realpath -m "$HERE/../../tools/extgen_served_compare.py")
[ -f "$CMP" ] || die "extgen_served_compare.py not found"
PY=$(command -v python3 || command -v python)

mkdir -p "$OUT"
OUT=$(realpath "$OUT")
cd "$OUT"
EMEV=$(awk -v e="$E" 'BEGIN { printf "%.6f", e * 1000 }')
[ "$CUR" = CC ] && NSTOCK=$(( 2 * N )) || NSTOCK=$(( 5 * N ))
"$CARD" > card.toml
"$CARD" --stock --nu "$NU" --target "$TGT" --energy-mev "$EMEV" --events "$NSTOCK" > stock.toml

# request mode: N requests at exactly E
awk -v n="$N" -v nu="$NU" -v c="$CUR" -v t="$TGT" -v e="$E" 'BEGIN {
  print "# extgen-requests v1 (extgen_neut_v3.sh)"
  print "# req_id run subrun event truth_idx nu_pdg ccnc tgt_pdg E_GeV vx vy vz t dx dy dz"
  for (i = 0; i < n; i++) printf "%d 1 %d %d 0 %d %s %d %s 0 0 0 0 0 0 1\n", i, i + 1, i, nu, c, t, e }' > requests.txt
echo "extgen_neut_v3.sh: request mode, $N events ($(date -u))"
"$RUN" "$NEUT" -m serve -c card.toml -r requests.txt -s request.txt -t trial_stats.txt -S "$SEED" \
  > request.log 2>&1 || die "request mode failed (request.log)"

# stock NEUT (its seed file name must be short: NEUT reads 80 characters)
echo "$(( SEED + 1 )) $(( SEED + 2 )) $(( SEED + 3 )) 0 0" > seed_stock.txt
echo "extgen_neut_v3.sh: stock NEUT, $NSTOCK events ($(date -u))"
RANFILE=seed_stock.txt "$RUN" --stock "$NEUT" stock.toml stock.root > stock.log 2>&1 \
  || die "stock NEUT failed (stock.log)"
"$RUN" "$NEUT" -m convert -i stock.root -s stock.txt -g "$TGT" -n "$NU" -C "$CUR" > convert.log 2>&1 \
  || die "conversion failed (convert.log)"

# Pauli-blocked fractions
read -r RQ_T RQ_D < <(awk '!/^#/ { n += $6; d += $10 } END { print n + 0, d + 0 }' trial_stats.txt)
# "neut_extgen: converted C of T entries (D without lepton, X of the other current)"
read -r ST_C ST_D < <(awk '/converted/ { gsub(/[(,]/, " "); print $3, $7 }' convert.log)
PB=$(awk -v t="$RQ_T" -v d="$RQ_D" -v c="$ST_C" -v sd="$ST_D" 'BEGIN {
  f1 = d / t; n2 = c + sd; f2 = sd / n2
  v = f1 * (1 - f1) / t + f2 * (1 - f2) / n2
  pull = (v > 0) ? (f1 - f2) / sqrt(v) : 0
  printf "Pauli-blocked fraction: request %.5f (%d of %d), stock %.5f (%d of %d), pull %+.2f", f1, d, t, f2, sd, n2, pull
  exit (pull > 4 || pull < -4) }') && pbok=1 || pbok=0

{
  echo "# extgen_neut_v3.sh: target $TGT nu $NU $CUR E $E GeV, request seed $SEED, $(date -u)"
  echo "# NEUT $(awk '/^commit:/ {print $2}' "$NEUT/BUILD_INFO"), card md5 $(md5sum "$CARD" | cut -c1-32)"
  echo "$PB"
} > v3_result.txt
set +e
"$PY" "$CMP" request.txt stock.txt --labels request,stock >> v3_result.txt 2>&1
rc=$?
set -e
cat v3_result.txt
[ "$pbok" -eq 1 ] || { echo "extgen_neut_v3.sh: the Pauli-blocked fractions differ"; rc=1; }
exit "$rc"
