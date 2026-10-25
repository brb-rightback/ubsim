#!/usr/bin/env python
"""Validation V5: truth-level comparison of overlay samples after reco2, from
the Wire-Cell trees (wcpselection/T_eval, T_PFeval, T_pot) of the combined
reco tree files.

  extgen_v5_compare.py -s LABEL=FILE[,FILE...] [-s LABEL=FILE ...]
                       [-w LABEL=EXPR] [--channel numuCC|numuNC|nueCC|all]
                       [--all-vertices] [--pdf out.pdf] [-n MAXEVENTS]

The first sample is the reference. Typical use: the ExtGen GiBUU sample
against the HepMC GiBUU production (same physics, different generation
route) and the standard GENIE overlay (same route, different physics).

Selection: the channel (true flavour and current) and, unless
--all-vertices, the true vertex in the active TPC (truth_vtxInside), since
samples differ in generation volume (ExtGen and GENIE: volCryostat).

Per sample: selected events, POT (sum of T_pot pot_tor875good) and events
per 1e20 POT. Per distribution (shapes normalised to the reference): chi2
and Kolmogorov-Smirnov p-values against the reference:
  E_nu; muon momentum and cos(theta) w.r.t. the neutrino; Q2 (CC);
  vertex x, y, z; neutrino time;
  primary final-state multiplicities: protons (KE > 35 MeV), charged pions
  (KE > 0), pi0; leading-proton momentum.
"Primary" = truth_mother == 0 in T_PFeval (the generator's final state as
Geant4 received it). Interaction-mode fractions (truth_nuScatType, GENIE's
scattering type: GENIE and ExtGen samples) are printed for samples that have
them (HepMC samples do not: -1). The interaction time is taken from the
primary particles' start time (truth_startXYZT, BNB spill: 3.125-4.725 us):
truth_nuTime is 0 in HepMC samples, whose particles are timed correctly.
With -n, rates per POT are not printed (T_pot covers the whole files).

-w LABEL=EXPR weights one sample's events, e.g. -w GENIE=weight_cv*weight_spline
for the GENIE tune central value (T_eval branches).

Needs PyROOT (any uboonecode setup, or an LCG view). Works with python 2.7
and 3.
"""
from __future__ import print_function, division

import argparse
import sys

import ROOT

ROOT.gROOT.SetBatch(True)
ROOT.gErrorIgnoreLevel = ROOT.kWarning

M_MU2 = 0.105658 ** 2
M_P = 0.938272

CHANNELS = {
    "numuCC": "truth_nuPdg == 14 && truth_isCC",
    "numuNC": "truth_nuPdg == 14 && !truth_isCC",
    "nueCC": "abs(truth_nuPdg) == 12 && truth_isCC",
    "all": "1",
}

# TTree aliases on T_PFeval (T_eval is a friend). Momenta in GeV, E_nu in MeV.
ALIASES = {
    "Enu": "truth_nuEnergy / 1000.",
    "pmu": "sqrt(truth_muonMomentum[0]**2 + truth_muonMomentum[1]**2 + truth_muonMomentum[2]**2)",
    "pnu": "sqrt(truth_nu_momentum[0]**2 + truth_nu_momentum[1]**2 + truth_nu_momentum[2]**2)",
    "cosmu": "(truth_muonMomentum[0]*truth_nu_momentum[0] + truth_muonMomentum[1]*truth_nu_momentum[1]"
             " + truth_muonMomentum[2]*truth_nu_momentum[2]) / (pmu * pnu)",
    "Q2": "2. * Enu * (truth_muonMomentum[3] - pmu * cosmu) - %g" % M_MU2,
    "prim": "truth_mother == 0",
    "Nprot": "Sum$(prim && truth_pdg == 2212 && truth_startMomentum[][3] > %g)" % (M_P + 0.035),
    "Npic": "Sum$(prim && abs(truth_pdg) == 211)",
    "Npi0": "Sum$(prim && truth_pdg == 111)",
    "Eplead": "Max$((prim && truth_pdg == 2212) * truth_startMomentum[][3])",
    "pplead": "sqrt(max(Eplead * Eplead - %g, 0.))" % (M_P * M_P),
    # all primaries start at the interaction time (us)
    "tprim": "Max$(prim * truth_startXYZT[][3]) / 1000.",
}

