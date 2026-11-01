# ExtGen: external neutrino generators through GENIE's flux and geometry drivers

ExtGen runs neutrino interactions from an external generator (GiBUU; NuWro)
with exactly the flux, geometry, vertex distribution and POT accounting of a
standard MicroBooNE GENIE overlay:

1. **Step A (GENIE).** `GENIEGen` runs with the ExtGen tune, whose cross
   sections are the external generator's total CC and NC cross sections. GENIE
   chooses each interaction's neutrino, target nucleus, current, exact energy,
   vertex, direction and time, and keeps track of POT and `MCFlux`. The event
   record holds only the neutrino and the target.
2. **Step B.** `ExtGenRequestDumper` (`job/extgen_dump_requests.fcl`) writes
   the requests to a text file, one line per `MCTruth`.
3. **Step C.** The external generator, patched with a "request mode", makes
   one unweighted event at exactly each requested energy and current.
4. **Step D.** `ExtGenMerge` rotates each final state onto its neutrino
   direction, places it at the vertex and writes standard
   `MCTruth`/`GTruth`/`MCFlux`, which `SimInfoMixer` overlays on EXT data.

The full design is in `GIBUU_GENIE_INTEGRATION_PLAN.md` in the development
area.

## Contents

| Directory | What it holds |
|---|---|
| `GENIE/` | GENIE plugin library `ubsim_ExtGen_GENIE`: `genie::ubext::ExtGenPXSec` (total cross sections) and `genie::ubext::ExtGenInteractionListGenerator` (one CC and one NC interaction per initial state). GENIE finds them through their ROOT dictionary. |
| `gxml/` | GENIE configuration, installed to `$UBSIM_DIR/gxml`: the tunes `GB25_05a_00_000` (GiBUU) and `NW25_11a_00_000` (NuWro), identical apart from their name, which ties a spline file to one generator (all tune files in `GB25_05a/` and `NW25_11a/`: a `_00_000` tune is "configuration only" to GENIE, which never reads a `GB25_05a_00_000/` subdirectory) plus overriding copies of GENIE's `master_config.xml` and `EventGenerator.xml`. **This directory must only be on `GXMLPATH` for ExtGen jobs, never on `FW_SEARCH_PATH`.** Regenerate the copies with `gxml/make_extgen_gxml.sh` when the GENIE version changes. |
| `Modules/` | art modules: `ExtGenRequestDumper` (step B; writes `requests.txt`, checking each `MCTruth` against its `GTruth`), `ExtGenMerge` (step D), and for the GENIE closure test `ExtGenTruthServer`, `ExtGenClosureCheck` and `ExtGenMixCheck`. Library `ubsim_ExtGen_Modules` (`ExtGenIO`): request and served-event file formats and the generator-to-detector rotation. |
| `tools/` | Offline scripts: `extgen_make_splines.py` (cross section table to GENIE spline XML), `extgen_placeholder_xsec.py` (fake cross sections for tests), `extgen_request_summary.py` (checks a request file and summarises targets, flavours, energies and vertices), `extgen_gibuu_scan_jobs.py` (job list of the GiBUU scan campaign), `extgen_gibuu_tables.py` (merges scans into the cross-section and Max tables), `extgen_gibuu_v3_compare.py` (V3), `extgen_gibuu_v4_summary.py` (V4 over a production; reads NuWro jobs' reports too) and `extgen_v5_compare.py` (V5, truth-level sample comparison after reco2); for NuWro `extgen_nuwro_scan_jobs.py` and `extgen_nuwro_tables.py`. |
| `job/` | fcl files: `extgen_modules.fcl` (module prologs), `extgen_requests_test_bnb.fcl` (step A test), `extgen_dump_requests.fcl` (step B), `extgen_merge.fcl` (step D, also writes the per-event POT `potinevent:SubRunPOT`), `extgen_overlay_SimInfoMixer.fcl` (overlay on EXT, exact POT per mixed event), `extgen_closure_*.fcl` (GENIE closure test); step A of production: `extgen_requests_{bnb_run4c,bnb_run4a,numi_fhc,numi_rhc}.fcl` (GiBUU tune) and `extgen_requests_nuwro_*.fcl` (the same with the NuWro tune, `extgen_genie_nuwro.fcl`). |
| `generators/gibuu/` | `build_gibuu.sh`: builds GiBUU for grid jobs from a commit of the MicroBooNE GiBUU repository (official release on `main`, MicroBooNE patches such as request mode on `v08_00_00_br`); run by hand in SL7. `extgen_gibuu_card.sh`: the GiBUU card of every ExtGen GiBUU run (one set of physics settings). `extgen_gibuu_scan.sh`: one scan (request mode 2) for the tables; `extgen_gibuu_energies.txt`: its energy grid. `make_gibuu_tarball.sh` and `extgen_gibuu_scan_grid.sh`: the grid scan campaign. `extgen_gibuu_convert`: GiBUU request-mode output to `served_events.txt` and `trial_stats.txt` (step C). `extgen_gibuu_serve.sh`: step C for one job's requests. `extgen_gibuu_xsec_check.sh`: in-job cross-section check (V4). `extgen_gibuu_grid_init.sh`: the project.py `<initscript>` of production jobs (steps A–D, leaving `genfile.root.local` for `extgen_overlay_SimInfoMixer.fcl`). |
| `generators/nuwro/` | NuWro route (NuWro branch `v08_00_00_br`, program `nuwro_extgen`): `build_nuwro.sh` (SL7, e26 ROOT/Pythia6), `make_nuwro_tarball.sh`, `extgen_nuwro_run.sh` (runs NuWro in a clean e26 environment), `extgen_nuwro_card.sh`, `extgen_nuwro_scan.sh` + `extgen_nuwro_scan_grid.sh` + `extgen_nuwro_energies.txt` (scan campaign), `extgen_nuwro_serve.sh` (step C), `extgen_nuwro_grid_init.sh` + `extgen_nuwro_grid_continue.sh` (production jobs). See "NuWro route" below. |
| `xml/` | project.py templates for reco1, one per generator and sample: `extgen_{gibuu,nuwro}_{bnb_run4c,bnb_run4a,numi_fhc,numi_rhc}_reco1.xml`. |

Cross section splines for production live in uboonedata, under `genie/gibuu/` (and `genie/nuwro/`).

## Phase-1 test (GENIE side only)

```
extgen_placeholder_xsec.py placeholder_xsec.txt
extgen_make_splines.py placeholder_xsec.txt $PWD/extgen_placeholder_splines.xml --tune GB25_05a_00_000
cat > test.fcl <<EOF
#include "extgen_requests_test_bnb.fcl"
physics.producers.generator.XSecTable: "$PWD/extgen_placeholder_splines.xml"
EOF
lar -c test.fcl -n 20
```

The placeholder cross sections are not physics. They only test that the
plugin loads, the splines are found and GENIE produces requests in
`volCryostat`.

Then write and check the requests (step B):

```
lar -c extgen_dump_requests.fcl -s extgen_requests_test.root
extgen_request_summary.py requests.txt
```

For a human-readable dump of the same events, larsim's `dump_mctruth.fcl`
(DumpMCTruth and DumpGTruth) works unchanged:
`lar -c dump_mctruth.fcl -s extgen_requests_test.root` (writes `DumpMCTruth.log`).

## GENIE closure test (V2)

GENIE plays the external generator: step A runs with the standard MicroBooNE
GENIE tune (full events), `ExtGenTruthServer` writes GENIE's own final states
as a served-event file, and the production merge job rebuilds every
interaction from the request and served files. `ExtGenClosureCheck` then
compares each merged interaction with GENIE's original (particles, momenta,
vertex and time, MCNeutrino codes and kinematics, GTruth, MCFlux,
BeamGateInfo, POT per subrun) and fails the job on any difference.

