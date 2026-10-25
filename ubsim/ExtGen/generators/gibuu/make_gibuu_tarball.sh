#!/bin/bash
#
# Packs a GiBUU build (from build_gibuu.sh) and the ExtGen GiBUU scripts into
# the tarball that grid jobs unpack. The unpacked tarball is a GIBUU_DIR as
# the scripts expect it:
#   release/objects/GiBUU.x  buuinput/  lib/  BUILD_INFO  version.txt
#   extgen/   extgen_gibuu_card.sh extgen_gibuu_scan.sh extgen_gibuu_scan_grid.sh
#             extgen_gibuu_energies.txt
#
# Usage:
#   ./make_gibuu_tarball.sh BUILD_DIR OUT.tar.gz
#
# Refuses a build that does not contain request mode (GiBUU branch
# v08_00_00_br), e.g. one made before the request-mode commit.

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 BUILD_DIR OUT.tar.gz" >&2
  exit 2
fi
BUILD=$(realpath "$1")
OUTF=$(realpath -m "$2")
HERE=$(dirname "$(realpath "$0")")

EXE=$BUILD/release/objects/GiBUU.x
for f in "$EXE" "$BUILD/BUILD_INFO" "$BUILD/version.txt"; do
  [ -e "$f" ] || { echo "ERROR: $f not found (run build_gibuu.sh)" >&2; exit 1; }
done
[ -d "$BUILD/buuinput" ] && [ -d "$BUILD/lib" ] || { echo "ERROR: $BUILD has no buuinput/ or lib/" >&2; exit 1; }
if ! grep -q "uboone_requests" "$EXE"; then
  echo "ERROR: $EXE has no request mode (namelist uboone_requests)." >&2
  echo "       Rebuild from a GiBUU commit that contains code/init/neutrino/nuRequests.f90." >&2
  exit 1
fi
md5=$(md5sum "$EXE" | cut -c1-32)
grep -q "$md5" "$BUILD/BUILD_INFO" || { echo "ERROR: GiBUU.x does not match BUILD_INFO" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/release/objects" "$STAGE/extgen"
cp "$EXE" "$STAGE/release/objects/"
cp -rL "$BUILD/buuinput" "$STAGE/buuinput"
cp -rL "$BUILD/lib" "$STAGE/lib"
cp "$BUILD/BUILD_INFO" "$BUILD/version.txt" "$STAGE/"
cp "$HERE/extgen_gibuu_card.sh" "$HERE/extgen_gibuu_scan.sh" "$HERE/extgen_gibuu_scan_grid.sh" \
   "$HERE/extgen_gibuu_energies.txt" "$STAGE/extgen/"
echo "packed: $(date -u +%Y-%m-%dT%H:%M:%SZ) from $BUILD" >> "$STAGE/BUILD_INFO"

tar -czf "$OUTF" -C "$STAGE" .
echo "wrote $OUTF ($(du -h "$OUTF" | cut -f1)), GiBUU commit $(awk '/^commit:/ {print $2}' "$BUILD/BUILD_INFO")"
