#!/bin/bash
#
# Writes the NuWro card of an ExtGen NuWro group (one target nucleus, one
# neutrino, one current) to stdout, for NuWro's request-mode program
# nuwro_extgen (NuWro branch v08_00_00_br). Every ExtGen NuWro run (scans for
# the spline and Max tables, serving in grid jobs, validation) takes its card
# from here, so they all share one set of physics settings.
#
# Usage:
#   extgen_nuwro_card.sh --target PDG --nu PDG --current CC|NC
#
# Physics settings: those of the NuWro 25.11.1 MicroBooNE BNB card
# (new_hepmc_grid_prod/prod_nuwro/params/nuwro_BNB_numuCC_uboone.txt, itself
# BuildEventGenerators' NuWroCard_CC_Ar_numu.txt), except
#   * beam: one neutrino along +z; nuwro_extgen sets the energy per request;
#   * target: the group's nucleus. Ar40 keeps the card's settings
#     (@target/Ar.txt: local Fermi gas, E_b 34 MeV, kF 220 MeV). Other nuclei:
#     local Fermi gas with NuWro's library values (binding energy from the
#     isotope table, kF from the density profile: nucleus_kf = 0, as NuWro's
#     own detector mode does);
#   * QEL spectral function (sf_method = 1, as the card) for C12, O16, Ar40 and
#     Fe56, the only nuclei NuWro has it for; local Fermi gas QEL
#     (sf_method = 0) for every other nucleus and the free nucleons
#     (nuwro_extgen refuses sf_method > 0 elsewhere: sfevent would give weight
#     0 without a warning);
#   * channels: all of the group's current (CC: QEL, RES, DIS, COH, MEC, HYP;
#     NC: QEL, RES, DIS, COH, MEC); neutrino-electron scattering off. HYP is
#     on for neutrinos too (zero cross section: never generated);
#   * spp_precision per current (card: 500): the number of sampled points per
#     bin of NuWro's RES-DIS boundary tables, built at start-up; nuwro_extgen
#     builds them with one fixed seed in every process, so their noise is a
#     fixed offset of the RES cross sections. CC: 2000, converged (Ar40 numu
#     CC RES at 8000 / 2000 = 1.000 +- 0.001, 0.4-4 GeV). NC: 8000; at 2000
#     Ar40 numu NC RES was 2-4% high, and 8000, 16000 and 32000 agree within
#     0.1-0.4% (0.6-3 GeV; nuwroval/spp_test, 2026-10-31). Start-up per group
#     on the grid: NC ~3 min at 2000, ~7.5 min at 8000;
#   * no NuWro test or real events (nuwro_extgen makes the events);
#   * MEC model per current: CC mec_kind = 6 (2020 Valencia, as the card); NC
#     mec_kind = 1 (TEM). NuWro implements NC MEC only for TEM (nuwro.cc,
#     case 9: "only TEM for NC"); with any other mec_kind the NC MEC channel
#     has weight 0, so the card's NC MEC (dyn_mec_nc = 1) would give no events.
#     TEM reads only mec_ratio_pp, mec_central_motion,
#     mec_back_to_back_smearing and mec_pb_trials, set below for both currents.
# random_seed is set on nuwro_extgen's command line (-p random_seed=N).

set -euo pipefail

die() { echo "extgen_nuwro_card.sh: ERROR: $*" >&2; exit 1; }

TGT= NU= CUR=
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TGT=$2; shift 2 ;;
    --nu) NU=$2; shift 2 ;;
    --current) CUR=$2; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
for v in TGT NU CUR; do
  [ -n "${!v}" ] || die "missing --$(echo $v | tr A-Z a-z)"
done
[[ "$TGT" =~ ^10[0-9]{8}$ ]] || die "target $TGT is not a nucleus PDG code"
Z=$(( (TGT / 10000) % 1000 ))
A=$(( (TGT / 10) % 1000 ))
N=$(( A - Z ))
[ "$A" -ge 1 ] && [ "$N" -ge 0 ] || die "bad target $TGT (Z=$Z A=$A)"
case "$NU" in 12|-12|14|-14) ;; *) die "neutrino $NU not supported (12, -12, 14, -14)" ;; esac
case "$CUR" in
  CC) C=1; NCF=0; MECKIND=6; MECNAME="2020 Valencia"; SPP=2000 ;;
  NC) C=0; NCF=1; MECKIND=1; MECNAME="TEM: NuWro's only NC MEC model"; SPP=8000 ;;
  *) die "current must be CC or NC" ;;
esac

case "$Z:$N" in
  6:6|8:8|18:22|26:30) SF=1 ;;
  *) SF=0 ;;
