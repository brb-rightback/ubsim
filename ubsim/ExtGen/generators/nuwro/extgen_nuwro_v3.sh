#!/bin/bash
#
# Validation V3 for NuWro: request mode (nuwro_extgen -m serve, as in grid
# jobs) against stock NuWro (nuwro_extgen -m stock: NuWro's own test_events
# and real_events) at one fixed energy, same card (extgen_nuwro_card.sh).
#
# Usage:
#   extgen_nuwro_v3.sh -d NUWRO_DIR -t TARGET_PDG -n NU_PDG -c CC|NC -E E_GeV
#                      -N EVENTS -s SEED -o OUT_DIR
#                      [-T STOCK_TEST_EVENTS] [-S SCAN_TRIALS] [-k MARGIN] [-R PIECES]
#
#   NUWRO_DIR   unpacked NuWro tarball (make_nuwro_tarball.sh)
#   EVENTS      events of each sample
#   SEED        seeds SEED (scan), SEED+1 (request mode), SEED+2+10k (stock
#               piece k); > 1
#   STOCK_TEST_EVENTS  stock NuWro's number_of_test_events in total, which set
#               its cross sections and channel fractions (default 1000000)
#   PIECES      stock NuWro runs as PIECES independent runs (seeds above) of
#               EVENTS/PIECES events and STOCK_TEST_EVENTS/PIECES test events,
#               pooled; request mode is split into PIECES consecutive batches
#               of requests. The cross-section errors are the spreads of the
#               pieces (default 8): NuWro's RES weights scatter from run to run
#               2-9 times more than their variance suggests (stock NuWro too),
#               so variance-based errors would make the test fail by itself.
#   SCAN_TRIALS trials per channel of the scan that sets the request-mode Max
#               (default 200000); Max = MARGIN (default 3) x the largest weight
#
# OUT_DIR gets the card, scan, request file, both event samples
# (request.txt, stock.txt), the request-mode trial statistics, stock NuWro's
# cross section, v3.info and v3_result.txt (extgen_served_compare.py; its exit
# code is this script's: 1 if a test is flagged).

set -euo pipefail

die() { echo "extgen_nuwro_v3.sh: ERROR: $*" >&2; exit 2; }
HERE=$(dirname "$(realpath "$0")")

NUWRO= TGT= NU= CUR= E= N= SEED= OUT= T=1000000 S=200000 K=3 R=8
while getopts "d:t:n:c:E:N:s:o:T:S:k:R:" opt; do
  case $opt in
    d) NUWRO=$OPTARG ;; t) TGT=$OPTARG ;; n) NU=$OPTARG ;; c) CUR=$OPTARG ;;
    E) E=$OPTARG ;; N) N=$OPTARG ;; s) SEED=$OPTARG ;; o) OUT=$OPTARG ;;
    T) T=$OPTARG ;; S) S=$OPTARG ;; k) K=$OPTARG ;; R) R=$OPTARG ;;
    *) die "bad option (see the header of this script)" ;;
  esac
done
for v in NUWRO TGT NU CUR E N SEED OUT; do
  [ -n "${!v}" ] || die "missing option for $v"
done
[[ "$SEED" =~ ^[0-9]+$ ]] && [ "$SEED" -gt 1 ] || die "SEED must be an integer > 1"
NUWRO=$(realpath "$NUWRO")
COMPARE=$(command -v extgen_served_compare.py || echo "$HERE/../../tools/extgen_served_compare.py")
[ -f "$COMPARE" ] || die "extgen_served_compare.py not found"
mkdir -p "$OUT"
OUT=$(realpath "$OUT")
cd "$OUT"
RUN="$HERE/extgen_nuwro_run.sh"

