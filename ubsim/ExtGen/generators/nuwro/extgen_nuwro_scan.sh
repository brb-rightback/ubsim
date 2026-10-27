#!/bin/bash
#
# One NuWro scan (nuwro_extgen -m scan) for the spline and Max tables: a fixed
# number of trials per channel at each energy of a list, for one target,
# flavour and current. Statistics from any number of scans (different seeds)
# are merged by extgen_nuwro_tables.py.
#
# Usage:
#   extgen_nuwro_scan.sh -d NUWRO_DIR -t TARGET_PDG -n NU_PDG -c CC|NC
#                        -e ENERGY_FILE -N TRIALS -s SEED -o OUT_DIR
#
#   NUWRO_DIR    unpacked NuWro tarball (make_nuwro_tarball.sh): bin/nuwro_extgen,
#                data/, BUILD_INFO
#   ENERGY_FILE  energies in GeV, one per line ('#' comments), e.g.
#                extgen_nuwro_energies.txt
#   TRIALS       trials per energy and channel
#   SEED         NuWro random seed (2..899999999; different for every scan job)
#
# OUT_DIR gets: extgen_scan.info (what was scanned, with which build and card),
# scan.txt (nuwro_extgen's statistics), the card, and the NuWro log (gzipped).
# NuWro runs through extgen_nuwro_run.sh (clean environment with the products
# of the build). Fails if NuWro fails or does not scan every energy.

set -euo pipefail

die() { echo "extgen_nuwro_scan.sh: ERROR: $*" >&2; exit 1; }
HERE=$(dirname "$(realpath "$0")")

NUWRO= TGT= NU= CUR= EFILE= TRIALS= SEED= OUT=
while getopts "d:t:n:c:e:N:s:o:" opt; do
  case $opt in
    d) NUWRO=$OPTARG ;; t) TGT=$OPTARG ;; n) NU=$OPTARG ;; c) CUR=$OPTARG ;;
    e) EFILE=$OPTARG ;; N) TRIALS=$OPTARG ;; s) SEED=$OPTARG ;; o) OUT=$OPTARG ;;
    *) die "bad option (see the header of this script)" ;;
  esac
done
for v in NUWRO TGT NU CUR EFILE TRIALS SEED OUT; do
  [ -n "${!v}" ] || die "missing option for $v"
done
NUWRO=$(realpath "$NUWRO")
[ -f "$NUWRO/BUILD_INFO" ] || die "$NUWRO/BUILD_INFO not found"
[ -f "$EFILE" ] || die "energy file $EFILE not found"
[[ "$TRIALS" =~ ^[0-9]+$ ]] && [ "$TRIALS" -gt 0 ] || die "TRIALS must be a positive integer"
[[ "$SEED" =~ ^[0-9]+$ ]] && [ "$SEED" -gt 1 ] && [ "$SEED" -lt 900000000 ] \
  || die "SEED must be an integer in 2..899999999"

mkdir -p "$OUT"
OUT=$(realpath "$OUT")
[ ! -e "$OUT/scan.txt" ] || die "$OUT already holds a scan"

# requests: req_id E
awk '!/^[[:space:]]*(#|$)/ { printf "%d %s\n", n++, $1 }' "$EFILE" > "$OUT/requests.in"
NE=$(wc -l < "$OUT/requests.in")
[ "$NE" -gt 0 ] || die "no energies in $EFILE"

"$HERE/extgen_nuwro_card.sh" --target "$TGT" --nu "$NU" --current "$CUR" > "$OUT/card.txt"

{
  echo "# extgen-nuwro-scan v1"
  echo "target $TGT"
  echo "nu $NU"
  echo "current $CUR"
  echo "trials $TRIALS"
  echo "seed $SEED"
  echo "nuwro_commit $(awk '/^commit:/ {print $2}' "$NUWRO/BUILD_INFO")"
  echo "nuwro_md5 $(awk '/^nuwro_extgen md5:/ {print $3}' "$NUWRO/BUILD_INFO")"
  echo "card_md5 $(md5sum "$HERE/extgen_nuwro_card.sh" | awk '{print $1}')"
  echo "host $(hostname)"
  echo "start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/extgen_scan.info"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/extgen_nuwro_scan.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
status=0
"$HERE/extgen_nuwro_run.sh" "$NUWRO" -m scan -n "$TRIALS" -r "$OUT/requests.in" -t scan.txt \
  -i "$OUT/card.txt" -o scan -p "random_seed=$SEED" > nuwro.log 2>&1 || status=$?
gzip -c nuwro.log > "$OUT/nuwro.log.gz"
[ "$status" -eq 0 ] || die "NuWro failed (exit $status), see $OUT/nuwro.log.gz"
[ -f scan.txt ] || die "NuWro wrote no scan.txt"
ndone=$(awk '!/^#/ {print $1}' scan.txt | sort -u | wc -l)
[ "$ndone" -eq "$NE" ] || die "NuWro scanned $ndone of $NE energies"
cp scan.txt "$OUT/"
echo "end $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT/extgen_scan.info"
echo "extgen_nuwro_scan.sh: $NE energies x $TRIALS trials per channel done: $OUT"
