#!/bin/bash
#
# Packs a NEUT build (from build_neut.sh) and the ExtGen NEUT scripts into the
# tarball that grid jobs unpack. The unpacked tarball is a NEUT_DIR as the
# scripts expect it:
#   bin/neut_extgen   neut/ (NEUT installation: bin lib [lib64] include share)
#   BUILD_INFO
#   extgen/   extgen_neut_card.sh extgen_neut_run.sh extgen_neut_serve.sh
#             extgen_neut_energies.txt extgen_neut_pb_energies.txt
#
# Usage:
#   ./make_neut_tarball.sh BUILD_DIR OUT.tar.gz
#
# The tarball holds no ROOT: grid jobs set up the UPS products recorded in
# BUILD_INFO from CVMFS (extgen_neut_run.sh). NEUT's source and CMake build
# tree are not packed.

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 BUILD_DIR OUT.tar.gz" >&2
  exit 2
fi
BUILD=$(realpath "$1")
OUTF=$(realpath -m "$2")
HERE=$(dirname "$(realpath "$0")")

EXE=$BUILD/bin/neut_extgen
for f in "$EXE" "$BUILD/BUILD_INFO" "$BUILD/neut/share/neut/Cards/NEUT.Defaults.toml"; do
  [ -e "$f" ] || { echo "ERROR: $f not found (run build_neut.sh)" >&2; exit 1; }
done
[ -d "$BUILD/neut/lib" ] && [ -d "$BUILD/neut/share/neut/crsdat" ] \
  || { echo "ERROR: $BUILD/neut is not a NEUT installation" >&2; exit 1; }
grep -q "^ups products:" "$BUILD/BUILD_INFO" || { echo "ERROR: BUILD_INFO has no 'ups products:' line" >&2; exit 1; }
md5=$(md5sum "$EXE" | cut -c1-32)
grep -q "^neut_extgen md5: $md5" "$BUILD/BUILD_INFO" || { echo "ERROR: neut_extgen does not match BUILD_INFO" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bin" "$STAGE/extgen" "$STAGE/neut"
cp "$EXE" "$STAGE/bin/"
for d in bin lib lib64 include share; do
  [ -d "$BUILD/neut/$d" ] && cp -rL "$BUILD/neut/$d" "$STAGE/neut/"
done
cp "$BUILD/BUILD_INFO" "$STAGE/"
for f in extgen_neut_card.sh extgen_neut_run.sh extgen_neut_serve.sh \
         extgen_neut_energies.txt extgen_neut_pb_energies.txt; do
  cp "$HERE/$f" "$STAGE/extgen/"
done
echo "packed: $(date -u +%Y-%m-%dT%H:%M:%SZ) from $BUILD" >> "$STAGE/BUILD_INFO"

tar -czf "$OUTF" -C "$STAGE" .
echo "wrote $OUTF ($(du -h "$OUTF" | cut -f1)), NEUT commit $(awk '/^commit:/ {print $2}' "$BUILD/BUILD_INFO")"
