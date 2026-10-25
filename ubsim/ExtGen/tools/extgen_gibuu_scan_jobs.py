#!/usr/bin/env python
"""Job list of the GiBUU scan campaign for the ExtGen spline and Max tables.

One line per grid job:  job_index target_pdg nu_pdg CC|NC trials seed
Each job scans every energy of extgen_gibuu_energies.txt with `trials`
trials (extgen_gibuu_scan_grid.sh picks its line by $PROCESS). Statistics of
all jobs of a channel are added by extgen_gibuu_tables.py, so a channel's
precision is set by its number of jobs. The relative error of a point
scales as 1/sqrt(jobs x trials); in local tests one trial has an rms of
~3-15 times sigma (Ar40 numu CC, 3-0.5 GeV), so one job of 20000 trials gives
~2-10% and 100 jobs ~0.2-1%.

Default tiers (jobs per channel), by share of the BNB interactions in
volCryostat (Ar40 ~89%, numu ~98%):
  1: Ar40 numu CC/NC                                       --tier1 (100)
  2: Ar40 numubar/nue/nuebar; Fe56, Cr52, Ni59 numu        --tier2 (12)
  3: every other channel of the 13 volCryostat nuclei     --tier3 (4)
  4: N14, K39, free neutron (outside volCryostat: GENIE
     needs their splines but they never interact)          --tier4 (1)
Seeds are seed_offset + job_index, unique within the campaign; a retried job
reuses its seed and reproduces its result.

Works with python 2.7 and python 3.
"""
from __future__ import print_function

import argparse

AR40 = 1000180400
CRYOSTAT = [AR40, 1000260560, 1000240520, 1000280590, 1000060120, 1000080160,
            1000010010, 1000140280, 1000220480, 1000130270, 1000200400,
            1000120240, 1000110230]
OUTSIDE = [1000070140, 1000190390, 1000000010]
STEEL = [1000260560, 1000240520, 1000280590]
FLAVOURS = [14, -14, 12, -12]
CURRENTS = ["CC", "NC"]


def tier(tgt, nu):
    if tgt in OUTSIDE:
        return 4
    if tgt == AR40 and nu == 14:
        return 1
    if tgt == AR40 or (tgt in STEEL and nu == 14):
        return 2
    return 3


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("output", help="job list file")
    ap.add_argument("--trials", type=int, default=20000, help="trials per energy per job")
    ap.add_argument("--tier1", type=int, default=100)
    ap.add_argument("--tier2", type=int, default=12)
    ap.add_argument("--tier3", type=int, default=4)
    ap.add_argument("--tier4", type=int, default=1)
    ap.add_argument("--seed-offset", type=int, default=1000,
                    help="seed of job 0 (use a new offset for an extension campaign)")
    ap.add_argument("--only", default=None,
                    help="restrict to channels 'target:nu:CC|NC[,...]', e.g. 1000180400:14:CC")
    args = ap.parse_args()

    jobs_per_tier = {1: args.tier1, 2: args.tier2, 3: args.tier3, 4: args.tier4}
    only = None
    if args.only:
        only = set()
        for item in args.only.split(","):
            t, n, c = item.split(":")
            only.add((int(t), int(n), c))

    lines = []
    for tgt in CRYOSTAT + OUTSIDE:
        for nu in FLAVOURS:
            for cur in CURRENTS:
                if only is not None and (tgt, nu, cur) not in only:
                    continue
                for _ in range(jobs_per_tier[tier(tgt, nu)]):
                    lines.append((tgt, nu, cur))

    with open(args.output, "w") as f:
        f.write("# job_index target_pdg nu_pdg CC|NC trials seed  (extgen_gibuu_scan_jobs.py)\n")
        for i, (tgt, nu, cur) in enumerate(lines):
            f.write("%d %d %d %s %d %d\n" % (i, tgt, nu, cur, args.trials, args.seed_offset + i))
    print("wrote %d jobs to %s" % (len(lines), args.output))
    for t in sorted(jobs_per_tier):
        n = sum(1 for (tgt, nu, cur) in lines if tier(tgt, nu) == t)
        print("  tier %d: %d jobs" % (t, n))


if __name__ == "__main__":
    main()
