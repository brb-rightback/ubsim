#!/bin/bash
#
# Build NuWro's request-mode program (bin/nuwro_extgen) for ExtGen grid jobs
# from a NuWro git repository.
#
# The source is the MicroBooNE NuWro repository: the official release
# (tag NuWro_25_11_1) plus the MicroBooNE changes on branch `v08_00_00_br`
# (request mode, src/extgen/nuwro_extgen.cc). No patches are applied here, so
# the binary corresponds exactly to one commit: by default that commit is
# exported with `git archive`, so uncommitted changes and build products never
# mix with the repository.
#
# Usage (in an SL7 environment, see below):
#   ./build_nuwro.sh [build_dir]
#
# Environment variables:
#   NUWRO_REPO          NuWro repository (default: $MRB_TOP/nuwro)
#   NUWRO_REF           commit/branch/tag to build (default: HEAD of NUWRO_REPO)
#   NUWRO_USE_WORKTREE  1 = build the working tree as it is, including
#                       uncommitted changes (for development only; recorded
#                       as "worktree" in BUILD_INFO)
#   NUWRO_UPS_PRODUCTS  UPS products to build against, ';'-separated (default:
#                       "root v6_28_12 -q e26:p3915:prof;pythia v6_4_28x -q e26:prof").
#                       Recorded in BUILD_INFO: the grid jobs set up exactly
#                       these (extgen_nuwro_run.sh) to run the binary.
#   NUWRO_UPS_SETUP     UPS setup script (default:
#                       /cvmfs/uboone.opensciencegrid.org/products/setup_uboone_mcc9.sh)
#   NJOBS               parallel make jobs (default 4)
#
# Run it from a fresh login shell, not one where uboonecode/mrbsetenv is set
# up: that environment has the e17 ROOT and gcc set up.
#
# NuWro needs ROOT (its event class) and Pythia6 (DIS hadronization, through
# ROOT's TPythia6, which ROOT 6.28 still contains) at run time, so unlike
# GiBUU it is not self-contained: grid jobs run it in a clean subshell with
# the e26 products above (extgen_nuwro_run.sh), separate from the job's e17
# environment.
#
# Output layout in build_dir:
#   src/ ...                 source copy and objects
#   bin/nuwro_extgen         the program (+ bin/event1Dict_rdict.pcm)
#   data/                    NuWro's input data (from the source)
#   BUILD_INFO               commit, products, checksums
#
# To run on the grid the binary must be built in an SL7 environment, e.g. on a
# uboone gpvm:
#   apptainer shell -B /cvmfs,/exp,/pnfs /cvmfs/singularity.opensciencegrid.org/fermilab/fnal-dev-sl7:latest

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "Run this script as ./build_nuwro.sh (do not source it)." >&2
  return 1
fi

BUILD_DIR=$(realpath -m "${1:-$PWD/nuwro_build}")
REPO=${NUWRO_REPO:-${MRB_TOP:+$MRB_TOP/nuwro}}
REF=${NUWRO_REF:-HEAD}
PRODUCTS_LIST=${NUWRO_UPS_PRODUCTS:-"root v6_28_12 -q e26:p3915:prof;pythia v6_4_28x -q e26:prof"}
UPS_SETUP=${NUWRO_UPS_SETUP:-/cvmfs/uboone.opensciencegrid.org/products/setup_uboone_mcc9.sh}

[ -n "$REPO" ] || { echo "ERROR: set NUWRO_REPO (or MRB_TOP) to the NuWro repository." \
  "It must be exported (export NUWRO_REPO=...) or given on the command line" \
  "(NUWRO_REPO=... ./build_nuwro.sh): a plain shell variable is not passed to the script." >&2; exit 1; }