```
lar -c extgen_closure_stepA_bnb.fcl -n 200
lar -c extgen_closure_serve.fcl -s extgen_closure_stepA.root
lar -c extgen_closure_merge.fcl -s extgen_closure_stepA.root
lar -c extgen_closure_mix.fcl -s <EXT run 4c file>
```

The last job is the production mixer (`extgen_overlay_SimInfoMixer.fcl`)
with the merged closure file as generator file. `ExtGenMixCheck` checks that
the n-th mixed event carries the n-th merged event unchanged (fingerprint of
MCTruth, GTruth, MCFlux and BeamGateInfo) and that the POT the mixer writes for
each EXT subrun is exactly the POT of the events mixed into it, using the
ledger the merge job wrote (`extgen_closure_mix_ledger.txt`).

## GiBUU cross-section and Max tables (scan campaign)

GiBUU in request mode 2 ("scan") makes a fixed number of trials at each
energy and records their weights: the mean is the total cross section, the
largest the scale of the equal-weights Max. Splines, Max tables and the
in-job cross-section check all use this one estimator, the one that serving
uses for its rejection.

1. Build GiBUU from a commit with request mode (`build_gibuu.sh`, SL7) and
   pack it: `make_gibuu_tarball.sh <build_dir> gibuu_scan.tar.gz` (refuses a
   build without request mode).