# name, expression, extra selection, bins, lo, hi, needs CC
DISTS = [
    ("E_nu [GeV]", "Enu", "1", 40, 0., 4., False),
    ("p_mu [GeV]", "pmu", "1", 40, 0., 3., True),
    ("cos theta_mu", "cosmu", "1", 40, -1., 1., True),
    ("Q2 [GeV2]", "Q2", "1", 40, 0., 2., True),
    ("vertex x [cm]", "truth_vtxX", "1", 26, -1., 255., False),
    ("vertex y [cm]", "truth_vtxY", "1", 24, -116., 116., False),
    ("vertex z [cm]", "truth_vtxZ", "1", 26, 0., 1037., False),
    ("interaction time [us]", "tprim", "1", 44, 2.9, 5.1, False),
    ("N protons (KE>35 MeV)", "min(Nprot, 4)", "1", 5, -0.5, 4.5, False),
    ("N charged pions", "min(Npic, 3)", "1", 4, -0.5, 3.5, False),
    ("N pi0", "min(Npi0, 2)", "1", 3, -0.5, 2.5, False),
    ("leading p momentum [GeV]", "pplead", "Nprot > 0", 30, 0.25, 1.75, False),
]

# truth_nuScatType: GENIE's scattering type from GTruth (ExtGenMerge sets it
# from the external generator's process)
MODES = {1: "QE", 2: "1K", 3: "DIS", 4: "RES", 5: "COH", 10: "MEC"}


def chain(files, tree):
    c = ROOT.TChain("wcpselection/" + tree)
    for f in files:
        c.Add(f)
    return c


def load(label, files, weight, sel, nmax):
    t = chain(files, "T_PFeval")
    friend = chain(files, "T_eval")
    t.AddFriend(friend)
    if t.GetEntries() != friend.GetEntries():
        sys.exit("%s: T_PFeval and T_eval differ in length" % label)
    for k, v in ALIASES.items():
        t.SetAlias(k, v)
    tp = chain(files, "T_pot")
    n = tp.Draw("pot_tor875good", "", "goff")
    pot = sum(tp.GetV1()[i] for i in range(n)) if n > 0 else 0.
    return {"label": label, "tree": t, "keep": [friend, tp], "w": weight, "sel": sel,
            "nmax": nmax if nmax > 0 else ROOT.TTree.kMaxEntries, "pot": pot}


def fill(s, name, expr, extra, nb, lo, hi):
    h = ROOT.TH1D("h%d" % fill.count, name, nb, lo, hi)
    fill.count += 1
    h.Sumw2()
    cut = "(%s) * (%s) * (%s)" % (s["sel"], extra, s["w"])
    s["tree"].Draw("%s >> %s" % (expr, h.GetName()), cut, "goff", s["nmax"])
    return h
