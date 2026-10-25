#!/usr/bin/env python
"""Validation V3: compares GiBUU request-mode events with stock GiBUU events
at the same fixed energy (directories made by extgen_gibuu_v3.sh).

  extgen_gibuu_v3_compare.py OUT [OUT2 ...]

Events of all given directories are pooled (same target, flavour, current,
energy and Max required). Compared (two-sample tests):
  * process (NuHepMC ProcID), struck-nucleon type     chi2
  * multiplicities of final-state p, n, pi+-, pi0    chi2 (0, 1, 2, 3+)
  * lepton energy, lepton cos(theta), Q2, leading-proton momentum,
    summed hadron kinetic energy                     Kolmogorov-Smirnov
  * cross section: request mode (mean trial weight) against stock GiBUU
    (Max x accepted / trials)                        pull
A p-value below --alpha (default 0.001, i.e. ~1% chance of any false alarm
over the ~12 tests) is flagged; the exit code is 1 if any test is flagged.

Works with python 2.7 and python 3.
"""
from __future__ import print_function, division

import argparse
import math
import os
import re
import sys

M_P, M_N = 0.938272, 0.939565


def read_info(d):
    info = {}
    with open(os.path.join(d, "v3.info")) as f:
        for line in f:
            k, _, v = line.strip().partition(" ")
            info[k] = v
    return info


def read_events(path):
    """Per event: dict(proc, hit, lep, nu, finals=[(pdg, px, py, pz, e)])."""
    events = []
    ev = None
    with open(path) as f:
        for line in f:
            t = line.split()
            if not t:
                continue
            if t[0] == "E":
                ev = {"proc": None, "hit": None, "lep": None, "nu": None, "finals": []}
                events.append(ev)
            elif t[0].startswith("HepMC::Asciiv3-END"):
                break
            elif ev is None:
                continue
            elif t[0] == "A" and len(t) >= 4 and t[1] == "0" and t[2] == "ProcID":
                ev["proc"] = int(t[3])
            elif t[0] == "P":
                pdg, status = int(t[3]), int(t[9])
                p = (pdg, float(t[4]), float(t[5]), float(t[6]), float(t[7]))
                if status == 4:
                    ev["nu"] = p
                elif status == 21:
                    ev["hit"] = pdg
                elif status == 1:
                    if ev["lep"] is None:
                        ev["lep"] = p
                    else:
                        ev["finals"].append(p)
    return events


def sigma_request(d):
    n = sw = sw2 = 0.0
    with open(os.path.join(d, "uboone_request_stats.dat")) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            c = line.split()
            n += float(c[3]); sw += float(c[4]); sw2 += float(c[5])
    return n, sw, sw2


def stock_counts(d):
    acc = trials = 0
    with open(os.path.join(d, "gibuu.log")) as f:
        for line in f:
            m = re.match(r"\s*numtry\s*=\s*(\d+)", line)
            if m:
                trials += int(m.group(1))
            m = re.match(r"\s*numberOfSuccess\s*=\s*(\d+)", line)
            if m:
                acc += int(m.group(1))
    return acc, trials


# --- statistics -------------------------------------------------------------
def chi2_sf(x, k):
    """Upper tail of the chi2 distribution (regularised gamma Q(k/2, x/2))."""
    if k <= 0:
        return 1.0
    a, x = k / 2.0, x / 2.0
    if x <= 0:
        return 1.0
    if x < a + 1:  # series for P
        s = term = 1.0 / a
        n = a
        for _ in range(1000):
            n += 1
            term *= x / n
            s += term
            if abs(term) < abs(s) * 1e-15:
                break
        return max(0.0, 1.0 - s * math.exp(-x + a * math.log(x) - math.lgamma(a)))
    # continued fraction for Q
    b = x + 1 - a
    c = 1e300
    dd = 1 / b
    h = dd
    for i in range(1, 1000):
        an = -i * (i - a)
        b += 2
        dd = an * dd + b
        dd = 1e-300 if abs(dd) < 1e-300 else dd
        c = b + an / c
        c = 1e-300 if abs(c) < 1e-300 else c
        dd = 1 / dd
        delta = dd * c
        h *= delta
        if abs(delta - 1) < 1e-15:
            break
    return math.exp(-x + a * math.log(x) - math.lgamma(a)) * h


def chi2_two_sample(ca, cb):
    """Two-sample chi2 for count dicts; bins with < 5 expected merged."""
    keys = sorted(set(ca) | set(cb), key=str)
    na, nb = float(sum(ca.values())), float(sum(cb.values()))
    if na == 0 or nb == 0:
        return float("nan"), 0, 1.0
    bins, cur = [], [0, 0]
    for k in keys:
        cur[0] += ca.get(k, 0)
        cur[1] += cb.get(k, 0)
        if (cur[0] + cur[1]) * min(na, nb) / (na + nb) >= 5:
            bins.append(cur)
            cur = [0, 0]
    if cur[0] + cur[1] > 0:
        if bins:
            bins[-1][0] += cur[0]
            bins[-1][1] += cur[1]
        else:
            bins.append(cur)
    x = 0.0
    for a, b in bins:
        if a + b > 0:
            x += (math.sqrt(nb / na) * a - math.sqrt(na / nb) * b) ** 2 / (a + b)
    ndf = len(bins) - 1
    return x, ndf, chi2_sf(x, ndf)


