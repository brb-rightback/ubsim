#!/bin/bash
#
# Writes the NEUT card (TOML) of ExtGen NEUT to stdout. Every ExtGen NEUT run
# (the cross-section tables, serving in grid jobs, validation) takes its card
# from here, so they all share one set of physics settings. The md5 of this
# script is recorded in the cross-section tables and checked by the grid jobs
# (extgen_neut_grid_init.sh).
#
# Usage:
#   extgen_neut_card.sh                       the card of neut_extgen (serve, xsec)
#   extgen_neut_card.sh --stock --nu PDG --target PDG --energy-mev E --events N
#                                             the same physics for stock NEUT
#                                             (neutroot2) at one fixed energy, for
#                                             validation V3 (extgen_neut_v3.sh)
#
# Physics: NEUT 6.2 defaults (src/config/Cards/NEUT.Defaults.toml of the build,
# which NEUT reads for every setting a card does not give; its sha1 is in the
# build's BUILD_INFO), except
#   * QE: the Nieves model (local Fermi gas with RPA, model = "nieves") instead
#     of NEUT's default, the Benhar spectral function ("rome"), which NEUT has
#     for C12, O16 and Fe56 only: on any other nucleus, argon included, NEUT
#     silently uses its old RFG tables instead. With "nieves", NC elastic is
#     NEUT's own choice for that model (RFG tables on argon; the variant
#     "nieves_furmanski_abe" differs for C, O and Fe only and needs spectral
#     function tables that do not exist for M_A = 1.05).
#   * QE axial mass 1.05 GeV (NEUT default 1.21): the value of the Nieves 1p1h
#     tables NEUT ships (data/N1p1h/Tables_std, for 37 nuclei). With any other
#     value NEUT recomputes them at start-up, ~30 min per nucleus and job.
#   * random numbers from NEUT's seed file (rng_seed = "file"): neut_extgen
#     writes it from the job's seed; for stock runs the caller sets RANFILE.
#   * beam and target: placeholders for neut_extgen (it sets the neutrino,
#     energy and nucleus per request through NEUT's interface); real values
#     for --stock.
# 2p2h: NEUT default (Nieves hadron tensors, 3p3h on). FSI: NEUT's default
# cascade, O16 de-excitation gammas (argon has none). Pauli blocking: on, as
# NEUT's default; neut_extgen takes the blocked single-pion events into
# account in the cross sections (see neut_extgen.cc).

set -euo pipefail

die() { echo "extgen_neut_card.sh: ERROR: $*" >&2; exit 1; }

STOCK=0 NU= TGT= EMEV= NEV=
while [ $# -gt 0 ]; do
  case "$1" in
    --stock) STOCK=1; shift ;;
    --nu) NU=$2; shift 2 ;;
    --target) TGT=$2; shift 2 ;;
    --energy-mev) EMEV=$2; shift 2 ;;
    --events) NEV=$2; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done

if [ "$STOCK" -eq 1 ]; then
  for v in NU TGT EMEV NEV; do [ -n "${!v}" ] || die "--stock needs --nu, --target, --energy-mev and --events"; done
  case "$NU" in
    14) SPECIES=numu ;; -14) SPECIES=numubar ;; 12) SPECIES=nue ;; -12) SPECIES=nuebar ;;
    *) die "neutrino $NU not supported (12, -12, 14, -14)" ;;
  esac
  [[ "$TGT" =~ ^10[0-9]{8}$ ]] || die "target $TGT is not a nucleus PDG code"
  Z=$(( (TGT / 10000) % 1000 )); A=$(( (TGT / 10) % 1000 ))
  [ "$A" -gt 1 ] && [ "$Z" -ge 1 ] || die "--stock needs a nucleus with A > 1 (got Z=$Z A=$A)"
  [[ "$NEV" =~ ^[0-9]+$ ]] || die "--events must be a number"
else
  SPECIES=numu EMEV=1000.0 Z=18 A=40 NEV=0
fi

cat <<EOF
# ExtGen NEUT card (extgen_neut_card.sh)$([ "$STOCK" -eq 1 ] && echo ", stock NEUT: nu $NU on $TGT at $EMEV MeV")
# Settings not given here are NEUT's defaults (NEUT.Defaults.toml of the build).

[neut]
rng_seed = "file"            # NEUT's seed file (RANFILE)
verbosity = "very_quiet"
output_format = "neutroot"   # stock runs only (neut_extgen writes its own files)
simulation_mode = "neutrino"
EOF
[ "$STOCK" -eq 0 ] || echo "number_of_events = $NEV"
cat <<EOF

[neut.probe]                 # neut_extgen: set per request
species = "$SPECIES"
direction_type = "z"
energy_spectrum_type = "fixed"
energy_mev = $EMEV

[neut.target]                # neut_extgen: set per request
num_nucleons = $A
num_bound_protons = $Z
num_free_protons = 0

[neut.interaction_model.QE]
model = "nieves"

[neut.interaction_model.QE.axial_form_factors.dipole]
axial_mass = 1.05            # GeV; the M_A of NEUT's Nieves 1p1h tables
EOF
