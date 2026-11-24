#!/bin/bash
#
# Runs ExtGen's NEUT driver (neut_extgen) of an unpacked NEUT tarball
# (make_neut_tarball.sh) in a clean environment with the UPS products NEUT was
# built against, separate from the calling (e.g. a grid job's e17 uboonecode)
# environment, and with NEUT's own environment (NEUT_ROOT, NEUT_CRSPATH,
# NEUT_CARDS). Arguments after NEUT_DIR go to the program; it runs in the
# current directory.
#
# Usage:
#   extgen_neut_run.sh NEUT_DIR [neut_extgen arguments ...]
#   extgen_neut_run.sh --stock NEUT_DIR CARD OUT.root   stock NEUT (neutroot2), validation
#   extgen_neut_run.sh --check NEUT_DIR                 environment and libraries only
#
# The products are those of the tarball's BUILD_INFO ("ups setup:",
# "ups products:"). The environment starts empty (env -i) apart from HOME,
# USER, TMPDIR, RANFILE and a minimal PATH, so that no e17 library (ROOT 6.12,
# its gcc runtime) can be loaded into the e26 programs.
#
# Exit code: the program's (neut_extgen: 0 ok, 2 bad input, 4 NEUT failure),
# 5 if the environment could not be set up or a library is missing.
#
# For tests without UPS (e.g. a local build): EXTGEN_NEUT_ENV=FILE sources
# FILE instead of the UPS setup (it must set up ROOT and the gcc 12 runtime).

set -uo pipefail

die() { echo "extgen_neut_run.sh: ERROR: $*" >&2; exit 5; }

CHECK=0 STOCK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
if [ "${1:-}" = "--stock" ]; then STOCK=1; shift; fi
[ $# -ge 1 ] || die "usage: extgen_neut_run.sh [--check|--stock] NEUT_DIR [arguments ...]"
NEUT_DIR=$(realpath "$1"); shift
EXE=$NEUT_DIR/bin/neut_extgen
[ "$STOCK" -eq 0 ] || EXE=$NEUT_DIR/neut/bin/neutroot2
[ -x "$EXE" ] || die "$EXE not found"
[ -f "$NEUT_DIR/BUILD_INFO" ] || die "$NEUT_DIR/BUILD_INFO not found"
UPS_SETUP=$(awk '/^ups setup:/ {sub(/^ups setup: */, ""); print}' "$NEUT_DIR/BUILD_INFO")
BUILD_PRODUCTS=$(awk '/^ups products:/ {sub(/^ups products: */, ""); print}' "$NEUT_DIR/BUILD_INFO")
if [ -z "${EXTGEN_NEUT_ENV:-}" ]; then
  [ -n "$UPS_SETUP" ] && [ -n "$BUILD_PRODUCTS" ] || die "no 'ups setup:'/'ups products:' lines in $NEUT_DIR/BUILD_INFO"
fi

# The inner script: set up, check libraries, run. Its own errors exit with 5.
INNER='
  if [ -n "${EXTGEN_NEUT_ENV:-}" ]; then
    source "$EXTGEN_NEUT_ENV" > /dev/null 2>&1 || { echo "cannot source $EXTGEN_NEUT_ENV" >&2; exit 5; }
  else
    # UPS setups can return non-zero without anything being wrong: judge by the result
    _ne_log=$(mktemp "${TMPDIR:-/tmp}/extgen_neut_setup.XXXXXX")
    source "$UPS_SETUP" > "$_ne_log" 2>&1 || true
    if ! type setup > /dev/null 2>&1; then
      echo "sourcing $UPS_SETUP did not define setup:" >&2; cat "$_ne_log" >&2; exit 5
    fi
    IFS=";" read -ra _ne_prods <<< "$NEUT_UPS_PRODUCTS"
    for _ne_prod in "${_ne_prods[@]}"; do
      echo "setup $_ne_prod" >> "$_ne_log"
      setup $_ne_prod >> "$_ne_log" 2>&1 || echo "(setup returned $?)" >> "$_ne_log"
    done
    if [ -z "${ROOTSYS:-}" ] || ! command -v root-config > /dev/null; then
      echo "UPS setup of \"$NEUT_UPS_PRODUCTS\" incomplete (ROOTSYS=${ROOTSYS:-}):" >&2
      cat "$_ne_log" >&2
      exit 5
    fi
    rm -f "$_ne_log"
  fi
  export NEUT_ROOT=$NEUT_DIR/neut
  export NEUT_CRSPATH=$NEUT_ROOT/share/neut/crsdat
  export NEUT_CARDS=$NEUT_ROOT/share/neut/Cards
  export PATH=$NEUT_ROOT/bin:$PATH
  export LD_LIBRARY_PATH=$NEUT_ROOT/lib:$NEUT_ROOT/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
  missing=$(ldd "$EXE" | grep "not found")
  [ -z "$missing" ] || { echo "unresolved libraries: $missing" >&2; exit 5; }
  if [ "$CHECK" = 1 ]; then
    echo "neut_extgen environment ok: ROOT $(root-config --version 2>/dev/null || echo ?)"
    exit 0
  fi
  exec "$EXE" "$@"
'
# The product list goes in as NEUT_UPS_PRODUCTS, never PRODUCTS: that is UPS's
# own variable (its product databases), which the setup script reads.
env -i HOME="${HOME:-/tmp}" USER="${USER:-nobody}" LOGNAME="${LOGNAME:-${USER:-nobody}}" \
    HOSTNAME="${HOSTNAME:-$(hostname)}" SHELL=/bin/bash TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin \
    NEUT_DIR="$NEUT_DIR" EXE="$EXE" CHECK="$CHECK" UPS_SETUP="$UPS_SETUP" NEUT_UPS_PRODUCTS="$BUILD_PRODUCTS" \
    ${RANFILE:+RANFILE="$RANFILE"} \
    ${EXTGEN_NEUT_ENV:+EXTGEN_NEUT_ENV="$EXTGEN_NEUT_ENV"} \
    bash -c "$INNER" neut_extgen "$@"
