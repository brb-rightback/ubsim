#!/bin/bash
#
# Build GiBUU for ExtGen grid jobs from a GiBUU git repository.
#
# The source is the MicroBooNE GiBUU repository (official release on `main`,
# MicroBooNE patches such as request mode committed on `v08_00_00_br`); no
# patches are applied here, so the binary corresponds exactly to one commit.
# By default that commit is exported with `git archive`, so uncommitted
# changes and build products never mix with the repository.
#
# Usage (in an SL7 environment, see below):
#   ./build_gibuu.sh [build_dir]
#
# Environment variables:
#   GIBUU_REPO          GiBUU repository (default: $MRB_TOP/GiBUU)
#   GIBUU_REF           commit/branch/tag to build (default: HEAD of GIBUU_REPO)
#   GIBUU_USE_WORKTREE  1 = build the working tree as it is, including
#                       uncommitted changes (for development only; recorded
#                       as "worktree" in BUILD_INFO)
#   GIBUU_BUUINPUT_TARBALL  local buuinput2025.tar.gz to use instead of
#                       downloading it from hepforge
#   WITH_ROOT           1 = also build RootTuple and ROOT output (not needed
#                       for grid jobs, which use NuHepMC output)
#   NJOBS               parallel make jobs (default 4)
#   GIBUU_GCC           UPS gcc version (default v12_1_0); the build fails if
#                       gfortran is not this version after the setup
#   SKIP_UPS_SETUP      1 = use the current environment as it is (the gfortran
#                       version is still checked against GIBUU_GCC)
#
# Run it from a fresh login shell, not one where uboonecode/mrbsetenv is set
# up: that environment already has gcc v7_3_0 (e17) set up.
#
# Default: ROOT-free build with gcc v12_1_0 (the compiler of the current
# production binary). NuHepMC output (EventFormat=7) does not need ROOT, and a
# ROOT-free binary does not clash with the uboonecode (e17) environment on the
# worker node. The gfortran runtime libraries are copied to build_dir/lib so
# they can be shipped with the binary.
#
# Output layout in build_dir (same as the old new_hepmc_grid_prod build):
#   release2025/ (+ release -> release2025)   source copy and objects/GiBUU.x
#   buuinput2025/ (+ buuinput -> buuinput2025) GiBUU input data
#   lib/                                       gfortran runtime
#   version.txt                                GiBUU release version
#   BUILD_INFO                                 commit, compiler, checksums
#
# To run on the grid the binary must be built in an SL7 environment, e.g. on a
# uboone gpvm:
#   apptainer shell -B /cvmfs,/exp,/pnfs /cvmfs/singularity.opensciencegrid.org/fermilab/fnal-dev-sl7:latest

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "Run this script as ./build_gibuu.sh (do not source it)." >&2
  return 1
fi

BUILD_DIR=$(realpath -m "${1:-$PWD/gibuu_build}")
REPO=${GIBUU_REPO:-${MRB_TOP:+$MRB_TOP/GiBUU}}
REF=${GIBUU_REF:-HEAD}
GCC_VERSION=${GIBUU_GCC:-v12_1_0}

[ -n "$REPO" ] || { echo "ERROR: set GIBUU_REPO (or MRB_TOP) to the GiBUU repository." \
  "It must be exported (export GIBUU_REPO=...) or given on the command line" \
  "(GIBUU_REPO=... ./build_gibuu.sh): a plain shell variable is not passed to the script." >&2; exit 1; }
