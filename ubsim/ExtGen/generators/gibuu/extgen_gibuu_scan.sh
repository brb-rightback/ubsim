#!/bin/bash
#
# One GiBUU scan (request mode 2) for the spline and Max tables: a fixed
# number of trials at each energy of a list, for one target, flavour and
# current. Statistics from any number of scans (different seeds) are merged
# by extgen_gibuu_tables.py.
#
# Usage:
#   extgen_gibuu_scan.sh -g GIBUU_DIR -t TARGET_PDG -n NU_PDG -c CC|NC
#                        -e ENERGY_FILE -N TRIALS -s SEED -o OUT_DIR
#                        [-E ENSEMBLES]
#
#   GIBUU_DIR    output of build_gibuu.sh (release/objects/GiBUU.x, buuinput,
#                lib, BUILD_INFO)
#   ENERGY_FILE  energies in GeV, one per line ('#' comments), e.g.
#                extgen_gibuu_energies.txt
#   TRIALS       trials per energy
#   SEED         GiBUU random seed (positive; different for every scan job)
#
# OUT_DIR gets: extgen_scan.info (what was scanned, with which build),
# uboone_request_stats.dat, the card, and the GiBUU log (gzipped). Fails if
# GiBUU fails or does not finish every energy.

set -euo pipefail

die() { echo "extgen_gibuu_scan.sh: ERROR: $*" >&2; exit 1; }
HERE=$(dirname "$(realpath "$0")")

GIBUU= TGT= NU= CUR= EFILE= TRIALS= SEED= OUT= ENS=1000
while getopts "g:t:n:c:e:N:s:o:E:" opt; do
  case $opt in
    g) GIBUU=$OPTARG ;; t) TGT=$OPTARG ;; n) NU=$OPTARG ;; c) CUR=$OPTARG ;;
    e) EFILE=$OPTARG ;; N) TRIALS=$OPTARG ;; s) SEED=$OPTARG ;; o) OUT=$OPTARG ;;
    E) ENS=$OPTARG ;;
    *) die "bad option (see the header of this script)" ;;
  esac
done
for v in GIBUU TGT NU CUR EFILE TRIALS SEED OUT; do
  [ -n "${!v}" ] || die "missing option for $v"
done
GIBUU=$(realpath "$GIBUU")
EXE=$GIBUU/release/objects/GiBUU.x
[ -x "$EXE" ] || die "$EXE not found"
[ -f "$GIBUU/BUILD_INFO" ] || die "$GIBUU/BUILD_INFO not found"
[ -f "$EFILE" ] || die "energy file $EFILE not found"
[[ "$TRIALS" =~ ^[0-9]+$ ]] && [ "$TRIALS" -gt 0 ] || die "TRIALS must be a positive integer"

mkdir -p "$OUT"
OUT=$(realpath "$OUT")
[ ! -e "$OUT/uboone_request_stats.dat" ] || die "$OUT already holds a scan"

# requests: req_id E Max (Max unused in a scan)
awk '!/^[[:space:]]*(#|$)/ { printf "%d %s 0\n", n++, $1 }' "$EFILE" > "$OUT/requests.in"
NE=$(wc -l < "$OUT/requests.in")
[ "$NE" -gt 0 ] || die "no energies in $EFILE"

# trials per run = nucleons of all ensembles (A x ENS); runs with 10% margin
A=$(( (TGT / 10) % 1000 ))
RUNS=$(( (NE * TRIALS + A * ENS - 1) / (A * ENS) ))
RUNS=$(( RUNS + RUNS / 10 + 2 ))

"$HERE/extgen_gibuu_card.sh" --mode scan --target "$TGT" --nu "$NU" --current "$CUR" \
  --requests "$OUT/requests.in" --buuinput "$GIBUU/buuinput" --seed "$SEED" \
  --ensembles "$ENS" --runs "$RUNS" --trials "$TRIALS" > "$OUT/gibuu.job"

{
  echo "# extgen-gibuu-scan v1"
  echo "target $TGT"
  echo "nu $NU"
  echo "current $CUR"
  echo "trials $TRIALS"
  echo "seed $SEED"
  echo "ensembles $ENS"
  echo "gibuu_commit $(awk '/^commit:/ {print $2}' "$GIBUU/BUILD_INFO")"
  echo "gibuu_md5 $(awk '/^GiBUU.x md5:/ {print $3}' "$GIBUU/BUILD_INFO")"
  echo "card_md5 $(md5sum "$HERE/extgen_gibuu_card.sh" | awk '{print $1}')"
  echo "host $(hostname)"
  echo "start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/extgen_scan.info"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/extgen_scan.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
export LD_LIBRARY_PATH=$GIBUU/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
status=0
"$EXE" < "$OUT/gibuu.job" > gibuu.log 2>&1 || status=$?
gzip -c gibuu.log > "$OUT/gibuu.log.gz"
[ "$status" -eq 0 ] || die "GiBUU failed (exit $status), see $OUT/gibuu.log.gz"
[ -f uboone_request_stats.dat ] || die "GiBUU wrote no uboone_request_stats.dat"
grep -q "request mode: all" gibuu.log || die "GiBUU did not finish every energy"
cp uboone_request_stats.dat "$OUT/"
echo "end $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT/extgen_scan.info"
echo "extgen_gibuu_scan.sh: $NE energies x $TRIALS trials done: $OUT"
