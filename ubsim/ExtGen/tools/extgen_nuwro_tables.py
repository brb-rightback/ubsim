#!/usr/bin/env python
"""Merge NuWro scans into the ExtGen cross-section and Max tables.

Reads scan directories written by extgen_nuwro_scan.sh (extgen_scan.info +
scan.txt), adds up the trial statistics of every (neutrino, current, target,
energy, NuWro channel) over all scans, and writes:

  --xsec FILE   cross-section table for extgen_make_splines.py and the
                in-job check (same format as the GiBUU table):
                  nu_pdg CC|NC target_pdg E_GeV sigma   # rel_err n_trials
                sigma = A * sum over the channels of the mean weight
                [1e-38 cm^2 per nucleus]; rel_err from the channels'
                statistical errors added in quadrature; n_trials the
                smallest number of trials of a channel.
  --max FILE    largest weight seen per point and channel (per nucleon, the
                scale of nuwro_extgen's Max values):
                  nu_pdg CC|NC target_pdg E_GeV dyn max_w n_trials

Every scan must come from the same NuWro build (commit and nuwro_extgen
checksum in extgen_scan.info), unless --allow-mixed-builds is given, and from
the same card script: its md5 goes into both tables as "# NuWro card md5:",
which the grid jobs check against the card they serve with. All scans of a
(neutrino, current, target) must have the same channels. NaN weights
(discarded by nuwro_extgen, as by stock NuWro) are reported per channel;
--max-rel-err X makes the
script fail if a point with sigma > 0 is less precise than X.

Works with python 2.7 (uboonecode v08 environment) and python 3.
"""
from __future__ import print_function, division

import argparse
import collections
import math
import os
import sys


def fail(msg):
    sys.exit("extgen_nuwro_tables.py: ERROR: " + msg)


def read_info(path):
    info = {}
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            key, _, value = line.strip().partition(" ")
            info[key] = value.strip()
    for key in ("target", "nu", "current", "nuwro_commit", "nuwro_md5", "card_md5", "end"):
        if key not in info:
            fail("%s: no '%s' (scan not finished?)" % (path, key))
    return info


