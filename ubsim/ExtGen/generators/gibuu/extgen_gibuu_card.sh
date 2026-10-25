#!/bin/bash
#
# Writes the GiBUU job card of an ExtGen GiBUU run in request mode (GiBUU
# branch v08_00_00_br, module nuRequests) to stdout. Every ExtGen GiBUU run
# (scans for the spline and Max tables, serving in grid jobs, validation)
# takes its card from here, so they all share one set of physics settings.
#
# Usage:
#   extgen_gibuu_card.sh --mode serve|scan --target PDG --nu PDG --current CC|NC
#                        --requests FILE --buuinput DIR --seed N
#                        [--ensembles N] [--runs N] [--trials N]
#                        [--timesteps N] [--stock-enu E]
#
#   --mode serve   one event per request (RequestMode 1, equal weights,
#                  NuHepMC output, 200 time steps of FSI)
#   --mode scan    --trials trials per request, no events (RequestMode 2,
#                  no FSI: inclusive cross sections do not need it)
#   --stock-enu E  validation only (V3): stock GiBUU at fixed energy E
#                  (nuXsectionMode 6, nl_SigmaMC), equal weights against the
#                  Max of the first line of --requests, no request mode.
#
# Physics settings: those of the 2026 run-4c GiBUU production card
# (new_hepmc_grid_prod/prod_gibuu/jobcards/gibuu_BNB_numuCC.job), except
#   * flux: request mode (nuExp=10 only sets histogram ranges);
#   * densitySwitch_Static: 2 (NPA 554 densities, as in that card) for the
#     nuclei GiBUU has them for (C, O16, Al, Ar, Ca40, Fe), 3 (GiBUU's
#     default Woods-Saxon after Lenske, any nucleus) for all others;
#   * built-in analysis output switched off (it does not affect the events).

set -euo pipefail

die() { echo "extgen_gibuu_card.sh: ERROR: $*" >&2; exit 1; }

MODE= TGT= NU= CUR= REQ= BUUINPUT= SEED= ENS= RUNS= TRIALS=0 TSTEPS= STOCK_ENU=
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE=$2; shift 2 ;;
    --target) TGT=$2; shift 2 ;;
    --nu) NU=$2; shift 2 ;;
    --current) CUR=$2; shift 2 ;;
    --requests) REQ=$2; shift 2 ;;
    --buuinput) BUUINPUT=$2; shift 2 ;;
    --seed) SEED=$2; shift 2 ;;
    --ensembles) ENS=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    --trials) TRIALS=$2; shift 2 ;;
    --timesteps) TSTEPS=$2; shift 2 ;;
    --stock-enu) STOCK_ENU=$2; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done

for v in MODE TGT NU CUR REQ BUUINPUT SEED; do
  [ -n "${!v}" ] || die "missing --$(echo $v | tr A-Z a-z)"
done
[[ "$TGT" =~ ^10[0-9]{8}$ ]] || die "target $TGT is not a nucleus PDG code"
[[ "$SEED" =~ ^[0-9]+$ ]] && [ "$SEED" -gt 0 ] || die "seed must be a positive integer"

Z=$(( (TGT / 10000) % 1000 ))
A=$(( (TGT / 10) % 1000 ))
[ "$A" -ge 1 ] && [ "$Z" -le "$A" ] || die "bad target $TGT (Z=$Z A=$A)"

case "$NU" in
  12|-12) FLAVOR=1 ;;
  14|-14) FLAVOR=2 ;;
  *) die "neutrino $NU not supported (12, -12, 14, -14)" ;;
esac
case "$CUR" in
  CC) PROC=2 ;;
  NC) PROC=3 ;;
  *) die "current must be CC or NC" ;;
esac
[ "$NU" -lt 0 ] && PROC=$(( -PROC ))

# NPA 554 densities exist in GiBUU (densityStatic.f90) for these (Z, A) only
case "$Z:$A" in
  6:12|8:16|13:27|18:40|20:40|26:56) DENSITY=2 ;;
  *) DENSITY=3 ;;
