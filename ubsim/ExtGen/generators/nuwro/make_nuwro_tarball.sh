#!/bin/bash
#
# Packs a NuWro build (from build_nuwro.sh) and the ExtGen NuWro scripts into
# the tarball that grid jobs unpack. The unpacked tarball is a NUWRO_DIR as
# the scripts expect it:
#   bin/nuwro_extgen  bin/event1Dict_rdict.pcm  data/  BUILD_INFO
#   extgen/   extgen_nuwro_card.sh extgen_nuwro_run.sh extgen_nuwro_scan.sh
#             extgen_nuwro_scan_grid.sh extgen_nuwro_energies.txt
#
# Usage:
#   ./make_nuwro_tarball.sh BUILD_DIR OUT.tar.gz
#
# The tarball holds no ROOT or Pythia6: grid jobs set up the UPS products
# recorded in BUILD_INFO from CVMFS (extgen_nuwro_run.sh).

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 BUILD_DIR OUT.tar.gz" >&2
  exit 2
fi
BUILD=$(realpath "$1")
OUTF=$(realpath -m "$2")
HERE=$(dirname "$(realpath "$0")")

EXE=$BUILD/bin/nuwro_extgen
for f in "$EXE" "$BUILD/bin/event1Dict_rdict.pcm" "$BUILD/BUILD_INFO"; do
  [ -e "$f" ] || { echo "ERROR: $f not found (run build_nuwro.sh)" >&2; exit 1; }
done
[ -d "$BUILD/data" ] || { echo "ERROR: $BUILD has no data/" >&2; exit 1; }
grep -q "^ups products:" "$BUILD/BUILD_INFO" || { echo "ERROR: BUILD_INFO has no 'ups products:' line" >&2; exit 1; }
md5=$(md5sum "$EXE" | cut -c1-32)
grep -q "$md5" "$BUILD/BUILD_INFO" || { echo "ERROR: nuwro_extgen does not match BUILD_INFO" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bin" "$STAGE/extgen"
cp "$EXE" "$BUILD/bin/event1Dict_rdict.pcm" "$STAGE/bin/"
cp -rL "$BUILD/data" "$STAGE/data"
cp "$BUILD/BUILD_INFO" "$STAGE/"
for f in extgen_nuwro_card.sh extgen_nuwro_run.sh extgen_nuwro_scan.sh extgen_nuwro_scan_grid.sh \
         extgen_nuwro_energies.txt; do
  cp "$HERE/$f" "$STAGE/extgen/"
done
echo "packed: $(date -u +%Y-%m-%dT%H:%M:%SZ) from $BUILD" >> "$STAGE/BUILD_INFO"

tar -czf "$OUTF" -C "$STAGE" .
echo "wrote $OUTF ($(du -h "$OUTF" | cut -f1)), NuWro commit $(awk '/^commit:/ {print $2}' "$BUILD/BUILD_INFO")"
