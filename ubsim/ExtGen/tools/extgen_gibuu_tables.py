#!/usr/bin/env python
"""Merge GiBUU scans into the ExtGen cross-section and Max tables.

Reads scan directories written by extgen_gibuu_scan.sh (extgen_scan.info +
uboone_request_stats.dat), adds up the trial statistics of every
(neutrino, current, target, energy) over all scans, and writes:

  --xsec FILE   cross-section table for extgen_make_splines.py:
                  nu_pdg CC|NC target_pdg E_GeV sigma   # rel_err n_trials
                sigma = A * mean trial weight [1e-38 cm^2 per nucleus];
                rel_err is its statistical uncertainty (rms / sqrt(n) / mean).
  --max FILE    largest trial weight seen per point (per nucleon, the scale
                GiBUU's equal-weights Max is on):
                  nu_pdg CC|NC target_pdg E_GeV max_w n_trials

Every scan must come from the same GiBUU build (commit and binary checksum
in extgen_scan.info), unless --allow-mixed-builds is given, and from the same
job card script: its md5 (card_md5 in extgen_scan.info, or --card for scans
that predate that line) goes into both tables as "# GiBUU card md5:", and
extgen_gibuu_grid_init.sh checks it against the card it serves with. --max-rel-err X
makes the script fail if a point with sigma > 0 is less precise than X.

Works with python 2.7 (uboonecode v08 environment) and python 3.
"""
from __future__ import print_function, division

import argparse
import collections
import hashlib
import math
import os
import sys


def fail(msg):
    sys.exit("extgen_gibuu_tables.py: ERROR: " + msg)


def read_info(path):
    info = {}
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            key, _, value = line.strip().partition(" ")
            info[key] = value.strip()
    for key in ("target", "nu", "current", "gibuu_commit", "gibuu_md5", "end"):
        if key not in info:
            fail("%s: no '%s' (scan not finished?)" % (path, key))
    return info