esac

case "$MODE" in
  serve)
    REQMODE=1; EQW=2; WRITEPERT=T
    ENS=${ENS:-2000}; TSTEPS=${TSTEPS:-200}
    ;;
  scan)
    REQMODE=2; EQW=0; WRITEPERT=F
    ENS=${ENS:-1000}; TSTEPS=${TSTEPS:-0}
    [ "$TRIALS" -gt 0 ] || die "scan needs --trials"
    ;;
  *) die "mode must be serve or scan" ;;
esac
[ -n "$RUNS" ] || die "missing --runs"
[ -f "$REQ" ] || die "request file $REQ not found"
[ -d "$BUUINPUT" ] || die "buuinput $BUUINPUT not found"

if [ -n "$STOCK_ENU" ]; then
  [ "$MODE" = serve ] || die "--stock-enu needs --mode serve"
  STOCK_MAX=$(awk '!/^#/ && NF>=3 {print $3; exit}' "$REQ")
  [ -n "$STOCK_MAX" ] || die "no Max in $REQ"
  XSMODE=6; NUEXP=0; REQFILE=""
else
  XSMODE=16; NUEXP=10; REQFILE=$(realpath "$REQ")
fi

cat <<EOF
! ExtGen GiBUU card, written by extgen_gibuu_card.sh
!   mode=$MODE target=$TGT (Z=$Z A=$A) nu=$NU current=$CUR seed=$SEED${STOCK_ENU:+ stock_enu=$STOCK_ENU}

&neutrino_induced
      process_ID      = $PROC
      flavor_ID       = $FLAVOR
      nuXsectionMode  = $XSMODE
      nuExp           = $NUEXP
      includeQE       = T
      includeDELTA    = T
      includeRES      = T
      include1pi      = T
      includeDIS      = T
      include2p2hQE   = T
      include2pi      = T
      printAbsorptionXS = F
      equalWeights_Mode = $EQW
      equalWeights_Max  = ${STOCK_MAX:-1.}
/

&target
      Z=$Z
      A=$A
      densitySwitch_Static=$DENSITY
      fermiMomentum_input=0.225
      fermiMotion=.true.
/

&initDensity
      densitySwitch=2
/

&initPauli
      pauliSwitch=2
/

&input
      eventtype=5
      numEnsembles=$ENS
      numTimeSteps=$TSTEPS
      delta_T=0.2
      fullensemble=.true.
      localEnsemble=.true.
      num_runs_SameEnergy=$RUNS
      num_Energies=1
      printParticleVectors=.false.
      freezeRealParticles=.true.
      LRF_equals_CALC_frame=.true.
      path_to_input='$BUUINPUT'
      version = 2025
/

&width_Baryon
      mediumSwitch=.false.
      mediumSwitch_Delta=.false.
      mediumSwitch_coll=.false.
/

&spectralFunction
      nuclwidth=0.001
/

&baryonPotential
      EQS_Type=5
      DeltaPot=1
/

&insertion
      minimumEnergy=0.005
/

&neutrinoAnalysis
      outputEvents=.false.
      include_W_dist=.false.
      DoOutChannels=.false.
      ZeroPion_analysis=.false.
      detailed_diff_output=.false.
      reconstruct_neutrino_energy=.false.
      specificEvent_analysis=.false.
/

&EventOutput
      WritePerturbativeParticles = $WRITEPERT
      EventFormat=7
/

&pythia
      PARP(91)=0.44
/

&initRandom
      SEED=$SEED
/
EOF

if [ -n "$STOCK_ENU" ]; then
  cat <<EOF

&nl_SigmaMC
      enu=$STOCK_ENU
/
EOF
else
  cat <<EOF

&uboone_requests
      RequestFile = '$REQFILE'
      RequestMode = $REQMODE
      ScanTrials  = $TRIALS
/

&nl_neutrino_energyFlux
      Eflux_min = 0.0
      Eflux_max = 8.0
/
EOF
fi
