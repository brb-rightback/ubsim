#!/usr/bin/env python
"""Summarise an ExtGen request file (ExtGenRequestDumper output) and check it.

Prints the header, the number of requests per target nucleus and per
(flavour, current), the energy distribution per flavour, and the range of
vertices and times. Fails (exit code 1) if the file is malformed: wrong
number of columns, req_id not 0..N-1 in order, a duplicated
(run, subrun, event, truth_idx), a non-positive energy, or a direction that
is not a unit vector.

Python 2.7/3, no ROOT needed (works in the v08 environment).
"""
from __future__ import print_function

import argparse
import collections
import math
import sys

NUCLEI = {
    1000180400: "Ar40", 1000260560: "Fe56", 1000240520: "Cr52",
    1000280590: "Ni59", 1000060120: "C12", 1000080160: "O16",
    1000010010: "H1 (p)", 1000140280: "Si28", 1000220480: "Ti48",
    1000130270: "Al27", 1000200400: "Ca40", 1000120240: "Mg24",
    1000110230: "Na23", 1000070140: "N14", 1000190390: "K39",
    1000000010: "n (Vacuum)",
}
FLAVOURS = {12: "nue", -12: "nuebar", 14: "numu", -14: "numubar",
            16: "nutau", -16: "nutaubar"}
NCOLS = 16


def histogram(values, edges):
    counts = [0] * (len(edges) - 1)
    for v in values:
        for i in range(len(edges) - 1):
            if edges[i] <= v < edges[i + 1]:
                counts[i] += 1
                break
    return counts


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("requests", help="request file (requests.txt)")
    ap.add_argument("--ebins", default="0,0.25,0.5,0.75,1,1.25,1.5,2,2.5,3,4,5,8,1000",
                    help="energy bin edges in GeV (comma separated)")
    args = ap.parse_args()

    errors = []
    header = []
    rows = []
    with open(args.requests) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                header.append(line)
                continue
            cols = line.split()
            if len(cols) != NCOLS:
                errors.append("line %d: %d columns, expected %d" % (lineno, len(cols), NCOLS))
                continue
            rows.append(dict(
                req_id=int(cols[0]), key=tuple(int(c) for c in cols[1:5]),
                nu=int(cols[5]), ccnc=cols[6], tgt=int(cols[7]), E=float(cols[8]),
                v=[float(c) for c in cols[9:12]], t=float(cols[12]),
                d=[float(c) for c in cols[13:16]], lineno=lineno))

    for h in header:
        print(h)
    n = len(rows)
    print("\n%d requests" % n)
    if n == 0:
        errors.append("no requests")

    # --- consistency checks
    seen = set()
    for i, r in enumerate(rows):
        if r["req_id"] != i:
            errors.append("line %d: req_id %d, expected %d" % (r["lineno"], r["req_id"], i))
        if r["key"] in seen:
            errors.append("line %d: duplicate run/subrun/event/truth_idx %s" % (r["lineno"], r["key"]))
        seen.add(r["key"])
        if r["ccnc"] not in ("CC", "NC"):
            errors.append("line %d: bad current %s" % (r["lineno"], r["ccnc"]))
        if not r["E"] > 0:
            errors.append("line %d: energy %g" % (r["lineno"], r["E"]))
        norm = math.sqrt(sum(c * c for c in r["d"]))
        if abs(norm - 1) > 1e-9:
            errors.append("line %d: |direction| = %.12g" % (r["lineno"], norm))
    nevents = len(set(r["key"][:3] for r in rows))
    print("%d events with at least one request (%.3f requests per such event)"
          % (nevents, float(n) / nevents if nevents else 0))

    # --- target mix
    print("\nTarget nucleus        requests  fraction")
    for tgt, c in collections.Counter(r["tgt"] for r in rows).most_common():
        print("  %-12s %10d %10d  %8.4f" % (NUCLEI.get(tgt, "?"), tgt, c, float(c) / n))

    # --- flavour and current
    print("\nFlavour   current  requests  fraction  <E>/GeV")
    fc = collections.defaultdict(list)
    for r in rows:
        fc[(r["nu"], r["ccnc"])].append(r["E"])
    for (nu, cur), es in sorted(fc.items(), key=lambda kv: -len(kv[1])):
        print("  %-8s %-6s %9d  %8.4f  %7.3f" % (FLAVOURS.get(nu, str(nu)), cur, len(es),
                                                 float(len(es)) / n, sum(es) / len(es)))

    # --- energy spectra per flavour
    edges = [float(x) for x in args.ebins.split(",")]
    flavs = sorted(set(r["nu"] for r in rows), key=lambda x: (abs(x), x < 0))
    print("\nEnergy [GeV]  " + "".join("%9s" % FLAVOURS.get(nu, nu) for nu in flavs))
    hists = [histogram([r["E"] for r in rows if r["nu"] == nu], edges) for nu in flavs]
    for i in range(len(edges) - 1):
        print("  %5.2f-%-6.2f" % (edges[i], edges[i + 1]) + "".join("%9d" % h[i] for h in hists))
    if rows:
        print("  min %.6g GeV, max %.6g GeV" % (min(r["E"] for r in rows), max(r["E"] for r in rows)))

    # --- vertices, times, directions
    if rows:
        print("\nVertex range [cm] (compare with volCryostat):")
        for k, name in enumerate("xyz"):
            vals = [r["v"][k] for r in rows]
            print("  %s: %10.2f .. %10.2f" % (name, min(vals), max(vals)))
        ts = [r["t"] for r in rows]
        print("Time range [ns]: %.2f .. %.2f" % (min(ts), max(ts)))
        dz = [r["d"][2] for r in rows]
        print("Direction cosine z: %.6f .. %.6f (mean %.6f)" % (min(dz), max(dz), sum(dz) / n))

    if errors:
        print("\n%d ERRORS:" % len(errors))
        for e in errors[:50]:
            print("  " + e)
        return 1
    print("\nAll checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
