#!/usr/bin/env python
"""Write a PLACEHOLDER cross section table for testing the ExtGen chain.

The numbers are NOT physics: sigma_CC per nucleon rises linearly from a
crude threshold and sigma_NC = 0.3 sigma_CC. They only exist so that the
GENIE side of the chain (plugin loading, splines, step-A request
generation) can be tested before real GiBUU tables exist.

Default targets: every nucleus in the MicroBooNE geometry
(microboonev12.gdml), with the PDG codes GENIE's ROOTGeomAnalyzer assigns
(A = nearest integer of the GDML element's atomic mass, so nickel is A = 59).
GENIE needs a spline for every nucleus of every material in the WHOLE
geometry (ROOTGeomAnalyzer::BuildListOfTargetNuclei), not only those below
TopVolume, even though only the latter can ever interact.

Output format is the ExtGenPXSec/extgen_make_splines.py table format.
"""
from __future__ import print_function

import argparse

# (Z, A) of every element used in microboonev12.gdml; the first 13 are the
# ones below volCryostat.
GEOMETRY_NUCLEI = [
    (18, 40),  # Ar (LAr, argon gas)
    (26, 56),  # Fe (stainless steel, glass)
    (24, 52),  # Cr (stainless steel)
    (28, 59),  # Ni (stainless steel; GDML A = 58.69)
    (6, 12),   # C  (steel, G10, acrylic)
    (8, 16),   # O  (G10, acrylic, glass)
    (1, 1),    # H  (G10, acrylic)
    (14, 28),  # Si (G10, glass)
    (22, 48),  # Ti (titanium, glass)
    (13, 27),  # Al (glass)
    (20, 40),  # Ca (glass)
    (12, 24),  # Mg (glass)
    (11, 23),  # Na (glass)
    # only outside volCryostat
    (7, 14),   # N  (air, foam)
    (19, 39),  # K  (dirt)
    # ROOT's GDML parser forces Z = 0 for a material named "Vacuum"
    # (TGDMLParse::MatProcess), so GENIE sees MicroBooNE's Vacuum (A = 1.0079)
    # as a free neutron.
    (0, 1),    # free neutron (Vacuum)
]
FLAVOURS = [12, -12, 14, -14]


def ion_pdg(Z, A):
    return 1000000000 + Z * 10000 + A * 10


def sigma_cc_per_nucleon(nu, E):
    """Placeholder only: ~0.7 E (nu) or ~0.35 E (nubar), in 1e-38 cm^2."""
    thr = 0.12 if abs(nu) == 14 else 0.02
    if E <= thr:
        return 0.0
    slope = 0.7 if nu > 0 else 0.35
    return slope * (E - thr)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("output")
    ap.add_argument("--emin", type=float, default=0.01)
    ap.add_argument("--emax", type=float, default=8.0)
    ap.add_argument("--npoints", type=int, default=200)
    args = ap.parse_args()

    ratio = (args.emax / args.emin) ** (1.0 / (args.npoints - 1))
    energies = [args.emin * ratio ** i for i in range(args.npoints)]
    energies[-1] = args.emax

    with open(args.output, "w") as out:
        out.write("# PLACEHOLDER cross sections for ExtGen testing - NOT PHYSICS\n")
        out.write("# nu_pdg current target_pdg E[GeV] sigma[1e-38 cm^2 per nucleus]\n")
        for Z, A in GEOMETRY_NUCLEI:
            for nu in FLAVOURS:
                for cur, scale in (("CC", 1.0), ("NC", 0.3)):
                    for E in energies:
                        s = A * scale * sigma_cc_per_nucleon(nu, E)
                        out.write("%d %s %d %.6g %.6g\n" % (nu, cur, ion_pdg(Z, A), E, s))
    print("Wrote placeholder table for %d nuclei to %s" % (len(GEOMETRY_NUCLEI), args.output))


if __name__ == "__main__":
    main()