def ks_two_sample(xa, xb):
    xa, xb = sorted(xa), sorted(xb)
    na, nb = len(xa), len(xb)
    if na == 0 or nb == 0:
        return float("nan"), 1.0
    i = j = 0
    d = 0.0
    while i < na and j < nb:
        v = min(xa[i], xb[j])
        while i < na and xa[i] <= v:
            i += 1
        while j < nb and xb[j] <= v:
            j += 1
        d = max(d, abs(i / na - j / nb))
    en = math.sqrt(na * nb / float(na + nb))
    lam = (en + 0.12 + 0.11 / en) * d
    p = 0.0
    for k in range(1, 101):
        p += 2 * (-1) ** (k - 1) * math.exp(-2 * k * k * lam * lam)
    return d, min(1.0, max(0.0, p))


# --- observables ------------------------------------------------------------
def observables(events):
    o = {"proc": {}, "hit": {}, "np": {}, "nn": {}, "npic": {}, "npi0": {},
         "elep": [], "cost": [], "q2": [], "pprot": [], "ekhad": []}

    def inc(d, k):
        d[k] = d.get(k, 0) + 1

    for ev in events:
        inc(o["proc"], ev["proc"])
        inc(o["hit"], ev["hit"])
        cnt = {"np": 0, "nn": 0, "npic": 0, "npi0": 0}
        pmax, ek = 0.0, 0.0
        for pdg, px, py, pz, e in ev["finals"]:
            p = math.sqrt(px * px + py * py + pz * pz)
            m2 = max(0.0, e * e - p * p)
            ek += e - math.sqrt(m2)
            if pdg == 2212:
                cnt["np"] += 1
                pmax = max(pmax, p)
            elif pdg == 2112:
                cnt["nn"] += 1
            elif abs(pdg) == 211:
                cnt["npic"] += 1
            elif pdg == 111:
                cnt["npi0"] += 1
        for k, v in cnt.items():
            inc(o[k], min(v, 3))
        lep, nu = ev["lep"], ev["nu"]
        pl = math.sqrt(lep[1] ** 2 + lep[2] ** 2 + lep[3] ** 2)
        o["elep"].append(lep[4])
        o["cost"].append(lep[3] / pl if pl > 0 else 1.0)
        q = [nu[i] - lep[i] for i in range(1, 5)]
        o["q2"].append(-(q[3] ** 2 - q[0] ** 2 - q[1] ** 2 - q[2] ** 2))
        if pmax > 0:
            o["pprot"].append(pmax)
        o["ekhad"].append(ek)
    return o


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--alpha", type=float, default=0.001)
    args = ap.parse_args()

    ref = None
    req, stk = [], []
    n = sw = sw2 = 0.0
    acc = trials = 0
    for d in args.dirs:
        info = read_info(d)
        key = tuple(info[k] for k in ("target", "nu", "current", "energy", "max", "ensembles"))
        if ref is None:
            ref = key
        elif key != ref:
            sys.exit("%s: different setup %s vs %s" % (d, key, ref))
        req += read_events(os.path.join(d, "request", "EventOutput.Pert.hepmc3"))
        stk += read_events(os.path.join(d, "stock", "EventOutput.Pert.hepmc3"))
        a, b, c = sigma_request(os.path.join(d, "request"))
        n += a; sw += b; sw2 += c
        a, b = stock_counts(os.path.join(d, "stock"))
        acc += a; trials += b
    target, nu, cur, energy, mx, ens = ref
    mx = float(mx)
    print("V3: target %s nu %s %s at %s GeV, Max %g: %d request-mode, %d stock events"
          % (target, nu, cur, energy, mx, len(req), len(stk)))

    flagged = []

    def report(name, stat, p):
        flag = p < args.alpha
        if flag:
            flagged.append(name)
        print("  %-28s %-26s p = %.4f %s" % (name, stat, p, "  <-- FLAG" if flag else ""))

    sig_r = sw / n
    err_r = math.sqrt(max(0.0, sw2 / n - sig_r ** 2) / (n - 1))
    sig_s = mx * acc / trials
    err_s = mx * math.sqrt(acc) / trials
    pull = (sig_r - sig_s) / math.sqrt(err_r ** 2 + err_s ** 2)
    p_pull = math.erfc(abs(pull) / math.sqrt(2))
    print("  cross section per nucleon: request %.4f +- %.4f, stock %.4f +- %.4f (1e-38 cm^2)"
          % (sig_r, err_r, sig_s, err_s))
    report("cross section", "pull %+.2f" % pull, p_pull)

    oa, ob = observables(req), observables(stk)
    for k, name in (("proc", "process (ProcID)"), ("hit", "struck nucleon"),
                     ("np", "N protons (0-3+)"), ("nn", "N neutrons (0-3+)"),
                     ("npic", "N charged pions (0-3+)"), ("npi0", "N pi0 (0-3+)")):
        x, ndf, p = chi2_two_sample(oa[k], ob[k])
        report(name, "chi2/ndf %.1f/%d" % (x, ndf), p)
    for k, name in (("elep", "lepton energy"), ("cost", "lepton cos(theta)"),
                     ("q2", "Q2"), ("pprot", "leading proton momentum"),
                     ("ekhad", "hadron kinetic energy")):
        dks, p = ks_two_sample(oa[k], ob[k])
        report(name, "KS D %.4f" % dks, p)

    print("  process fractions (request / stock):")
    for k in sorted(set(oa["proc"]) | set(ob["proc"]), key=str):
        print("    %-6s %.4f / %.4f" % (k, oa["proc"].get(k, 0) / float(len(req)),
                                      ob["proc"].get(k, 0) / float(len(stk))))
    if flagged:
        print("V3: FLAGGED: " + ", ".join(flagged))
        return 1
    print("V3: no test below alpha = %g" % args.alpha)
    return 0


if __name__ == "__main__":
    sys.exit(main())
