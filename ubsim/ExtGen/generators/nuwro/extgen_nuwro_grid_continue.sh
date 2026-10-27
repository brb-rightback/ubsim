#!/bin/bash
#
# project.py <endscript> of the EXT copy stage (extgen_ext_copy.fcl) in NuWro grid
# jobs with extgen_nuwro_grid_init.sh --nevents auto: runs steps A-D with as
# many generator events as the copied EXT file has.
#
# Always exits 0: condor_lar.sh ends a job at once, without saving its logs,
# when a stage script fails. On failure there is no genfile.root.local, so
# the mixer stage fails and the job ends the normal way, logs included;
# the reason is in extgen_job_summary.txt.
# On failure the EXT copy is deleted too: after a failed stage condor_lar.sh
# copies every *.root file left in the work directory to the output
# directory, which would put a copy of the raw EXT file there. Without it the
# mixer stage has no input file and fails at once.

if ! extgen_nuwro_grid_init.sh --continue; then
  echo "extgen_nuwro_grid_continue.sh: steps A-D failed (extgen_job_summary.txt); the mixer stage will fail"
  for f in *_extcopy.root; do
    [ -f "$f" ] || continue
    echo "extgen_nuwro_grid_continue.sh: removing the EXT copy $f"
    rm -f "$f" "$f.json"
  done
fi
exit 0