REPO=$(realpath "$REPO")
git -C "$REPO" rev-parse --git-dir > /dev/null 2>&1 || { echo "ERROR: $REPO is not a git repository" >&2; exit 1; }
case "$BUILD_DIR/" in
  "$REPO"/*) echo "ERROR: build_dir must be outside the GiBUU repository" >&2; exit 1 ;;
esac

# UPS environment before set -e: UPS setups can return non-zero without
# anything being wrong.
if [ "${SKIP_UPS_SETUP:-0}" != "1" ]; then
  if ! type setup > /dev/null 2>&1; then
    source /cvmfs/uboone.opensciencegrid.org/products/setup_uboone_mcc9.sh
  fi
  setup gcc $GCC_VERSION || echo "WARNING: 'setup gcc $GCC_VERSION' failed" >&2
  setup git v2_45_1 || echo "WARNING: 'setup git v2_45_1' failed" >&2
  if [ "${WITH_ROOT:-0}" = "1" ]; then
    setup root v6_28_12 -q e26:p3915:prof
    setup cmake v3_27_4
  fi
fi
for t in gfortran make wget tar sha1sum git perl; do
  command -v "$t" > /dev/null || { echo "ERROR: $t not found" >&2; exit 1; }
done
# The compiler must be the requested one: a different gfortran changes the
# binary and its runtime library (e.g. gcc 7 -> libgfortran.so.4, gcc 12 ->
# libgfortran.so.5).
want=$(echo "${GCC_VERSION#v}" | tr _ .)
have=$(gfortran -dumpfullversion 2>/dev/null || gfortran -dumpversion)
if [ "$have" != "$want" ]; then
  echo "ERROR: gfortran is $have ($(command -v gfortran)), expected $want (GIBUU_GCC=$GCC_VERSION)." >&2
  echo "       Run from a fresh shell without uboonecode/mrbsetenv set up." >&2
  exit 1
fi
echo "Using $(gfortran --version | head -1)"
set -e

URL="https://gibuu.hepforge.org/downloads?f="
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# --- source
if [ "${GIBUU_USE_WORKTREE:-0}" = "1" ]; then
  COMMIT="worktree of $(git -C "$REPO" rev-parse HEAD) ($(git -C "$REPO" status --porcelain | wc -l) uncommitted changes)"
else
  COMMIT=$(git -C "$REPO" rev-parse --verify "$REF^{commit}")
fi
BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
echo "GiBUU source: $REPO ($COMMIT)"

rm -rf release2025 release
mkdir release2025
if [ "${GIBUU_USE_WORKTREE:-0}" = "1" ]; then
  (cd "$REPO" && tar --exclude=.git -cf - .) | tar -xf - -C release2025
else
  git -C "$REPO" archive --format=tar "$COMMIT" | tar -xf - -C release2025
fi
ln -sfn release2025 release
# Empty directories of the official release that git does not track.
mkdir -p release2025/objects/LIB/lib release2025/code/collisions/twoBodyReactions/testRun/XS/run
cp release2025/version.txt version.txt
echo "GiBUU version: $(cat version.txt)"

# --- input data (not in the repository)
wget -q "${URL}version.txt" -O hepforge_version.txt || true
wget -q "${URL}sha1sum.txt" -O sha1sum.txt || true
if [ -s hepforge_version.txt ] && ! cmp -s hepforge_version.txt version.txt; then
  echo "WARNING: hepforge now serves '$(cat hepforge_version.txt)', but the source is" \
       "'$(cat version.txt)'. Check that buuinput2025.tar.gz matches the source." >&2
fi
if [ -n "$GIBUU_BUUINPUT_TARBALL" ]; then
  cp "$GIBUU_BUUINPUT_TARBALL" buuinput2025.tar.gz
elif [ ! -f buuinput2025.tar.gz ]; then
  wget -q --content-disposition "${URL}buuinput2025.tar.gz" -O buuinput2025.tar.gz
fi
if [ -s sha1sum.txt ]; then
  grep -E " buuinput2025\.tar\.gz$" sha1sum.txt | sha1sum -c -
else
  echo "WARNING: could not get sha1sum.txt from hepforge; buuinput2025.tar.gz not verified" >&2
fi
rm -rf buuinput2025 buuinput
tar -xzf buuinput2025.tar.gz
ln -sfn buuinput2025 buuinput

# --- build
if [ "${WITH_ROOT:-0}" = "1" ]; then
  [ -f libraries2025_RootTuple.tar.gz ] || \
    wget -q --content-disposition "${URL}libraries2025_RootTuple.tar.gz" -O libraries2025_RootTuple.tar.gz
  rm -rf libraries rt_build
  tar -xzf libraries2025_RootTuple.tar.gz
  sed -i 's/-std=c++11/-std=c++17/g' libraries/RootTuple/RootTuple-master/src/CMakeLists.txt
  mkdir -p rt_build && (cd rt_build && cmake -DCMAKE_INSTALL_PREFIX=./ ../libraries/RootTuple/RootTuple-master/ && make && make install)
  cp rt_build/lib/libRootTuple.a release/objects/LIB/lib/libRootTuple.100.a
  (cd release && make buildRootTuple_POS && make withROOT=1)
else
  (cd release && make -j"${NJOBS:-4}")
fi
[ -x release/objects/GiBUU.x ] || { echo "ERROR: release/objects/GiBUU.x was not built" >&2; exit 1; }

# Ship the gfortran runtime with the binary (the grid node may not have this
# gcc's). Take the library names from the binary itself, so this works for any
# gcc version.
rm -rf lib && mkdir -p lib
for l in $(ldd release/objects/GiBUU.x | awk '$1 ~ /^lib(gfortran|quadmath)\.so/ {print $1}'); do
  src=$(gfortran -print-file-name=$l)
  [ -f "$src" ] || { echo "ERROR: runtime library $l not found for $(command -v gfortran)" >&2; exit 1; }
  cp -L "$src" lib/
done
if LD_LIBRARY_PATH=lib ldd release/objects/GiBUU.x | grep -q "not found"; then
  echo "ERROR: unresolved libraries in GiBUU.x even with lib/:" >&2
  LD_LIBRARY_PATH=lib ldd release/objects/GiBUU.x | grep "not found" >&2
  exit 1
fi

{
  echo "GiBUU version:  $(cat version.txt)"
  echo "repository:     $REPO"
  echo "branch:         $BRANCH"
  echo "commit:         $COMMIT"
  echo "compiler:       $(gfortran --version | head -1)"
  echo "runtime libs:   $(ls lib | tr '\n' ' ')"
  echo "with ROOT:      ${WITH_ROOT:-0}"
  echo "buuinput sha1:  $(sha1sum buuinput2025.tar.gz | cut -d' ' -f1)"
  echo "GiBUU.x md5:    $(md5sum release/objects/GiBUU.x | cut -d' ' -f1)"
  echo "built:          $(date -u) on $(hostname)"
} > BUILD_INFO
cat BUILD_INFO

echo "Built $BUILD_DIR/release/objects/GiBUU.x"
LD_LIBRARY_PATH=$BUILD_DIR/lib ldd release/objects/GiBUU.x
