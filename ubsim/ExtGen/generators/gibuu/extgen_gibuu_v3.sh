#!/bin/bash
#
# Validation V3: GiBUU request mode against stock GiBUU at one fixed energy.
# Both runs use the same card (extgen_gibuu_card.sh) and the same Max:
#   OUT/request: request mode, NEVENTS requests all at ENERGY;
#   OUT/stock:   stock GiBUU, nuXsectionMode 6 (fixed energy), equal weights,
#                with enough runs for about NEVENTS events (estimated from
#                the request run's own cross section).
# Compare with extgen_gibuu_v3_compare.py OUT [OUT2 ...] (several seeds can
# be merged).
#
# Usage:
#   extgen_gibuu_v3.sh -g GIBUU_DIR -t TARGET_PDG -n NU_PDG -c CC|NC
#                      -E ENERGY -M MAX -N NEVENTS -s SEED -o OUT [-e ENSEMBLES]
#
# MAX must exceed every trial weight at ENERGY (see the Max table); GiBUU
# aborts otherwise. Time: about NEVENTS x MAX / sigma trials per run type at
# ~2 ms each (sigma = mean trial weight, per nucleon).

set -euo pipefail

die() { echo "extgen_gibuu_v3.sh: ERROR: $*" >&2; exit 1; }
HERE=$(dirname "$(realpath "$0")")

GIBUU= TGT= NU= CUR= E= MAX= NEV= SEED= OUT= ENS=1000
while getopts "g:t:n:c:E:M:N:s:o:e:" opt; do
  case $opt in
    g) GIBUU=$OPTARG ;; t) TGT=$OPTARG ;; n) NU=$OPTARG ;; c) CUR=$OPTARG ;;
    E) E=$OPTARG ;; M) MAX=$OPTARG ;; N) NEV=$OPTARG ;; s) SEED=$OPTARG ;;
    o) OUT=$OPTARG ;; e) ENS=$OPTARG ;;
    *) die "bad option (see the header of this script)" ;;
  esac
done
for v in GIBUU TGT NU CUR E MAX NEV SEED OUT; do
  [ -n "${!v}" ] || die "missing option for $v"
done
GIBUU=$(realpath "$GIBUU")
EXE=$GIBUU/release/objects/GiBUU.x
[ -x "$EXE" ] || die "$EXE not found"
mkdir -p "$OUT"
OUT=$(realpath "$OUT")
export LD_LIBRARY_PATH=$GIBUU/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
A=$(( (TGT / 10) % 1000 ))

{
  echo "target $TGT"; echo "nu $NU"; echo "current $CUR"; echo "energy $E"
  echo "max $MAX"; echo "nevents $NEV"; echo "seed $SEED"; echo "ensembles $ENS"
  echo "gibuu_commit $(awk '/^commit:/ {print $2}' "$GIBUU/BUILD_INFO")"
} > "$OUT/v3.info"

run_gibuu() {  # dir
  (cd "$1" && "$EXE" < gibuu.job > gibuu.log 2>&1) || die "GiBUU failed in $1 (see gibuu.log)"
  grep -q "HepMC::Asciiv3-END_EVENT_LISTING" "$1/EventOutput.Pert.hepmc3" \
    || die "no complete NuHepMC output in $1"
  find "$1" -maxdepth 1 -type f ! -name 'gibuu.job' ! -name 'gibuu.log' ! -name 'requests.in' \
       ! -name 'EventOutput.Pert.hepmc3' ! -name 'uboone_request_stats.dat' -delete
}

# --- request mode: NEV requests at E, runs capped generously
mkdir -p "$OUT/request"
awk -v n="$NEV" -v e="$E" -v m="$MAX" 'BEGIN { for (i = 0; i < n; ++i) print i, e, m }' \
  > "$OUT/request/requests.in"
"$HERE/extgen_gibuu_card.sh" --mode serve --target "$TGT" --nu "$NU" --current "$CUR" \
  --requests "$OUT/request/requests.in" --buuinput "$GIBUU/buuinput" --seed "$SEED" \
  --ensembles "$ENS" --runs 100000 > "$OUT/request/gibuu.job"
echo "extgen_gibuu_v3.sh: request mode, $NEV events at $E GeV ($(date -u))"
run_gibuu "$OUT/request"

# --- stock: runs for ~NEV events from the request run's sigma = sum_w / n_trials
read -r NTR SUMW < <(awk '!/^#/ { n += $4; s += $5 } END { print n, s }' \
                       "$OUT/request/uboone_request_stats.dat")
RUNS=$(awk -v nev="$NEV" -v max="$MAX" -v ntr="$NTR" -v sw="$SUMW" -v ens="$ENS" -v a="$A" \
         'BEGIN { sig = sw / ntr; r = nev * max / (sig * ens * a); printf "%d", r + 1 }')
mkdir -p "$OUT/stock"
cp "$OUT/request/requests.in" "$OUT/stock/requests.in"
"$HERE/extgen_gibuu_card.sh" --mode serve --target "$TGT" --nu "$NU" --current "$CUR" \
  --requests "$OUT/stock/requests.in" --buuinput "$GIBUU/buuinput" --seed $(( SEED + 1 )) \
  --ensembles "$ENS" --runs "$RUNS" --stock-enu "$E" > "$OUT/stock/gibuu.job"
echo "extgen_gibuu_v3.sh: stock GiBUU, $RUNS runs at $E GeV ($(date -u))"
run_gibuu "$OUT/stock"

echo "extgen_gibuu_v3.sh: done: $(grep -c '^E ' "$OUT/request/EventOutput.Pert.hepmc3") request-mode and" \
     "$(grep -c '^E ' "$OUT/stock/EventOutput.Pert.hepmc3") stock events in $OUT"