"$HERE/extgen_nuwro_card.sh" --target "$TGT" --nu "$NU" --current "$CUR" > card.txt
A=$(( (TGT / 10) % 1000 ))
EMEV=$(awk -v e="$E" 'BEGIN { printf "%.10g", e * 1000 }')
{
  echo "target $TGT"; echo "nu $NU"; echo "current $CUR"; echo "energy $E"; echo "events $N"
  echo "seed $SEED"; echo "stock_test_events $T"; echo "scan_trials $S"; echo "margin $K"
  echo "pieces $R"
  echo "nuwro_commit $(awk '/^commit:/ {print $2}' "$NUWRO/BUILD_INFO")"
  echo "nuwro_md5 $(awk '/^nuwro_extgen md5:/ {print $3}' "$NUWRO/BUILD_INFO")"
  echo "card_md5 $(md5sum "$HERE/extgen_nuwro_card.sh" | awk '{print $1}')"
} > v3.info

# --- 1. scan at E: the Max of each channel
echo "0 $E" > energy.txt
"$RUN" "$NUWRO" -m scan -n "$S" -r energy.txt -t scan.txt -i card.txt -o scan \
  -p "random_seed=$SEED" > scan.log 2>&1 || die "scan failed (scan.log)"
CH=$(awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^channels=/) { sub("channels=", "", $i); print $i } }' scan.txt)
MAXES=$(awk -v k="$K" '!/^#/ { printf " %.6g", k * $7 }' scan.txt)

# --- 2. request mode: N requests at E
{
  echo "# extgen-nuwro-requests v1 channels=$CH"
  awk -v n="$N" -v e="$E" -v m="$MAXES" 'BEGIN { for (i = 0; i < n; i++) print i, e m }'
} > requests.in
"$RUN" "$NUWRO" -m serve -r requests.in -s request.txt -t request_stats.txt -i card.txt \
  -o request -p "random_seed=$(( SEED + 1 ))" > request.log 2>&1 \
  || die "request mode failed (request.log; exit 3 = a weight above its Max)"
# sigma and its error from R consecutive batches of requests
SIG_REQ=$(awk -v a="$A" -v r="$R" -v n="$N" '!/^#/ { b = int(k++ * r / n); bn[b] += $6; bs[b] += $7; tn += $6; ts += $7 }
  END { m = ts / tn; for (i = 0; i < r; i++) { x = bs[i] / bn[i]; v += (x - m) ^ 2 }
        printf "%.10g,%.10g", m / a, sqrt(v / (r - 1) / r) / a }' request_stats.txt)

# --- 3. stock NuWro at E, in R independent pieces
NP=$(( (N + R - 1) / R ))
TP=$(( (T + R - 1) / R ))
: > stock_sigma.txt
for k in $(seq 0 $(( R - 1 ))); do
  "$RUN" "$NUWRO" -m stock -s stock_$k.txt -t stock_sigma_$k.txt -i card.txt -o stock_$k \
    -p "random_seed=$(( SEED + 2 + 10 * k ))" -p "beam_energy=$EMEV" -p "number_of_events=$NP" \
    -p "number_of_test_events=$TP" > stock_$k.log 2>&1 || die "stock NuWro failed (stock_$k.log)"
  cat stock_sigma_$k.txt >> stock_sigma.txt
  rm -f stock_$k.root
done
{ grep '^#' stock_0.txt; for k in $(seq 0 $(( R - 1 ))); do grep -v '^#' stock_$k.txt; done; } > stock.txt
SIG_STK=$(awk '$1 == "stock_sigma" { x[++r] = $2; s += $2 }
  END { m = s / r; for (i = 1; i <= r; i++) v += (x[i] - m) ^ 2; printf "%.10g,%.10g", m, sqrt(v / (r - 1) / r) }' \
  stock_sigma.txt)

# --- 4. compare
status=0
"$(command -v python || command -v python3)" "$COMPARE" request.txt stock.txt --labels request,stock \
  --sigma-a "$SIG_REQ" --sigma-b "$SIG_STK" > v3_result.txt 2>&1 || status=$?
cat v3_result.txt
exit "$status"
