#!/usr/bin/env python
"""Validation V3 for any generator: compares two served-event files
(ExtGen format, ExtGenIO.h) of the same target, flavour, current and energy,
e.g. NuWro request mode against stock NuWro (extgen_nuwro_v3.sh).

  extgen_served_compare.py A_EVENTS B_EVENTS [--labels A,B]
                           [--sigma-a SIGMA,ERR] [--sigma-b SIGMA,ERR] [--alpha 0.001]

Compared (two-sample tests, the same as GiBUU's V3, extgen_gibuu_v3_compare.py,
whose statistics and observables this script uses):
  * process (gen_proc), struck nucleon (status 11 PDG, "None" if absent)  chi2
  * multiplicities of final-state p, n, pi+-, pi0                          chi2 (0, 1, 2, 3+)
  * lepton energy, lepton cos(theta), Q2, leading-proton momentum,
    summed hadron kinetic energy                                           Kolmogorov-Smirnov
  * cross sections, if both are given (same units)                          pull
Frame: neutrino along +z (as in served-event files); the lepton is the first
status-1 particle, the hadrons every other status-1 particle.
A p-value below --alpha (default 0.001, i.e. ~1% chance of any false alarm
over the ~12 tests) is flagged; the exit code is 1 if any test is flagged.

Works with python 2.7 and python 3.
"""
from __future__ import print_function, division

import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from extgen_gibuu_v3_compare import chi2_two_sample, ks_two_sample, observables  # noqa: E402


def read_served(path):
    """Events as extgen_gibuu_v3_compare.observables() takes them, plus the energies."""
    events, energies = [], set()
    ev = None
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            t = line.split()
            if not t or t[0].startswith("#"):
                continue
            if t[0] == "EVENT":
                E = float(t[2])
                energies.add(E)
                ev = {"proc": int(t[3]), "hit": None, "lep": None,
                      "nu": (0, 0.0, 0.0, E, E), "finals": []}
                events.append(ev)
            elif t[0] == "P" and ev is not None:
                status, pdg = int(t[1]), int(t[2])
                p = (pdg, float(t[3]), float(t[4]), float(t[5]), float(t[6]))
                if status == 11:
                    ev["hit"] = pdg
                elif status == 1:
                    if ev["lep"] is None:
                        ev["lep"] = p
                    else:
                        ev["finals"].append(p)
            else:
                sys.exit("%s:%d: unexpected line" % (path, lineno))
    for i, e in enumerate(events):
        if e["lep"] is None:
            sys.exit("%s: event %d has no status-1 particle" % (path, i))
    return events, energies


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--labels", default="A,B")
    ap.add_argument("--sigma-a", default=None, help="SIGMA,ERR of sample A")
    ap.add_argument("--sigma-b", default=None, help="SIGMA,ERR of sample B")
    ap.add_argument("--alpha", type=float, default=0.001)
    args = ap.parse_args()
    la, lb = args.labels.split(",")

    ea, Ea = read_served(args.a)
    eb, Eb = read_served(args.b)
    if len(Ea | Eb) != 1:
        sys.exit("the samples must have one common energy, found %s" % sorted(Ea | Eb))
    print("V3: %d %s and %d %s events at %g GeV" % (len(ea), la, len(eb), lb, Ea.pop()))

    flagged = []

    def report(name, stat, p):
        flag = p < args.alpha
        if flag:
            flagged.append(name)
        print("  %-28s %-26s p = %.4f %s" % (name, stat, p, "  <-- FLAG" if flag else ""))

    if args.sigma_a and args.sigma_b:
        sa, da = (float(x) for x in args.sigma_a.split(","))
        sb, db = (float(x) for x in args.sigma_b.split(","))
        pull = (sa - sb) / math.sqrt(da * da + db * db)
        print("  cross section: %s %.5g +- %.2g, %s %.5g +- %.2g" % (la, sa, da, lb, sb, db))
        report("cross section", "pull %+.2f" % pull, math.erfc(abs(pull) / math.sqrt(2)))

    oa, ob = observables(ea), observables(eb)
    for k, name in (("proc", "process (gen_proc)"), ("hit", "struck nucleon"),
                    ("np", "N protons (0-3+)"), ("nn", "N neutrons (0-3+)"),
                    ("npic", "N charged pions (0-3+)"), ("npi0", "N pi0 (0-3+)")):
        x, ndf, p = chi2_two_sample(oa[k], ob[k])
        report(name, "chi2/ndf %.1f/%d" % (x, ndf), p)
    for k, name in (("elep", "lepton energy"), ("cost", "lepton cos(theta)"),
                    ("q2", "Q2"), ("pprot", "leading proton momentum"),
                    ("ekhad", "hadron kinetic energy")):
        dks, p = ks_two_sample(oa[k], ob[k])
        report(name, "KS D %.4f" % dks, p)

    print("  process fractions (%s / %s):" % (la, lb))
    for k in sorted(set(oa["proc"]) | set(ob["proc"]), key=str):
        print("    %-6s %.4f / %.4f" % (k, oa["proc"].get(k, 0) / float(len(ea)),
                                      ob["proc"].get(k, 0) / float(len(eb))))
    if flagged:
        print("V3: FLAGGED: " + ", ".join(flagged))
        return 1
    print("V3: no test below alpha = %g" % args.alpha)
    return 0


if __name__ == "__main__":
    sys.exit(main())