def read_scan(path):
    header = None
    rows = []
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            if line.startswith("# extgen-nuwro-scan v1"):
                header = dict(w.split("=", 1) for w in line.split()[3:] if "=" in w)
                continue
            if line.startswith("#") or not line.strip():
                continue
            c = line.split()
            if len(c) != 8:
                fail("%s:%d: %d columns, expected 8" % (path, lineno, len(c)))
            # E dyn n sum_w sum_w2 max_w n_nan
            rows.append((float(c[1]), int(c[2]), int(c[3]), float(c[4]), float(c[5]),
                         float(c[6]), int(c[7])))
    if header is None:
        fail("%s: no extgen-nuwro-scan header" % path)
    return header, rows


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scans", nargs="+", help="scan directories (extgen_nuwro_scan.sh -o)")
    ap.add_argument("--xsec", required=True, help="output cross-section table")
    ap.add_argument("--max", dest="maxfile", required=True, help="output Max table")
    ap.add_argument("--max-rel-err", type=float, default=None,
                    help="fail if a point with sigma > 0 has a larger relative error")
    ap.add_argument("--allow-mixed-builds", action="store_true",
                    help="accept scans made with different NuWro builds")
    args = ap.parse_args()

    # (nu, cur, tgt, E, dyn) -> [n, sum_w, sum_w2, max_w, n_nan]
    acc = collections.defaultdict(lambda: [0, 0.0, 0.0, 0.0, 0])
    channel_sets = {}
    nucleons = {}
    builds = set()
    cards = set()
    for d in args.scans:
        info = read_info(os.path.join(d, "extgen_scan.info"))
        header, rows = read_scan(os.path.join(d, "scan.txt"))
        tgt, nu, cur = int(info["target"]), int(info["nu"]), info["current"]
        if cur not in ("CC", "NC"):
            fail("%s: current '%s'" % (d, cur))
        if (int(header["tgt_pdg"]), int(header["nu_pdg"]), header["ccnc"]) != (tgt, nu, cur):
            fail("%s: scan.txt is for %s %s %s, extgen_scan.info for %d %d %s"
                 % (d, header["tgt_pdg"], header["nu_pdg"], header["ccnc"], tgt, nu, cur))
        chans = header["channels"]
        if channel_sets.setdefault((nu, cur, tgt), chans) != chans:
            fail("%s: channels %s, other scans of this group have %s"
                 % (d, chans, channel_sets[(nu, cur, tgt)]))
        nucleons[tgt] = (tgt // 10) % 1000
        builds.add((info["nuwro_commit"], info["nuwro_md5"]))
        cards.add(info["card_md5"])
        for E, dyn, n, sw, sw2, mw, nnan in rows:
            if n <= 0:
                fail("%s: energy %g channel %d has no trials" % (d, E, dyn))
            a = acc[(nu, cur, tgt, E, dyn)]
            a[0] += n
            a[1] += sw
            a[2] += sw2
            a[3] = max(a[3], mw)
            a[4] += nnan
    if len(builds) > 1 and not args.allow_mixed_builds:
        fail("scans from %d different NuWro builds: %s" % (len(builds), sorted(builds)))
    if len(cards) > 1:
        fail("scans from %d different card scripts: %s" % (len(cards), sorted(cards)))
    card = cards.pop()

    # per point: channels summed
    points = collections.defaultdict(list)
    for (nu, cur, tgt, E, dyn), a in acc.items():
        points[(nu, cur, tgt, E)].append((dyn, a))

    worst = []
    nan_total = 0
    nan_by = {}
    channels = collections.defaultdict(list)
    build_line = " ".join("%s/%s" % b for b in sorted(builds))
    with open(args.xsec, "w") as fx, open(args.maxfile, "w") as fm:
        fx.write("# NuWro total cross sections, from %d scans (extgen_nuwro_tables.py)\n"
                 % len(args.scans))
        fx.write("# NuWro build(s): %s\n" % build_line)
        fx.write("# NuWro card md5: %s\n" % card)
        fx.write("# nu_pdg CC|NC target_pdg E_GeV sigma[1e-38 cm^2 per nucleus]"
                 "   # rel_err n_trials\n")
        fm.write("# largest NuWro weight per channel [1e-38 cm^2 per nucleon], from %d scans\n"
                 % len(args.scans))
        fm.write("# NuWro build(s): %s\n" % build_line)
        fm.write("# NuWro card md5: %s\n" % card)
        fm.write("# nu_pdg CC|NC target_pdg E_GeV dyn max_w n_trials\n")
        for key in sorted(points):
            nu, cur, tgt, E = key
            A = nucleons[tgt]
            mean = var = 0.0
            nmin = None
            for dyn, (n, sw, sw2, mw, nnan) in sorted(points[key]):
                m = sw / n
                v = max(0.0, sw2 / n - m * m)
                mean += m
                var += v / (n - 1) if n > 1 else float("inf")
                nmin = n if nmin is None else min(nmin, n)
                nan_total += nnan
                fm.write("%d %s %d %.6g %d %.8g %d\n" % (nu, cur, tgt, E, dyn, mw, n))
            err = math.sqrt(var)
            rel = err / mean if mean > 0 else 0.0
            fx.write("%d %s %d %.6g %.8g   # %.4f %d\n" % (nu, cur, tgt, E, A * mean, rel, nmin))
            channels[(nu, cur, tgt)].append((E, nmin, rel, A * mean))
            if args.max_rel_err is not None and mean > 0 and rel > args.max_rel_err:
                worst.append((rel, key))

    print("%-24s %6s %10s %16s" % ("channel", "points", "min_trials", "worst_rel_err@E"))
    for ch in sorted(channels):
        pts = channels[ch]
        rel, E = max((p[2], p[0]) for p in pts if p[3] > 0) if any(p[3] > 0 for p in pts) \
            else (0.0, 0.0)
        print("%-24s %6d %10d %9.4f@%-6g" % ("%d %s %d" % ch, len(pts),
                                            min(p[1] for p in pts), rel, E))
    if nan_total:
        print("NaN weights discarded by nuwro_extgen (not in the statistics): %d" % nan_total)
        for key in sorted(acc):
            n, sw, sw2, mw, nnan = acc[key]
            if nnan:
                nan_by.setdefault(key[:3] + (key[4],), [0, 0])
                nan_by[key[:3] + (key[4],)][0] += nnan
                nan_by[key[:3] + (key[4],)][1] += n
        for k in sorted(nan_by):
            print("  %d %s %d dyn %d: %d NaN per %d valid trials (%.2g%%)"
                  % (k + (nan_by[k][0], nan_by[k][1], 100.0 * nan_by[k][0] / nan_by[k][1])))
    print("card md5 %s; wrote %s and %s" % (card, args.xsec, args.maxfile))
    if worst:
        worst.sort(reverse=True)
        fail("%d points above --max-rel-err %g, worst %.4f at %s"
             % (len(worst), args.max_rel_err, worst[0][0], worst[0][1]))


if __name__ == "__main__":
    main()