2. Job list: `extgen_gibuu_scan_jobs.py scan_jobs.txt` (default tiers: 100
   jobs each for Ar40 numu CC/NC, 25 for the other Ar40 flavours and steel
   numu, 4 for the other volCryostat channels, 1 for N14, K39 and the free
   neutron: 884 jobs, 20000 trials per energy per job, ~1 h each).
3. Submit `extgen_gibuu_scan_grid.sh` with jobsub (example in its header);
   each job writes `scan_<index>.tgz` to the output directory.
4. Unpack and merge into a table set named
   `gibuu_<version>_<cardhash>` (cardhash: first 8 hex digits of the md5 of
   `extgen_gibuu_card.sh`):
   `extgen_gibuu_tables.py scan_*/ --xsec STEM_xsec.txt --max STEM_max.txt`
   (fails on scans from different GiBUU builds or card scripts), then
   `extgen_make_splines.py STEM_xsec.txt STEM_xsec.xml --tune GB25_05a_00_000`,
   and put the three files in uboonedata `genie/gibuu/`.

Target densities: `densitySwitch_Static=2` (as in the 2026 production card)
for C12, O16, Al27, Ar40, Ca40, Fe56, which GiBUU has NPA 554 densities for;
3 (GiBUU's default) for all other nuclei.

## NuWro route

The same chain with NuWro (25.11.1 plus request mode: NuWro repository,
branch `v08_00_00_br`, `README_extgen.md` there) as the external generator.
Everything from step A to the mixer is shared; the differences:

* **Program.** `nuwro_extgen`, a separate NuWro executable (stock `nuwro`
  unchanged). One process per group (target, neutrino, current); each request
  at its exact energy: channel k drawn with probability M_k/ΣM, NuWro event
  of channel k, accepted with probability w/M_k (exact; a weight above M_k
  stops it with exit code 3 and the group is retried with twice the Max). It
  writes `served_events.txt` and `trial_stats.txt` itself (no converter).
* **Environment.** NuWro needs ROOT and Pythia6 at run time; it is built
  with e26 (`root v6_28_12 -q e26:p3915:prof`, `pythia v6_4_28x -q e26:prof`,
  recorded in the tarball's `BUILD_INFO`) and always run through
  `extgen_nuwro_run.sh`, which sets up exactly those products from CVMFS in an
  empty environment (`env -i`), apart from the job's e17. Grid jobs check
  that environment at setup (`extgen_nuwro_run.sh --check`).
* **Card.** `extgen_nuwro_card.sh`: the physics of the NuWro MicroBooNE BNB
  card for every group. QEL spectral function for C12, O16, Ar40, Fe56 (the
  only nuclei NuWro has it for; `nuwro_extgen` refuses it elsewhere, where
  NuWro would give weight 0 silently), local Fermi gas for the other nuclei
  and free nucleons; Ar40 keeps the card's E_b and kF, other nuclei NuWro's
  library values.
* **Max per channel.** The Max table has one entry per NuWro channel (`dyn`);
  serving takes margin × the largest weight of the channel around the
  request's energy (default margin 3, floor 0: a channel without weight
  there stays closed).

Build, tables and production:

1. Build in SL7 from a fresh shell: `NUWRO_REPO=<repo> build_nuwro.sh
   <build_dir>` (exports one commit with `git archive`); pack:
   `make_nuwro_tarball.sh <build_dir> nuwro_extgen.tar.gz`.
2. Scan campaign: `extgen_nuwro_scan_jobs.py scan_jobs.txt` (default 268
   jobs, 100000 trials per energy and channel, ~20–40 min each), submit
   `extgen_nuwro_scan_grid.sh` (example in its header), then
   `extgen_nuwro_tables.py scan_*/ --xsec STEM_xsec.txt --max STEM_max.txt`
   and `extgen_make_splines.py STEM_xsec.txt STEM_xsec.xml --tune
   NW25_11a_00_000 --cap 8 --extend-to 200`, with STEM =
   `nuwro_<version>_<cardhash>` (first 8 hex digits of the md5 of
   `extgen_nuwro_card.sh`), into uboonedata `genie/nuwro/`.
3. Production XMLs as for GiBUU, with `extgen_nuwro_grid_init.sh
   --stepa-fcl extgen_requests_nuwro_bnb_run4c.fcl --nevents auto
   --nuwro-tarball ... --nuwro-md5 ... --tables genie/nuwro/<STEM>
   --soft-fail` and `<endscript>extgen_nuwro_grid_continue.sh</endscript>`.
   The job files are those of the GiBUU route (`extgen_job_summary.txt`,
   `extgen_xsec_check.txt`, ...); NuWro starts in ~70 s per group
   (`spp_precision = 2000`) plus ~12 ms per event.

Validation V3 (request mode against stock NuWro, same card, one fixed
energy): `extgen_nuwro_v3.sh -d <unpacked tarball> -t TARGET -n NU -c CC|NC
-E E_GeV -N 20000 -s SEED -o OUT`. Stock NuWro runs inside `nuwro_extgen -m
stock` (NuWro's own `test_events` and `real_events`, as stock `NuWro::main`);
both samples are compared by `extgen_served_compare.py` (any two served-event
files: cross section, process, struck nucleon, multiplicities, lepton
kinematics, Q², leading proton, hadronic energy; the tests of GiBUU's V3).

## Production (grid)

One grid job per EXT file. `xml/` has one reco1 template per generator and
sample, `extgen_<generator>_<sample>_reco1.xml`:

| Sample | Templates | Step A | Chain |
|---|---|---|---|
| BNB run 4c (and every BNB period except 4a) | `extgen_{gibuu,nuwro}_bnb_run4c_reco1.xml` | `extgen_requests_[nuwro_]bnb_run4c.fcl` | BNB |
| BNB run 4a | `extgen_{gibuu,nuwro}_bnb_run4a_reco1.xml` | `extgen_requests_[nuwro_]bnb_run4a.fcl` (run-4a flux set) | BNB |
| NuMI FHC, RHC | `extgen_{gibuu,nuwro}_numi_{fhc,rhc}_reco1.xml` | `extgen_requests_[nuwro_]numi_{fhc,rhc}.fcl` (dk2nu flux, NuMI timing) | NuMI: `wirecell_detsim_overlay_numi_uboone.fcl`, `standard_overlay_numi_uboone.fcl`, `reco_uboone_mcc9_8_driver_overlay_numi_stage1c.fcl` |

The BNB run 4c templates are the ones used in production so far; the BNB run 4a and
NuMI templates have not been run yet.

**reco1 job** (GiBUU; NuWro runs the matching `extgen_nuwro_*` scripts):

| Step | What | Where |
|---|---|---|
| initscript | `extgen_gibuu_grid_init.sh --nevents auto --soft-fail ...`: checks the GiBUU tarball (md5), the tables (same GiBUU build and card as the tarball and this ubsim), draws the job's seeds | before SAM |
| stage 0 | `extgen_ext_copy.fcl`: copies the job's EXT file into the job | lar |
| its endscript | `extgen_gibuu_grid_continue.sh`: N = EXT events (checked against sam `event_count`); steps A–D: N GENIE requests (`extgen_requests_bnb_run4c.fcl`), request file, GiBUU serving + in-job cross-section check (V4), merge → `genfile.root.local` | shell |
| stages 1… | `extgen_overlay_SimInfoMixer.fcl`, g4, detsim, overlay, reco1 1a/1b/1c | lar |

**reco2 job** (v10_04_07_26): the MCC10 reco2 workflow, with the standard
`run_combinedrecotree_overlay.fcl` (ExtGen events have MCFlux and GTruth) and
a `def_filetype` initsource script for the Wire-Cell FileType (in ubana).

**Before submitting reco1:**
1. Use a release whose uboonedata has the tables and the generator tarball:
   `genie/gibuu/gibuu_<version>_<commit7>.tar.gz` (`make_gibuu_tarball.sh`) or
   `genie/nuwro/nuwro_<version>_<cardhash>.tar.gz` (`make_nuwro_tarball.sh`).
   The jobs find both along FW_SEARCH_PATH and check the tarball's md5.
2. In the XML: the `SET_ME` entities `user`, `name`, `ext_samdef`, `numjobs`, and
   `release`. After a new generator build or card also the tarball name, its md5
   and `tables`.
3. `project.py --xml <xml> --stage reco1 --submit`.

**Per job** (in the job's `log.tar`):

| File | Contents |
|---|---|
| `extgen_job_summary.txt` | seeds, tables and tarball used, N, requests, GiBUU time, V4 result, `status OK` or `status FAIL <reason>` |
| `extgen_xsec_check.txt` | V4: observed / expected GiBUU trial-weight sums per channel and energy band (`WARN` above \|pull\| 4, job fails above 8) |
| `extgen_requests.txt.gz`, `extgen_served_events.txt.gz` | the requests and the GiBUU final states |
| `extgen_serve_summary.txt`, `extgen_trial_stats.txt`, `extgen_logs.tgz` | per GiBUU group: Max range, retries, time; trial statistics; step logs |
| `genfile.root.local` | the merged generator file the mixer read |

A failed setup or step A–D leaves no `genfile.root.local`, so the mixer stage
fails and the job ends with its logs; the reason is the summary's `status
FAIL` line. (`--soft-fail` makes the init script exit 0 after a failure:
condor_lar ends a job whose initscript fails without its log tarball.) After a
failed step A–D the EXT copy is deleted, so that no raw EXT file is copied to
the output directory. A job is rerun exactly with `--seeds` (from its summary).

**After a production:** unpack the log tarballs and run
`extgen_gibuu_v4_summary.py <dir>`: production-wide observed / expected per
channel. Expect totals within a few per mille to a few percent of 1
(|pull| < 3). Single-band in-job warnings, mostly negative, are expected at
the ~1 % level (heavy tail of GiBUU's trial weights).

**Truth-level comparison (V5)**, on reco2 output (combined reco tree files):
```
extgen_v5_compare.py -s ExtGen=<reco2 hist files> -s HepMC_GiBUU=<file> \
    -s GENIE=<file> -w GENIE='weight_cv*weight_spline' --pdf v5.pdf
```
Events per POT and shape tests (chi2, KS) for E_nu, muon kinematics, Q2,
vertex, time, primary multiplicities and leading-proton momentum, plus mode
fractions; `--channel numuCC|numuNC|nueCC|all`, true vertex in the active TPC
unless `--all-vertices`.

**Sample definition:** E_nu < 8 GeV (GiBUU tables end there): no effect for
BNB, 0.1 % (FHC) / 0.2 % (RHC) of NuMI interactions are left out; POT is
that of the whole flux.

