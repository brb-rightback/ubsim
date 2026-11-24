#!/bin/bash
#
# Makes the cross-section tables of ExtGen NEUT for uboonedata (genie/neut/):
#   STEM_xsec.txt   nu_pdg CC|NC target_pdg E_GeV sigma[1e-38 cm^2 per nucleus]
#                   # rel_err sigma_NEUT f_PB   (neut_extgen -m xsec)
#   STEM_xsec.xml   the GENIE splines of tune NE06_02a_00_000 made from it
#                   (extgen_make_splines.py --cap 8 --extend-to 200)
# for every nucleus of the MicroBooNE geometry (13 volCryostat nuclei, N14,
# K39; the free neutron of the geometry's Vacuum as an explicit zero) and
# nu_e, nu_e-bar, nu_mu, nu_mu-bar, CC and NC.
#
# Unlike GiBUU and NuWro there is no grid scan campaign: NEUT's total cross
# sections are computed directly; only the Pauli-blocked fraction of NEUT's
# single-pion events needs NEUT events (-b per energy of
# extgen_neut_pb_energies.txt; see neut_extgen.cc). One process per target,
# NJOBS at a time.
#
# Usage:
#   extgen_neut_tables.sh -d NEUT_DIR -o OUT_DIR [-b EVENTS] [-j NJOBS] [-S STEM]
#
#   NEUT_DIR  unpacked NEUT tarball (make_neut_tarball.sh) or a build_neut.sh
#             directory with the scripts installed next to this one
#   EVENTS    NEUT events per energy of the blocking estimate (default 4000)
#   STEM      default neut_<NEUT version>_<card md5, 8 characters>
#
# The table header records the NEUT build (commit and neut_extgen md5) and the
# md5 of extgen_neut_card.sh; the grid jobs refuse tables of another build or
# card (extgen_neut_grid_init.sh). Needs python (extgen_make_splines.py) on
# PATH or next to this script's ubsim installation.

set -euo pipefail

die() { echo "extgen_neut_tables.sh: ERROR: $*" >&2; exit 1; }
HERE=$(dirname "$(realpath "$0")")

NEUT= OUT= NPB=4000 NJOBS=8 STEM=
while getopts "d:o:b:j:S:" opt; do
  case $opt in
    d) NEUT=$OPTARG ;;
    o) OUT=$OPTARG ;;
    b) NPB=$OPTARG ;;
    j) NJOBS=$OPTARG ;;
    S) STEM=$OPTARG ;;
    *) die "bad option (see the header of this script)" ;;
  esac
done
[ -n "$NEUT" ] && [ -n "$OUT" ] || die "give -d and -o"
NEUT=$(realpath "$NEUT")
[ -f "$NEUT/BUILD_INFO" ] || die "$NEUT/BUILD_INFO not found"
RUN=$HERE/extgen_neut_run.sh
CARD=$HERE/extgen_neut_card.sh
ENERGIES=$HERE/extgen_neut_energies.txt
PBE=$HERE/extgen_neut_pb_energies.txt
for f in "$RUN" "$CARD" "$ENERGIES" "$PBE"; do [ -f "$f" ] || die "$f missing"; done
SPLINES=$(command -v extgen_make_splines.py || true)
[ -n "$SPLINES" ] || SPLINES=$(realpath -m "$HERE/../../tools/extgen_make_splines.py")
[ -f "$SPLINES" ] || die "extgen_make_splines.py not found"

COMMIT=$(awk '/^commit:/ {print $2}' "$NEUT/BUILD_INFO")
EXEMD5=$(awk '/^neut_extgen md5:/ {print $3}' "$NEUT/BUILD_INFO")
# the git tag of the build (BUILD_INFO "NEUT version: <neut-config> (<tag>)"): NEUT's
# self-reported version is 6.2.0 for the tag 6.2.3
VERSION=$(awk '/^NEUT version:/ { v = $3; if (match($0, /\(([^)]*)\)/)) v = substr($0, RSTART + 1, RLENGTH - 2); print v }' \
          "$NEUT/BUILD_INFO" | tr . _)
CARDMD5=$(md5sum "$CARD" | cut -c1-32)
[ -n "$STEM" ] || STEM=neut_${VERSION}_${CARDMD5:0:8}

TARGETS="1000010010 1000060120 1000070140 1000080160 1000110230 1000120240 1000130270 1000140280
         1000180400 1000190390 1000200400 1000220480 1000240520 1000260560 1000280590 1000000010"

mkdir -p "$OUT/parts"
OUT=$(realpath "$OUT")
"$CARD" > "$OUT/card.toml"
echo "extgen_neut_tables.sh: $STEM, NEUT $COMMIT, card $CARDMD5, $NPB blocking events per energy, $NJOBS jobs"
for t in $TARGETS; do
  (
    d=$OUT/parts/$t
    mkdir -p "$d" && cd "$d"
    "$RUN" "$NEUT" -m xsec -c "$OUT/card.toml" -e "$ENERGIES" -o xsec.txt -g "$t" \
      -b "$NPB" -B "$PBE" > neut.log 2>&1 && echo ok > done || echo "FAILED (exit $?)" > done
  ) &
  while [ "$(jobs -rp | wc -l)" -ge "$NJOBS" ]; do sleep 2; done
done
wait
for t in $TARGETS; do
  grep -q '^ok$' "$OUT/parts/$t/done" 2>/dev/null || die "target $t failed ($OUT/parts/$t/neut.log)"
done

TABLE=$OUT/${STEM}_xsec.txt
{
  echo "# NEUT total cross sections for ExtGen (extgen_neut_tables.sh, neut_extgen -m xsec)"
  echo "# NEUT build(s): $COMMIT/$EXEMD5"
  echo "# NEUT card md5: $CARDMD5"
  grep -h '^# \(substitutions\|zero\|Pauli\)' "$OUT/parts/1000180400/xsec.txt"
  echo "# nu_pdg CC|NC target_pdg E_GeV sigma[1e-38 cm^2 per nucleus]   # rel_err sigma_NEUT f_PB"
  for t in $TARGETS; do grep -v '^#' "$OUT/parts/$t/xsec.txt"; done
} > "$TABLE"
python "$SPLINES" "$TABLE" "$OUT/${STEM}_xsec.xml" --tune NE06_02a_00_000 --cap 8 --extend-to 200 \
  || python3 "$SPLINES" "$TABLE" "$OUT/${STEM}_xsec.xml" --tune NE06_02a_00_000 --cap 8 --extend-to 200
echo "extgen_neut_tables.sh: wrote $TABLE and $OUT/${STEM}_xsec.xml"