def read_stats(path):
    A = Z = mode = None
    rows = []
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            if line.startswith("# uboone-request-stats v1"):
                fields = dict(w.split("=") for w in line.split()[3:])
                A, Z, mode = int(fields["A"]), int(fields["Z"]), int(fields["mode"])
                continue
            if line.startswith("#") or not line.strip():
                continue
            c = line.split()
            if len(c) != 10:
                fail("%s:%d: %d columns, expected 10" % (path, lineno, len(c)))
            rows.append((float(c[1]), int(c[3]), float(c[4]), float(c[5]), float(c[6])))
    if A is None:
        fail("%s: no uboone-request-stats header" % path)
    if mode != 2:
        fail("%s: request mode %d, a scan has mode 2" % (path, mode))
    return A, Z, rows


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scans", nargs="+", help="scan directories (extgen_gibuu_scan.sh -o)")
    ap.add_argument("--xsec", required=True, help="output cross-section table")
    ap.add_argument("--max", dest="maxfile", required=True, help="output Max table")
    ap.add_argument("--max-rel-err", type=float, default=None,
                    help="fail if a point with sigma > 0 has a larger relative error")
    ap.add_argument("--allow-mixed-builds", action="store_true",
                    help="accept scans made with different GiBUU builds")
    ap.add_argument("--card", default=None,
                    help="extgen_gibuu_card.sh the scans ran with (for scans "
                         "without card_md5 in extgen_scan.info)")
    args = ap.parse_args()
    card_arg = None
    if args.card:
        with open(args.card, "rb") as f:
            card_arg = hashlib.md5(f.read()).hexdigest()

    # (nu, cur, tgt, E) -> [n, sum_w, sum_w2, max_w]
    acc = collections.defaultdict(lambda: [0, 0.0, 0.0, 0.0])
    nucleons = {}
    builds = set()
    cards = set()
    for d in args.scans:
        info = read_info(os.path.join(d, "extgen_scan.info"))
        A, Z, rows = read_stats(os.path.join(d, "uboone_request_stats.dat"))
        tgt, nu, cur = int(info["target"]), int(info["nu"]), info["current"]
        if cur not in ("CC", "NC"):
            fail("%s: current '%s'" % (d, cur))
        if (tgt // 10) % 1000 != A or (tgt // 10000) % 1000 != Z:
            fail("%s: target %d but GiBUU ran A=%d Z=%d" % (d, tgt, A, Z))
        nucleons[tgt] = A
        builds.add((info["gibuu_commit"], info["gibuu_md5"]))
        card = info.get("card_md5", card_arg)
        if card is None:
            fail("%s: no card_md5 in extgen_scan.info, give --card" % d)
        if card_arg is not None and card != card_arg:
            fail("%s: card md5 %s, --card has %s" % (d, card, card_arg))
        cards.add(card)
        for E, n, sw, sw2, mw in rows:
            if n <= 0:
                fail("%s: energy %g has no trials" % (d, E))
            a = acc[(nu, cur, tgt, E)]
            a[0] += n
            a[1] += sw
            a[2] += sw2
            a[3] = max(a[3], mw)
    if len(builds) > 1 and not args.allow_mixed_builds:
        fail("scans from %d different GiBUU builds: %s" % (len(builds), sorted(builds)))
    if len(cards) > 1:
        fail("scans from %d different job card scripts: %s" % (len(cards), sorted(cards)))
    card = cards.pop()

    worst = []
    channels = collections.defaultdict(list)
    with open(args.xsec, "w") as fx, open(args.maxfile, "w") as fm:
        fx.write("# GiBUU total cross sections, from %d scans (extgen_gibuu_tables.py)\n"
                 % len(args.scans))
        fx.write("# GiBUU build(s): %s\n" % " ".join("%s/%s" % b for b in sorted(builds)))
        fx.write("# GiBUU card md5: %s\n" % card)
        fx.write("# nu_pdg CC|NC target_pdg E_GeV sigma[1e-38 cm^2 per nucleus]"
                 "   # rel_err n_trials\n")
        fm.write("# largest GiBUU trial weight [1e-38 cm^2 per nucleon], from %d scans\n"
                 % len(args.scans))
        fm.write("# GiBUU build(s): %s\n" % " ".join("%s/%s" % b for b in sorted(builds)))
        fm.write("# GiBUU card md5: %s\n" % card)
        fm.write("# nu_pdg CC|NC target_pdg E_GeV max_w n_trials\n")
        for key in sorted(acc):
            nu, cur, tgt, E = key
            n, sw, sw2, mw = acc[key]
            A = nucleons[tgt]
            mean = sw / n
            var = max(0.0, sw2 / n - mean * mean)
            err = math.sqrt(var / (n - 1)) if n > 1 else float("inf")
            rel = err / mean if mean > 0 else 0.0
            fx.write("%d %s %d %.6g %.8g   # %.4f %d\n" % (nu, cur, tgt, E, A * mean, rel, n))
            fm.write("%d %s %d %.6g %.8g %d\n" % (nu, cur, tgt, E, mw, n))
            channels[(nu, cur, tgt)].append((E, n, rel, mw, A * mean))
            if args.max_rel_err is not None and mean > 0 and rel > args.max_rel_err:
                worst.append((rel, key))

    print("%-24s %6s %10s %16s %12s" % ("channel", "points", "min_trials",
                                         "worst_rel_err@E", "max_w"))
    for ch in sorted(channels):
        pts = channels[ch]
        rel, E = max((p[2], p[0]) for p in pts if p[4] > 0) if any(p[4] > 0 for p in pts) \
            else (0.0, 0.0)
        print("%-24s %6d %10d %9.4f@%-6g %12.4g" % ("%d %s %d" % ch, len(pts),
                                                    min(p[1] for p in pts), rel, E,
                                                    max(p[3] for p in pts)))
    print("card md5 %s; wrote %s and %s" % (card, args.xsec, args.maxfile))
    if worst:
        worst.sort(reverse=True)
        fail("%d points above --max-rel-err %g, worst %.4f at %s"
             % (len(worst), args.max_rel_err, worst[0][0], worst[0][1]))


if __name__ == "__main__":
    main()
