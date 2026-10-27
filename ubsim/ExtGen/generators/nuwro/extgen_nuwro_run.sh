#!/bin/bash
#
# Runs NuWro's request-mode program (nuwro_extgen) of an unpacked NuWro
# tarball (make_nuwro_tarball.sh) in a clean environment with the UPS
# products it was built against, separate from the calling (e.g. a grid job's
# e17 uboonecode) environment. Arguments after NUWRO_DIR go to nuwro_extgen;
# it runs in the current directory.
#
# Usage:
#   extgen_nuwro_run.sh NUWRO_DIR [nuwro_extgen arguments ...]
#   extgen_nuwro_run.sh --check NUWRO_DIR      environment and libraries only
#
# The products are those of the tarball's BUILD_INFO ("ups setup:",
# "ups products:"). The environment starts empty (env -i) apart from HOME,
# USER, TMPDIR and a minimal PATH, so that no e17 library (ROOT 6.12, its
# gcc runtime) can be loaded into the e26 binary.
#
# Exit code: nuwro_extgen's (0 ok, 2 bad input, 3 a weight above Max, 4
# NuWro failure), 5 if the environment could not be set up or a library is
# missing.
#
# For tests without UPS (e.g. a local build): EXTGEN_NUWRO_ENV=FILE sources
# FILE instead of the UPS setup (it must set up ROOT and Pythia6).

set -uo pipefail

die() { echo "extgen_nuwro_run.sh: ERROR: $*" >&2; exit 5; }

CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
[ $# -ge 1 ] || die "usage: extgen_nuwro_run.sh [--check] NUWRO_DIR [nuwro_extgen arguments ...]"
NUWRO_DIR=$(realpath "$1"); shift
EXE=$NUWRO_DIR/bin/nuwro_extgen
[ -x "$EXE" ] || die "$EXE not found"
[ -f "$NUWRO_DIR/BUILD_INFO" ] || die "$NUWRO_DIR/BUILD_INFO not found"
UPS_SETUP=$(awk '/^ups setup:/ {sub(/^ups setup: */, ""); print}' "$NUWRO_DIR/BUILD_INFO")
BUILD_PRODUCTS=$(awk '/^ups products:/ {sub(/^ups products: */, ""); print}' "$NUWRO_DIR/BUILD_INFO")
if [ -z "${EXTGEN_NUWRO_ENV:-}" ]; then
  [ -n "$UPS_SETUP" ] && [ -n "$BUILD_PRODUCTS" ] || die "no 'ups setup:'/'ups products:' lines in $NUWRO_DIR/BUILD_INFO"
fi

# The inner script: set up, check libraries, run. Its own errors exit with 5.
INNER='
  if [ -n "${EXTGEN_NUWRO_ENV:-}" ]; then
    source "$EXTGEN_NUWRO_ENV" > /dev/null 2>&1 || { echo "cannot source $EXTGEN_NUWRO_ENV" >&2; exit 5; }
  else
    # UPS setups can return non-zero without anything being wrong (and the
    # setup function uses global variables): judge by the result instead
    _nw_log=$(mktemp "${TMPDIR:-/tmp}/extgen_nuwro_setup.XXXXXX")
    source "$UPS_SETUP" > "$_nw_log" 2>&1 || true
    if ! type setup > /dev/null 2>&1; then
      echo "sourcing $UPS_SETUP did not define setup:" >&2; cat "$_nw_log" >&2; exit 5
    fi
    IFS=";" read -ra _nw_prods <<< "$NUWRO_UPS_PRODUCTS"
    for _nw_prod in "${_nw_prods[@]}"; do
      echo "setup $_nw_prod" >> "$_nw_log"
      setup $_nw_prod >> "$_nw_log" 2>&1 || echo "(setup returned $?)" >> "$_nw_log"
    done
    if [ -z "${ROOTSYS:-}" ] || ! command -v root-config > /dev/null || [ -z "${PYTHIA_FQ_DIR:-}" ]; then
      echo "UPS setup of \"$NUWRO_UPS_PRODUCTS\" incomplete (ROOTSYS=${ROOTSYS:-} PYTHIA_FQ_DIR=${PYTHIA_FQ_DIR:-}):" >&2
      cat "$_nw_log" >&2
      exit 5
    fi
    rm -f "$_nw_log"
    export LD_LIBRARY_PATH=$PYTHIA_FQ_DIR/lib:$LD_LIBRARY_PATH
  fi
  export LD_LIBRARY_PATH=$NUWRO_DIR/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
  missing=$(ldd "$EXE" | grep "not found")
  [ -z "$missing" ] || { echo "unresolved libraries: $missing" >&2; exit 5; }
  if [ "$CHECK" = 1 ]; then
    echo "nuwro_extgen environment ok: ROOT $(root-config --version 2>/dev/null || echo ?)"
    exit 0
  fi
  exec "$EXE" "$@"
'
# The product list goes in as NUWRO_UPS_PRODUCTS, never PRODUCTS: that is UPS's
# own variable (its product databases), which the setup script reads.
env -i HOME="${HOME:-/tmp}" USER="${USER:-nobody}" LOGNAME="${LOGNAME:-${USER:-nobody}}" \
    HOSTNAME="${HOSTNAME:-$(hostname)}" SHELL=/bin/bash TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin \
    NUWRO_DIR="$NUWRO_DIR" EXE="$EXE" CHECK="$CHECK" UPS_SETUP="$UPS_SETUP" NUWRO_UPS_PRODUCTS="$BUILD_PRODUCTS" \
    ${EXTGEN_NUWRO_ENV:+EXTGEN_NUWRO_ENV="$EXTGEN_NUWRO_ENV"} \
    bash -c "$INNER" nuwro_extgen "$@"