esac

cat <<EOF
# ExtGen NuWro card: target $TGT (Z=$Z N=$N), nu $NU, $CUR
# (extgen_nuwro_card.sh; physics of the NuWro 25.11.1 MicroBooNE BNB card)

number_of_test_events = 0
number_of_events      = 0
user_events           = 0
beam_test_only        = 0
kaskada_redo          = 0

################################################################################
# Beam: one neutrino along +z (nuwro_extgen sets the energy of each request)
beam_type      = 0
beam_energy    = 1000
beam_particle  = $NU
beam_direction = 0 0 1
beam_placement = 0

################################################################################
# Target
target_type    = 0
nucleus_p      = $Z
nucleus_n      = $N
nucleus_target = 2      // local Fermi gas
density_model  = 1
pauli_blocking = 1
EOF
if [ "$Z:$N" = "18:22" ]; then
  cat <<EOF
nucleus_E_b    = 34     // as @target/Ar.txt of the card
nucleus_kf     = 220
EOF
else
  cat <<EOF
nucleus_E_b    = 0      // library values (isotope table, density profile)
nucleus_kf     = 0
EOF
fi
cat <<EOF

################################################################################
# Channels: the $CUR channels only
dyn_qel_cc = $C
dyn_res_cc = $C
dyn_dis_cc = $C
dyn_coh_cc = $C
dyn_mec_cc = $C
dyn_hyp_cc = $C
dyn_qel_nc = $NCF
dyn_res_nc = $NCF
dyn_dis_nc = $NCF
dyn_coh_nc = $NCF
dyn_mec_nc = $NCF
dyn_lep    = 0
dyn_qel_el = 0
dyn_res_el = 0

################################################################################
# QEL
qel_vector_ff_set = 2      // BBBA05
qel_axial_ff_set  = 8      // MINERvA axial FF, Nature 614, 48 (2023)
qel_strange       = 1
qel_strangeEM     = 0
delta_s           = 0
qel_cc_axial_mass = 1030
qel_nc_axial_mass = 1030
qel_s_axial_mass  = 1030
flux_correction   = 0
cc_smoothing      = 0
qel_rpa           = 1

# Spectral function (C12, O16, Ar40, Fe56 only; local Fermi gas elsewhere)
sf_method                 = $SF
sf_transparency_table_idx = 1
sf_transparency_scale     = 1
sf_recoil                 = 1
sf_Coulomb                = 1
sf_src                    = 1
sf_pb                     = 1

################################################################################
# RES
res_kind               = 2   // hybrid model
res_hybrid_sampling    = 4
delta_FF_set           = 1
pion_axial_mass        = 0.94
pion_C5A               = 1.19
delta_angular          = 2
spp_precision          = $SPP   // card: 500; per current, see the header
bkgrscaling            = 0.0
res_dis_cut            = 1900
res_dis_blending_start = 1600
res_dis_blending_end   = 1900

################################################################################
# COH
coh_kind            = 2      // Berger-Sehgal
coh_mass_correction = 1

################################################################################
# MEC
mec_kind                  = $MECKIND    // $MECNAME
mec_ratio_pp              = 0.85
mec_central_motion        = 0
mec_back_to_back_smearing = 0
MEC_pauli_blocking        = 1
mec_pb_trials             = 30
MEC_cm_direction          = 0
mec_scaling               = 0
MEC_cm_direction_pp       = 0.77
MEC_cm_strength_pp        = 4
MEC_cm_direction_np       = 0.7
MEC_cm_strength_np        = 3
MEC_cm_direction_pn       = 0.8
MEC_cm_strength_pn        = 4

################################################################################
# HYP
hyp_lambda           = 1
hyp_sigma_zero       = 1
hyp_sigma_minus      = 1
hyp_axial_mass       = 1030
hyp_effmass          = 1
hyp_Lambda_Eb        = 27
hyp_Sigma_Eb         = -70
hyp_g2_Re_part       = 0
hyp_g2_Im_part       = 0
hyp_su3_sym_breaking = 0

################################################################################
# FSI
FSI_on               = 1
kaskada_w            = 7
U_switch             = 1
nucleus_model        = 1
kaskada_writeall     = 0
tau                  = 8.0
step                 = 0.2
kaskada_NN_mfp_scale = 0.76
kaskada_NN_xsec      = 2
kaskada_NN_inel      = 2
kaskada_NN_angle     = 3
kaskada_NN_corr      = 1
kaskada_piN_xsec     = 1
first_step           = 1
formation_zone       = fz-new
EOF
