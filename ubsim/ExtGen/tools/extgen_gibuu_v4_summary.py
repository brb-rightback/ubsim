#!/usr/bin/env python
"""Validation V4 over a production: adds up the in-job cross-section checks
(extgen_gibuu_xsec_check.sh reports, one per job) and prints, per channel and
energy band, observed/expected trial-weight sums and the pull.

  extgen_gibuu_v4_summary.py [--fail-pull 5] REPORT [REPORT ...]

REPORT may be a report file or a directory searched recursively for
extgen_xsec_check.txt. The expected sums' table errors are added linearly
over jobs (they share the table), the observed variances in quadrature.
Exit code 1 if a channel total has |pull| > --fail-pull, is missing from the
table in any job, or a channel or band has requests but no table prediction
(energies outside the table).

Works with python 2.7 and python 3.
"""
from __future__ import print_function, division

import argparse
import math
import os
import sys

NAME = "extgen_xsec_check.txt"


def report_files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                if NAME in files:
                    yield os.path.join(root, NAME)
        else:
            yield p


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reports", nargs="+")
    ap.add_argument("--fail-pull", type=float, default=5.0)
    args = ap.parse_args()

    tot = {}
    missing = set()
    njobs = 0
    for path in report_files(args.reports):
        njobs += 1
        with open(path) as f:
            for line in f:
                if line.startswith("#") or not line.strip():
                    continue
                c = line.split()
                key = (c[0], c[1], c[2], c[3])
                if c[12] == "MISSING":
                    missing.add(key[:3])
                    continue
                t = tot.setdefault(key, [0, 0, 0.0, 0.0, 0.0, 0.0])
                t[0] += int(c[4]); t[1] += int(c[5])
                t[2] += float(c[6]); t[3] += float(c[7])
                t[4] += float(c[8]); t[5] += float(c[9])
    if njobs == 0:
        sys.exit("no reports found")

    bad = False
    print("V4 over %d jobs: obs = sum of GiBUU trial weights, exp = trials x table sigma" % njobs)
    print("%-11s %4s %2s %-6s %8s %11s %8s %8s %7s" %
          ("target", "nu", "", "band", "requests", "trials", "obs/exp", "+-", "pull"))
    for key in sorted(tot, key=lambda k: (k[0], int(k[1]), k[2], k[3] != "all", k[3])):
        nreq, ntr, obs, exp, var, experr = tot[key]
        if exp <= 0:
            # requests outside the table's energy range
            print("%-11s %4s %2s %-6s %8d %11d   no table prediction (obs %.4g)  <-- FAIL" %
                  (key[0], key[1], key[2], key[3], nreq, ntr, obs))
            bad = True
            continue
        d = math.sqrt(var + experr ** 2)
        pull = (obs - exp) / d if d > 0 else 0.0
        flag = ""
        if key[3] == "all" and abs(pull) > args.fail_pull:
            flag = "  <-- FAIL"
            bad = True
        print("%-11s %4s %2s %-6s %8d %11d %8.4f %8.4f %+7.2f%s" %
              (key[0], key[1], key[2], key[3], nreq, ntr, obs / exp, d / exp, pull, flag))
    for m in sorted(missing):
        print("%s %s %s: missing from the table in some jobs  <-- FAIL" % m)
        bad = True
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