fill.count = 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-s", "--sample", action="append", required=True,
                    help="LABEL=FILE[,FILE...] (first: reference)")
    ap.add_argument("-w", "--weight", action="append", default=[], help="LABEL=EXPR")
    ap.add_argument("--channel", default="numuCC", choices=sorted(CHANNELS))
    ap.add_argument("--all-vertices", action="store_true",
                    help="do not require the true vertex in the active TPC")
    ap.add_argument("--pdf", help="overlay plots")
    ap.add_argument("-n", "--max-events", type=int, default=0, help="per sample (tests)")
    args = ap.parse_args()

    weights = dict(w.split("=", 1) for w in args.weight)
    sel = CHANNELS[args.channel]
    if not args.all_vertices:
        sel = "(%s) && truth_vtxInside == 1" % sel
    samples = []
    for spec in args.sample:
        label, _, files = spec.partition("=")
        samples.append(load(label, files.split(","), weights.get(label, "1"), sel,
                            args.max_events))
    cc = args.channel.endswith("CC")

    print("V5 truth comparison, channel %s%s; reference %s"
          % (args.channel, "" if args.all_vertices else ", vertex in active TPC",
             samples[0]["label"]))
    print("%-12s %10s %12s %16s" % ("sample", "events", "POT", "events/1e20 POT"))
    for s in samples:
        h = fill(s, "n", "0", "1", 1, -1., 1.)
        s["n"] = h.GetBinContent(1)
        ok = s["pot"] > 0 and args.max_events <= 0
        rate = s["n"] / s["pot"] * 1e20 if ok else float("nan")
        err = h.GetBinError(1) / s["pot"] * 1e20 if ok else float("nan")
        print("%-12s %10.0f %12.4g %10.1f +- %4.1f%s" % (s["label"], s["n"], s["pot"], rate, err,
              "  (weighted: %s)" % s["w"] if s["w"] != "1" else ""))

    canvas = None
    if args.pdf:
        canvas = ROOT.TCanvas("c", "c", 800, 600)
        canvas.Print(args.pdf + "[")
    colors = [ROOT.kBlack, ROOT.kRed + 1, ROOT.kBlue + 1, ROOT.kGreen + 2, ROOT.kMagenta + 1]
    print("\n%-26s" % "distribution" + "".join("%26s" % ("%s: chi2/ndf (p)  p(KS)" % s["label"])
                                                 for s in samples[1:]))
    for name, expr, extra, nb, lo, hi, needs_cc in DISTS:
        if needs_cc and not cc:
            continue
        hs = [fill(s, name, expr, extra, nb, lo, hi) for s in samples]
        ref = hs[0]
        line = "%-26s" % name
        for h in hs[1:]:
            if ref.Integral() <= 0 or h.Integral() <= 0:
                line += "%26s" % "empty"
                continue
            chi2ndf = ref.Chi2Test(h, "WW CHI2/NDF")
            pchi2 = ref.Chi2Test(h, "WW")
            ks = ref.KolmogorovTest(h)
            line += "%26s" % ("%6.2f (p %7.2g)  %7.2g" % (chi2ndf, pchi2, ks))
        print(line)
        if canvas:
            canvas.Clear()
            leg = ROOT.TLegend(0.65, 0.7, 0.88, 0.88)
            top = 0.
            for i, h in enumerate(hs):
                if h.Integral() > 0:
                    h.Scale(1. / h.Integral())
                h.SetLineColor(colors[i % len(colors)])
                h.SetMarkerColor(colors[i % len(colors)])
                h.SetLineWidth(2)
                top = max(top, h.GetMaximum())
                leg.AddEntry(h, samples[i]["label"], "l")
            for i, h in enumerate(hs):
                h.SetMaximum(1.25 * top)
                h.SetMinimum(0.)
                h.GetXaxis().SetTitle(name)
                h.SetTitle("%s, %s" % (name, args.channel))
                h.Draw("hist e" if i == 0 else "hist e same")
            leg.Draw()
            canvas.Print(args.pdf)
    if canvas:
        canvas.Print(args.pdf + "]")

    print("\ninteraction modes (truth_nuScatType), fraction of selected events:")
    for s in samples:
        h = fill(s, "mode", "truth_nuScatType", "1", 13, -1.5, 11.5)
        tot = h.Integral()
        fr = [(int(round(h.GetBinCenter(b))), h.GetBinContent(b) / tot)
              for b in range(1, h.GetNbinsX() + 1) if h.GetBinContent(b) > 0] if tot > 0 else []
        if fr and fr[0][0] == -1 and fr[0][1] > 0.99:
            print("  %-12s not available (truth_nuScatType = -1)" % s["label"])
            continue
        print("  %-12s %s" % (s["label"], "  ".join("%s %.3f" % (MODES.get(m, str(m)), f)
                                                   for m, f in fr)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
