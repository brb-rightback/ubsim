#!/bin/bash
#
# project.py <endscript> of the EXT copy stage (extgen_ext_copy.fcl) in grid
# jobs with extgen_gibuu_grid_init.sh --nevents auto: runs steps A-D with as
# many generator events as the copied EXT file has.
#
# Always exits 0: condor_lar.sh ends a job at once, without saving its logs,
# when a stage script fails. On failure there is no genfile.root.local, so
# the mixer stage fails and the job ends the normal way, logs included;
# the reason is in extgen_job_summary.txt.

extgen_gibuu_grid_init.sh --continue \
  || echo "extgen_gibuu_grid_continue.sh: steps A-D failed (extgen_job_summary.txt); the mixer stage will fail"
exit 0
