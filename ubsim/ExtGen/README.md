# ExtGen: external neutrino generators through GENIE's flux and geometry drivers

ExtGen runs neutrino interactions from an external generator (GiBUU first)
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
| `gxml/` | GENIE configuration, installed to `$UBSIM_DIR/gxml`: the `GB25_05a_00_000` tune (all tune files in `GB25_05a/`: a `_00_000` tune is "configuration only" to GENIE, which never reads a `GB25_05a_00_000/` subdirectory) plus overriding copies of GENIE's `master_config.xml` and `EventGenerator.xml`. **This directory must only be on `GXMLPATH` for ExtGen jobs, never on `FW_SEARCH_PATH`.** Regenerate the copies with `gxml/make_extgen_gxml.sh` when the GENIE version changes. |
| `Modules/` | art modules: `ExtGenRequestDumper` (step B; writes `requests.txt`, checking each `MCTruth` against its `GTruth`), `ExtGenMerge` (step D), and for the GENIE closure test `ExtGenTruthServer`, `ExtGenClosureCheck` and `ExtGenMixCheck`. Library `ubsim_ExtGen_Modules` (`ExtGenIO`): request and served-event file formats and the generator-to-detector rotation. |
| `tools/` | Offline scripts: `extgen_make_splines.py` (cross section table to GENIE spline XML), `extgen_placeholder_xsec.py` (fake cross sections for tests), `extgen_request_summary.py` (checks a request file and summarises targets, flavours, energies and vertices), `extgen_gibuu_scan_jobs.py` (job list of the GiBUU scan campaign) and `extgen_gibuu_tables.py` (merges scans into the cross-section and Max tables). |
| `job/` | fcl files: `extgen_modules.fcl` (module prologs), `extgen_requests_test_bnb.fcl` (step A test), `extgen_dump_requests.fcl` (step B), `extgen_merge.fcl` (step D, also writes the per-event POT `potinevent:SubRunPOT`), `extgen_overlay_SimInfoMixer.fcl` (overlay on EXT, exact POT per mixed event), `extgen_closure_*.fcl` (GENIE closure test). |
| `generators/gibuu/` | `build_gibuu.sh`: builds GiBUU for grid jobs from a commit of the MicroBooNE GiBUU repository (official release on `main`, MicroBooNE patches such as request mode on `v08_00_00_br`); run by hand in SL7. `extgen_gibuu_card.sh`: the GiBUU card of every ExtGen GiBUU run (one set of physics settings). `extgen_gibuu_scan.sh`: one scan (request mode 2) for the tables; `extgen_gibuu_energies.txt`: its energy grid. `make_gibuu_tarball.sh` and `extgen_gibuu_scan_grid.sh`: the grid scan campaign. `extgen_gibuu_convert`: GiBUU request-mode output to `served_events.txt` and `trial_stats.txt` (step C). `extgen_gibuu_serve.sh`: step C for one job's requests. `extgen_gibuu_xsec_check.sh`: in-job cross-section check (V4). `extgen_gibuu_grid_init.sh`: the project.py `<initscript>` of production jobs (steps A–D, leaving `genfile.root.local` for `extgen_overlay_SimInfoMixer.fcl`). |
| `xml/` | Example project.py XML (`extgen_gibuu_bnb_run4c_test.xml`: 10-job grid test). |

Cross section splines for production live in uboonedata, under `genie/gibuu/`.

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
   jobs each for Ar40 numu CC/NC, 12 for the other Ar40 flavours and steel
   numu, 4 for the other volCryostat channels, 1 for N14, K39 and the free
   neutron; 20000 trials per energy per job, ~45 min).
3. Submit `extgen_gibuu_scan_grid.sh` with jobsub (example in its header);
   each job writes `scan_<index>.tgz` to the output directory.
4. Unpack and merge: `extgen_gibuu_tables.py scan_*/ --xsec xsec.txt --max max.txt`
   (fails on scans from different GiBUU builds), then
   `extgen_make_splines.py xsec.txt <spline>.xml --tune GB25_05a_00_000`.

Target densities: `densitySwitch_Static=2` (as in the 2026 production card)
for C12, O16, Al27, Ar40, Ca40, Fe56, which GiBUU has NPA 554 densities for;
3 (GiBUU's default) for all other nuclei.