REPO=$(realpath "$REPO")
case "$BUILD_DIR/" in
  "$REPO"/*) echo "ERROR: build_dir must be outside the NuWro repository" >&2; exit 1 ;;
esac

# UPS environment before set -e: UPS setups can return non-zero without
# anything being wrong.
if [ -n "${ROOTSYS:-}" ] || [ -n "${UBOONECODE_DIR:-}" ]; then
  echo "ERROR: ROOT or uboonecode is already set up (ROOTSYS=${ROOTSYS:-}); run from a fresh shell." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$UPS_SETUP" > /dev/null 2>&1 || { echo "ERROR: cannot source $UPS_SETUP" >&2; exit 1; }
IFS=';' read -ra PRODS <<< "$PRODUCTS_LIST"
for p in "${PRODS[@]}"; do
  # shellcheck disable=SC2086
  setup $p || { echo "ERROR: 'setup $p' failed" >&2; exit 1; }
done
setup git v2_45_1 || echo "WARNING: 'setup git v2_45_1' failed" >&2
for t in g++ gfortran make git root-config; do
  command -v "$t" > /dev/null || { echo "ERROR: $t not found" >&2; exit 1; }
done
[ -n "${PYTHIA_FQ_DIR:-}" ] || { echo "ERROR: Pythia6 (PYTHIA_FQ_DIR) not set up" >&2; exit 1; }
# The repository check needs the UPS git: the SL7 system git (1.8.3) has no
# 'git -C', so it fails on any directory.
if ! gerr=$(git -C "$REPO" rev-parse --git-dir 2>&1); then
  echo "ERROR: $REPO is not a git repository ($(command -v git): $gerr)" >&2
  exit 1
fi
echo "Using ROOT $(root-config --version), $(g++ --version | head -1), Pythia6 in $PYTHIA_FQ_DIR, $(git --version)"
set -euo pipefail

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# --- source
if [ "${NUWRO_USE_WORKTREE:-0}" = "1" ]; then
  COMMIT="worktree of $(git -C "$REPO" rev-parse HEAD) ($(git -C "$REPO" status --porcelain | wc -l) uncommitted changes)"
  DESCRIBE="$(git -C "$REPO" describe --tags --always)-worktree"
else
  COMMIT=$(git -C "$REPO" rev-parse --verify "$REF^{commit}")
  DESCRIBE=$(git -C "$REPO" describe --tags --always "$COMMIT")
fi
BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
echo "NuWro source: $REPO ($COMMIT, $DESCRIBE)"

rm -rf src data bin Makefile
if [ "${NUWRO_USE_WORKTREE:-0}" = "1" ]; then
  (cd "$REPO" && tar --exclude=.git --exclude='*.o' --exclude='*.d' --exclude=bin -cf - .) | tar -xf -
else
  git -C "$REPO" archive --format=tar "$COMMIT" | tar -xf -
fi
[ -f src/extgen/nuwro_extgen.cc ] || { echo "ERROR: $COMMIT has no request mode (src/extgen/nuwro_extgen.cc); use branch v08_00_00_br" >&2; exit 1; }
mkdir -p bin

# --- build (the Makefile takes VERSION from git describe, which needs .git)
export PYTHIA6=$PYTHIA_FQ_DIR/lib
export LIBRARY_PATH=${LIBRARY_PATH:+$LIBRARY_PATH:}$PYTHIA6
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$PYTHIA6
make -j"${NJOBS:-4}" VERSION="$DESCRIBE" bin/nuwro_extgen
[ -x bin/nuwro_extgen ] || { echo "ERROR: bin/nuwro_extgen was not built" >&2; exit 1; }
[ -f bin/event1Dict_rdict.pcm ] || cp src/event1Dict_rdict.pcm bin/
if ldd bin/nuwro_extgen | grep -q "not found"; then
  echo "ERROR: unresolved libraries in nuwro_extgen:" >&2
  ldd bin/nuwro_extgen | grep "not found" >&2
  exit 1
fi

{
  echo "NuWro version:  $DESCRIBE"
  echo "repository:     $REPO"
  echo "branch:         $BRANCH"
  echo "commit:         $COMMIT"
  echo "compiler:       $(g++ --version | head -1)"
  echo "ROOT:           $(root-config --version)"
  echo "ups setup:      $UPS_SETUP"
  echo "ups products:   $PRODUCTS_LIST"
  echo "data sha1:      $(find data -type f -print0 | sort -z | xargs -0 sha1sum | sha1sum | cut -d' ' -f1)"
  echo "nuwro_extgen md5: $(md5sum bin/nuwro_extgen | cut -d' ' -f1)"
  echo "built:          $(date -u) on $(hostname)"
} > BUILD_INFO
cat BUILD_INFO

echo "Built $BUILD_DIR/bin/nuwro_extgen"
