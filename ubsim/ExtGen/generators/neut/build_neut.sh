#!/bin/bash
#
# Builds NEUT and ExtGen's NEUT driver (bin/neut_extgen, from neut_extgen.cc
# next to this script) for ExtGen grid jobs.
#
# NEUT is built unchanged from one commit of a NEUT git repository (by default
# exported with `git archive`, so uncommitted changes and build products never
# mix with the repository); no patches are applied. neut_extgen only uses
# NEUT's own interface for external drivers (libNEUTGenIFace, neutgen.h).
#
# Usage (in an SL7 environment, see below):
#   ./build_neut.sh [build_dir]
#
# Environment variables:
#   NEUT_REPO          NEUT repository (required), e.g. a clone of
#                      github.com/neut-devel/neut
#   NEUT_REF           commit/branch/tag to build (default: HEAD of NEUT_REPO;
#                      ExtGen uses the LTS/6.2 tag 6.2.3)
#   NEUT_USE_WORKTREE  1 = build the working tree as it is (development only;
#                      recorded as "worktree" in BUILD_INFO)
#   NEUT_UPS_PRODUCTS  UPS products NEUT runs with, ';'-separated (default:
#                      "root v6_28_12 -q e26:p3915:prof"; it brings gcc 12.1).
#                      Recorded in BUILD_INFO: grid jobs set up exactly these
#                      (extgen_neut_run.sh).
#   NEUT_BUILD_PRODUCTS products needed only to build (default: "cmake v3_27_4")
#   NEUT_UPS_SETUP     UPS setup script (default:
#                      /cvmfs/uboone.opensciencegrid.org/products/setup_uboone_mcc9.sh)
#   NJOBS              parallel make jobs (default 4)
#   NEUT_REUSE         1 = keep the NEUT of an earlier run in build_dir (same
#                      commit, checked) and only rebuild neut_extgen, the
#                      library check and BUILD_INFO
#
# Run it from a fresh login shell, not one where uboonecode/mrbsetenv (e17
# ROOT and gcc) or another generator build (CMAKE_PREFIX_PATH) is set up: NEUT's
# CMake would pick up libraries from there. NEUT's configure step downloads its
# own dependencies (toml11, NucDeEx, Eigen, FortModGen, fmt; versions fixed by
# the NEUT commit) from GitHub, so the build machine needs network access.
# NEUT's NuHepMC output is not built (NEUT_NUHEPMC_ENABLED=OFF): ExtGen does
# not use it, and it would add HepMC3 and spdlog to the run-time libraries.
#
# Output layout in build_dir:
#   src/ build/              NEUT source copy and CMake build
#   neut/                    NEUT installation (bin, lib, include, share/neut:
#                            crsdat data, Cards/NEUT.Defaults.toml)
#   bin/neut_extgen          the driver (rpath to neut/lib)
#   BUILD_INFO               commit, products, checksums
#
# To run on the grid it must be built in an SL7 environment, e.g. on a uboone
# gpvm:
#   apptainer shell -B /cvmfs,/exp,/pnfs /cvmfs/singularity.opensciencegrid.org/fermilab/fnal-dev-sl7:latest

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "Run this script as ./build_neut.sh (do not source it)." >&2
  return 1
fi

HERE=$(dirname "$(realpath "$0")")
DRIVER=$HERE/neut_extgen.cc
BUILD_DIR=$(realpath -m "${1:-$PWD/neut_build}")
REPO=${NEUT_REPO:-}
REF=${NEUT_REF:-HEAD}
PRODUCTS_LIST=${NEUT_UPS_PRODUCTS:-"root v6_28_12 -q e26:p3915:prof"}
BUILD_PRODUCTS=${NEUT_BUILD_PRODUCTS:-"cmake v3_27_4"}
UPS_SETUP=${NEUT_UPS_SETUP:-/cvmfs/uboone.opensciencegrid.org/products/setup_uboone_mcc9.sh}

[ -f "$DRIVER" ] || { echo "ERROR: $DRIVER not found (it is installed next to this script)" >&2; exit 1; }
[ -n "$REPO" ] || { echo "ERROR: set NEUT_REPO to the NEUT repository. It must be exported" \
  "(export NEUT_REPO=...) or given on the command line (NEUT_REPO=... ./build_neut.sh)." >&2; exit 1; }
REPO=$(realpath "$REPO")
case "$BUILD_DIR/" in
  "$REPO"/*) echo "ERROR: build_dir must be outside the NEUT repository" >&2; exit 1 ;;
esac

# UPS environment before set -e: UPS setups can return non-zero without
# anything being wrong.
if [ -n "${ROOTSYS:-}" ] || [ -n "${UBOONECODE_DIR:-}" ] || [ -n "${NEUT_ROOT:-}" ]; then
  echo "ERROR: ROOT, uboonecode or NEUT is already set up (ROOTSYS=${ROOTSYS:-} NEUT_ROOT=${NEUT_ROOT:-});" \
       "run from a fresh shell." >&2
  exit 1
fi
unset CMAKE_PREFIX_PATH PKG_CONFIG_PATH
# shellcheck disable=SC1090
source "$UPS_SETUP" > /dev/null 2>&1 || { echo "ERROR: cannot source $UPS_SETUP" >&2; exit 1; }
IFS=';' read -ra PRODS <<< "$PRODUCTS_LIST;$BUILD_PRODUCTS"
for p in "${PRODS[@]}"; do
  [ -n "$p" ] || continue
  # shellcheck disable=SC2086
  setup $p || { echo "ERROR: 'setup $p' failed" >&2; exit 1; }
done
setup git v2_45_1 || echo "WARNING: 'setup git v2_45_1' failed" >&2
for t in g++ gfortran make git cmake root-config; do
  command -v "$t" > /dev/null || { echo "ERROR: $t not found" >&2; exit 1; }
done
if ! gerr=$(git -C "$REPO" rev-parse --git-dir 2>&1); then
  echo "ERROR: $REPO is not a git repository ($(command -v git): $gerr)" >&2
  exit 1
fi
echo "Using ROOT $(root-config --version), $(g++ --version | head -1), $(cmake --version | head -1), $(git --version)"
set -euo pipefail

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# --- source
if [ "${NEUT_USE_WORKTREE:-0}" = "1" ]; then
  COMMIT="worktree of $(git -C "$REPO" rev-parse HEAD) ($(git -C "$REPO" status --porcelain | wc -l) uncommitted changes)"
  DESCRIBE="$(git -C "$REPO" describe --tags --always)-worktree"
else
  COMMIT=$(git -C "$REPO" rev-parse --verify "$REF^{commit}")
  DESCRIBE=$(git -C "$REPO" describe --tags --always "$COMMIT")
fi
echo "NEUT source: $REPO ($COMMIT, $DESCRIBE)"

if [ "${NEUT_REUSE:-0}" = "1" ] && [ -d neut ] && [ -d src ]; then
  # keep the NEUT built here before; only the driver, checks and BUILD_INFO are redone
  if [ -f neut/.extgen_commit ]; then
    [ "$(cat neut/.extgen_commit)" = "$COMMIT" ] \
      || { echo "ERROR: NEUT_REUSE: neut/ was built from $(cat neut/.extgen_commit), not $COMMIT" >&2; exit 1; }
  else
    echo "WARNING: NEUT_REUSE: neut/ has no commit stamp; assuming it is $COMMIT" >&2
    echo "$COMMIT" > neut/.extgen_commit
  fi
  echo "NEUT_REUSE: using the NEUT installation in $BUILD_DIR/neut"
  rm -rf bin
  mkdir -p bin
else
  rm -rf src build neut bin
  mkdir -p src bin
  if [ "${NEUT_USE_WORKTREE:-0}" = "1" ]; then
    (cd "$REPO" && tar --exclude=.git --exclude=build -cf - .) | tar -xf - -C src
  else
    git -C "$REPO" archive --format=tar "$COMMIT" | tar -xf - -C src
  fi
  [ -f src/src/generators/geniface/neutgen.h ] || { echo "ERROR: $COMMIT has no src/generators/geniface/neutgen.h" >&2; exit 1; }

  # --- NEUT
  mkdir -p build
  cmake -S src -B build -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/neut" \
        -DNEUT_DOWNLOAD_DATA=OFF -DNEUT_WERROR_ENABLED=OFF \
        -DNEUT_NUHEPMC_ENABLED=OFF -DNEUT_ROOTIO_ENABLED=ON
  cmake --build build -j"${NJOBS:-4}"
  cmake --install build
  echo "$COMMIT" > neut/.extgen_commit
fi
NEUTD=$BUILD_DIR/neut
[ -f "$NEUTD/include/neutgen.h" ] && ls "$NEUTD"/lib/libNEUTGenIFace.* > /dev/null \
  || { echo "ERROR: the NEUT installation in $NEUTD has no NEUTGenIFace" >&2; exit 1; }
[ -f "$NEUTD/share/neut/Cards/NEUT.Defaults.toml" ] || { echo "ERROR: no share/neut/Cards/NEUT.Defaults.toml" >&2; exit 1; }
[ -d "$NEUTD/share/neut/crsdat" ] || { echo "ERROR: no share/neut/crsdat" >&2; exit 1; }
NEUT_VERSION=$("$NEUTD/bin/neut-config" --version 2>/dev/null || echo "?")

# --- neut_extgen
LIBDIRS=("$NEUTD/lib")
[ -d "$NEUTD/lib64" ] && LIBDIRS+=("$NEUTD/lib64")
# Every library of the installation: NEUT's neut-config --libs is incomplete
# (in 6.2.3 it misses libNEUTModelsQESpecFuncConstants and
# libNEUTModelsContrib_nieves2020[Types], which other NEUT libraries need).
# Shared libraries first, static archives (CERNLIB, ...) last.
NEUTLIBS=()
for f in "$NEUTD"/lib/lib*.so; do b=$(basename "$f" .so); NEUTLIBS+=("-l${b#lib}"); done
for f in "$NEUTD"/lib/lib*.a; do NEUTLIBS+=("$f"); done
g++ -std=c++17 -O2 -Wall -Wextra -DNEUT_EXTGEN_CONVERT \
    -DNEUT_EXTGEN_VERSION="\"NEUT $NEUT_VERSION $DESCRIBE\"" \
    -I"$NEUTD/include" -I"$(root-config --incdir)" "$DRIVER" -o bin/neut_extgen \
    "${LIBDIRS[@]/#/-L}" "${LIBDIRS[@]/#/-Wl,-rpath-link,}" -Wl,--no-as-needed "${NEUTLIBS[@]}" \
    $(root-config --libs) -lgfortran \
    -Wl,-rpath,'$ORIGIN/../neut/lib' -Wl,-rpath,'$ORIGIN/../neut/lib64'
[ -x bin/neut_extgen ] || { echo "ERROR: bin/neut_extgen was not built" >&2; exit 1; }

# --- run-time libraries: only the NEUT installation, ROOT and the compiler
# runtime of the UPS products (no library from another build tree)
export LD_LIBRARY_PATH="$NEUTD/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
bad=0
for f in bin/neut_extgen "$NEUTD/bin/neutroot2" "$NEUTD"/lib/*.so; do
  [ -e "$f" ] || continue
  while read -r lib path; do
    case "$path" in
      "not found") echo "ERROR: $f: $lib not found" >&2; bad=1 ;;
      "$NEUTD"/*|"$BUILD_DIR"/*|/lib*/*|/usr/lib*/*|/cvmfs/*) ;;
      *) echo "ERROR: $f: $lib from $path (outside NEUT, UPS and the system)" >&2; bad=1 ;;
    esac
  # only "name => /path" and "name => not found" lines: the kernel's vdso
  # (SL7: "linux-vdso.so.1 =>  (0x...)") has no file
  done < <(ldd "$f" | awk '/=>/ && ($3 ~ /^\// || $3 == "not") {print $1, ($3 == "not" ? "not found" : $3)}')
done
[ "$bad" -eq 0 ] || exit 1

{
  echo "NEUT version:   $NEUT_VERSION ($DESCRIBE)"
  echo "repository:     $REPO"
  echo "commit:         $COMMIT"
  echo "compiler:       $(g++ --version | head -1)"
  echo "ROOT:           $(root-config --version)"
  echo "ups setup:      $UPS_SETUP"
  echo "ups products:   $PRODUCTS_LIST"
  echo "build products: $BUILD_PRODUCTS"
  echo "data sha1:      $(cd "$NEUTD/share/neut/crsdat" && find . -type f -print0 | sort -z | xargs -0 sha1sum | sha1sum | cut -d' ' -f1)"
  echo "defaults sha1:  $(sha1sum "$NEUTD/share/neut/Cards/NEUT.Defaults.toml" | cut -d' ' -f1)"
  echo "driver source md5: $(md5sum "$DRIVER" | cut -d' ' -f1)"
  echo "neut_extgen md5: $(md5sum bin/neut_extgen | cut -d' ' -f1)"
  echo "built:          $(date -u) on $(hostname)"
} > BUILD_INFO
cat BUILD_INFO

echo "Built $BUILD_DIR/bin/neut_extgen and NEUT in $NEUTD"
