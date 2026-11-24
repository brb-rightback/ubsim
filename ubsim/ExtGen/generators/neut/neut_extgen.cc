// neut_extgen: NEUT's side of MicroBooNE ExtGen (ubsim/ExtGen).
//
// ExtGen lets GENIE choose the neutrino, its energy, the target nucleus and
// the current (CC/NC) from the real flux and geometry, and asks an external
// generator for the final state of each such interaction ("request"). This
// program serves requests with stock NEUT, through NEUT's own interface for
// external drivers (src/generators/geniface, libNEUTGenIFace: initialize,
// total_cross_section_pb_per_target_nuc, simulate_interaction). NEUT itself is
// not changed: this file is compiled against an unmodified NEUT build
// (build_neut.sh).
//
//   neut_extgen -m serve   -c CARD -r requests.txt -s served_events.txt -t trial_stats.txt -S SEED
//   neut_extgen -m xsec    -c CARD -e energies.txt -o table.txt [-n NU,...] [-g TGT,...]
//                          [-b N -B pb_energies.txt]
//   neut_extgen -m convert -i stock.root -s served_events.txt -g TGT -n NU [-C CC|NC]
//   neut_extgen -m info    -c CARD
//
// CARD is the TOML card of extgen_neut_card.sh. It must have rng_seed = "file":
// serve mode writes NEUT's seed file (RANFILE: the seeds of RLUXGO, RM48IN and
// RMARIN, NEUT's three generators) from SEED before NEUT reads the card, so a
// job is reproducible and every job differs. NEUT's C++ models (N1p1h, HT2p2h)
// draw from NEUT's RLU too; NucDeEx (own generator) is not used by this card.
//
// One process serves all requests of a job, whatever their target, neutrino
// and current: NEUT sets the nucleus per call (CommonBlockIFace::SetTargetZA),
// and the current is chosen with NEUT's per-mode scale factors
// (neutcard%crsneut for neutrinos, %crsneutb for antineutrinos), which NEUT
// applies both to its total cross section (fntotpau) and to the mode choice of
// each event (nemodsel). The CC and NC sets of factors are found at start-up
// from NEUT's own mode table (necrsmode, the routine behind the card's
// mode_choice_type = "single"), not hard-coded here, and checked: CC and NC
// together are all modes, sigma_CC + sigma_NC = sigma_total (info mode).
// Requests are served grouped by (target, neutrino, current) to save set-up
// calls; the output order does not matter (ExtGenMerge keys on req_id).
//
// Targets. NEUT's nuclear models do not cover every nucleus of the MicroBooNE
// geometry: Mg24 has no Fermi-gas parameters in NEUT (nesetfgparams stops for
// Z = 12) and neither Mg24 nor K39 has a table of the Nieves 1p1h model
// (N1p1h exits). Their requests are generated on a neighbour (kSubstitutes:
// Mg24 -> Na23, the nearest A; K39 -> Ar40) and their cross sections are the
// neighbour's per nucleon times the requested A. Both are small parts of the
// interactions (cryostat materials); the substitutions are written in every
// output header. Coherent and diffractive modes are switched off on the free
// proton (H1): NEUT computes them per nucleus, GENIE has none there.
// The free neutron (1000000010: ROOT's GDML parser gives the geometry's
// "Vacuum" Z = 0; density 1e-25 g/cm^3, it never interacts) cannot be a NEUT
// target (nrinit fails for A = 1 without a free proton): its table entries are
// an explicit zero (no spline, no events), and a request on it is refused.
// Any other nucleus is refused (exit 2) rather than left to NEUT, which stops
// or exits for unsupported nuclei without an error code.
//
// Served events (ExtGen format, ubsim/ExtGen ExtGenIO.h), per request:
//   EVENT req_id E_GeV gen_proc simb_mode simb_inttype nparts
//   P status pdg px py pz E      (GeV, target rest frame, neutrino along +z)
// gen_proc = NEUT mode (nework%modene, signed); + 1000 * sign for 3p3h (three
// initial nucleons). Particles from NEUT's vector (vcwork) with the status
// rules of NEUT's NuHepMC writer (src/output/NuHepMC/NuHepMCWriter.cc):
//   status 1:  final state (NuHepMC UndecayedPhysical: iflgvc 0/2/10 with
//              icrnvc 1, and the outgoing neutrino of NC events), the primary
//              lepton first;
//   status 11: the initial nucleon (iflgvc -1, index > 0); for 2p2h the two
//              initial nucleons as one cluster, pdg 2000000200 + number of
//              protons, as GENIE does; none for coherent scattering and for
//              3p3h. NEUT writes no nuclear remnant.
// Pauli blocking. NEUT applies Pauli blocking to the nucleon of single-pion
// production after choosing the mode: a blocked event keeps its vector, with
// every outgoing particle flagged "stop" (iflgvc 5, not tracked), and stock
// NEUT writes it like any other event; it has no final state, so what stock
// NEUT predicts is sigma_total x (1 - f_PB), f_PB the blocked fraction. ExtGen
// does the same: the spline is NEUT's sigma x (1 - f_PB) (xsec mode, f_PB
// measured with NEUT events on a coarse energy grid and interpolated), and in
// serving a blocked event (no primary lepton among the final particles) is a
// trial without an event: dropped (n_dropped), and NEUT is called again.
// NEUT's vector-generation failures (nevect error code) are retried and not
// counted, as stock NEUT's main loop does.
//
// Trial statistics (for the in-job cross-section check against the splines):
//   req_id tgt_pdg nu_pdg ccnc E_GeV n_trials sum_w sum_w2 max_w n_dropped
// per NEUT event (trial), w = NEUT's total cross section of the request's
// current at its energy (1e-38 cm^2 per nucleus) if the event is served and 0
// if dropped, so sum_w / n_trials estimates sigma x (1 - f_PB), the spline.
//
// Cross-section table (xsec mode), the input of extgen_make_splines.py and of
// the in-job check (extgen_gibuu_xsec_check.sh, which reads rel_err):
//   nu_pdg CC|NC target_pdg E_GeV sigma[1e-38 cm^2 per nucleus]   # rel_err sigma_NEUT f_PB
// with sigma = sigma_NEUT x (1 - f_PB). -b N events at each energy of the grid
// -B give f_PB (0: no correction); the table's own grid is -e. rel_err is the
// uncertainty of sigma as the check uses it, linearly interpolated between
// table energies: the statistical error of f_PB, relative to (1 - f_PB), and
// the interpolation error, |sigma_NEUT at the midpoint of a neighbouring
// interval - the interpolation there| / sigma_NEUT (the larger of the two
// neighbouring intervals), and 1e-6, the precision of NEUT's cross section,
// which it computes in single precision, added in quadrature. NEUT's
// sigma_NEUT itself has no statistical error (no Monte Carlo).
//
// Convert mode (validation only) writes the events of a stock neutroot2 run
// (neuttree, NeutVect) in the served format with the same status rules
// (req_id = entry, E_GeV = the neutrino energy), for comparisons with served
// events (extgen_neut_v3.sh).
//
// Floating-point traps: NEUT's libNEUTsmpl (linked as by stock NEUT) enables
// traps for invalid operations, division by zero and overflow when it is
// loaded (trapfpe.c), as in stock neutroot2; this program's own arithmetic
// must not raise them either.
//
// Exit codes: 0 ok, 2 bad input or configuration, 4 NEUT failure (a crash prints
// a backtrace).

#include <algorithm>
#include <array>
#include <csignal>
#include <execinfo.h>
#include <unistd.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <tuple>
#include <vector>

#include "neutgen.h"
#include "CommonBlockIFace.h"
#include "necard.h"
#include "nework.h"
#include "vcwork.h"

#ifdef NEUT_EXTGEN_CONVERT
#include "TFile.h"
#include "TTree.h"
#include "neutvect.h"
#include "neutpart.h"
#endif

#ifndef NEUT_EXTGEN_VERSION
#define NEUT_EXTGEN_VERSION "unknown"
#endif

extern "C" {
void necrsmode_(int* ipar, int* mode);
}

namespace {

const char* kProg = "neut_extgen";
const long kMaxTrials = 100000;   // NEUT calls per request
// relative precision of NEUT's total cross section (single precision, float):
// a floor of the tables' rel_err (see the header)
const double kSigmaPrecision = 1e-6;

void die(const std::string& msg, int code = 2)
{
  std::cerr << kProg << ": ERROR: " << msg << std::endl;
  std::exit(code);
}

// --- targets ---------------------------------------------------------------

int PdgZ(int pdg) { return (pdg / 10000) % 1000; }
int PdgA(int pdg) { return (pdg / 10) % 1000; }

// Nuclei generated as they are: those of the MicroBooNE geometry that NEUT's
// models (Fermi-gas parameters, Nieves 1p1h tables, 2p2h tensors) cover.
const std::set<int> kDirect = {
  1000010010,   // H1 (free proton)
  1000060120, 1000070140, 1000080160, 1000110230, 1000130270, 1000140280,
  1000180400, 1000200400, 1000220480, 1000240520, 1000260560, 1000280590};

// requested nucleus -> the nucleus NEUT generates on (see the header)
const std::map<int, int> kSubstitutes = {
  {1000120240, 1000110230},   // Mg24 -> Na23 (nearest A; no Mg in NEUT)
  {1000190390, 1000180400}};  // K39  -> Ar40 (no Nieves 1p1h table for A = 39)

// zero cross section (see the header)
const std::set<int> kZero = {1000000010};   // free neutron ("Vacuum")

int GenTarget(int pdg)
{
  if (kZero.count(pdg))
    die("target " + std::to_string(pdg) + " (free neutron, the geometry's Vacuum) has a zero "
        "cross section in the NEUT tables: no request can be made on it");
  if (kDirect.count(pdg)) return pdg;
  auto it = kSubstitutes.find(pdg);
  if (it != kSubstitutes.end()) return it->second;
  die("target " + std::to_string(pdg) + " is not supported by the ExtGen NEUT setup "
      "(neither generated directly nor substituted; see neut_extgen.cc)");
  return 0;
}

std::string SubstitutionList()
{
  std::string s;
  for (auto const& kv : kSubstitutes)
    s += (s.empty() ? "" : ",") + std::to_string(kv.first) + ":" + std::to_string(kv.second);
  return s;
}

// --- modes -------------------------------------------------------------------

// NEUT modes (absolute values) of each current (NEUT's mode numbering,
// src/models/common/necrsmode.F and neutmodesCPP.h)
const std::vector<int> kModesCC = {1, 2, 11, 12, 13, 15, 16, 17, 21, 22, 23, 26};
const std::vector<int> kModesNC = {31, 32, 33, 34, 35, 36, 38, 39, 41, 42, 43, 44, 45, 46, 51, 52};
const std::vector<int> kModesSingleNucleonOff = {15, 16, 35, 36};   // diffractive, coherent

int SimbMode(int mode)
{
  switch (std::abs(mode)) {
    case 1: case 51: case 52: return 0;                     // kQE
    case 2: return 10;                                      // kMEC
    case 11: case 12: case 13: case 17: case 22: case 23:   // single pi, gamma, eta, K
    case 31: case 32: case 33: case 34: case 38: case 39:
    case 42: case 43: case 44: case 45: return 1;           // kRes
    case 21: case 26: case 41: case 46: return 2;           // kDIS (multi-pi, DIS)
    case 16: case 36: return 3;                             // kCoh
    case 15: case 35: return 11;                            // kDiffractive
  }
  return -1;
}

// GENIE2ART interaction types (kNuanceOffset + NUANCE code); resonances,
// MEC and diffractive 1000, as for NuWro (nuwro_extgen.cc)
int SimbIntType(int mode)
{
  switch (std::abs(mode)) {
    case 1: return 1001;                     // kCCQE
    case 51: case 52: return 1002;           // kNCQE
    case 21: case 26: return 1091;           // kCCDIS
    case 41: case 46: return 1092;           // kNCDIS
    case 16: return 1097;                    // kCCCOH
    case 36: return 1096;                    // kNCCOH
  }
  return 1000;
}

// --- the per-mode scale factors of each current -------------------------------

struct ModeMasks {
  // [sign: 0 nu, 1 nubar][current: 0 CC, 1 NC][index]
  bool on[2][2][30] = {};
  // [sign][index]: modes off on single nucleons
  bool singleNucleonOff[2][30] = {};
  float base[2][30] = {};   // the card's factors (mode_rescaling)
};

ModeMasks FindMasks()
{
  ModeMasks m;
  const auto saved = FortMod::neutcardIF::copy();
  for (int i = 0; i < 30; ++i) {
    m.base[0][i] = saved.crsneut[i];
    m.base[1][i] = saved.crsneutb[i];
  }
  auto mark = [&](int mode, int sign, bool* dst) {
    int ipar = sign == 0 ? 14 : -14;
    int md = mode;
    necrsmode_(&ipar, &md);
    const auto c = FortMod::neutcardIF::copy();
    const float* f = sign == 0 ? c.crsneut : c.crsneutb;
    int n = 0;
    for (int i = 0; i < 30; ++i)
      if (f[i] > 0) { dst[i] = true; ++n; }
    if (n == 0) die("NEUT mode " + std::to_string(mode) + " sets no scale factor");
    FortMod::neutcardIF::update(saved);
  };
  for (int s = 0; s < 2; ++s) {
    for (int mode : kModesCC) mark(mode, s, m.on[s][0]);
    for (int mode : kModesNC) mark(mode, s, m.on[s][1]);
    for (int mode : kModesSingleNucleonOff) mark(mode, s, m.singleNucleonOff[s]);
    for (int i = 0; i < 30; ++i)
      if (m.on[s][0][i] && m.on[s][1][i])
        die("NEUT scale factor " + std::to_string(i + 1) + " belongs to both currents");
  }
  FortMod::neutcardIF::update(saved);
  return m;
}

// sets NEUT's factors for (neutrino sign, current, single nucleon?);
// cur: 0 CC, 1 NC, -1 all (the card's own factors)
void SetCurrent(const ModeMasks& m, int cur, bool singleNucleon)
{
  auto c = FortMod::neutcardIF::copy();
  for (int s = 0; s < 2; ++s) {
    float* f = s == 0 ? c.crsneut : c.crsneutb;
    for (int i = 0; i < 30; ++i) {
      bool on = cur < 0 ? (m.on[s][0][i] || m.on[s][1][i]) : m.on[s][cur][i];
      if (singleNucleon && m.singleNucleonOff[s][i]) on = false;
      f[i] = on ? m.base[s][i] : 0.f;
    }
  }
  FortMod::neutcardIF::update(c);
}

// NEUT's total cross section in 1e-38 cm^2 per nucleus of the requested
// target (substitutes: per nucleon of the generated one times requested A).
// The factors of the current must be set (SetCurrent).
double SigmaPerNucleus(int nuPdg, double eGeV, int reqTgt)
{
  const int gen = GenTarget(reqTgt);
  const float pb = neut::gen::total_cross_section_pb_per_target_nuc(
      nuPdg, (float)eGeV, PdgZ(gen), PdgA(gen));
  return pb * 1e-36 / 1e-38 * PdgA(reqTgt);   // pb per nucleon -> 1e-38 cm^2 per nucleus
}

// --- events --------------------------------------------------------------------

struct OutParticle {
  int status, pdg;
  double px, py, pz, E;   // GeV
};

struct VecParticle {   // one entry of NEUT's vector (vcwork, NeutVect)
  int pdg, iflg, icrn;
  double px, py, pz, m;   // MeV
};

bool IsNeutrino(int pdg) { int a = std::abs(pdg); return a == 12 || a == 14 || a == 16; }

// NEUT's final-state rule (NuHepMCWriter BuildEvent): true for UndecayedPhysical
bool IsFinal(const VecParticle& p, int i, int mode)
{
  const int am = std::abs(mode);
  if (am == 15 || am == 35) return i >= 2;   // diffractive: NuHepMCWriter's special case
  switch (p.iflg) {
    case 0: case 2: return p.icrn ? true : IsNeutrino(p.pdg);
    case 10: return p.icrn != 0;
  }
  return false;
}

OutParticle Out(int status, int pdg, double px, double py, double pz, double m)
{
  const double E = std::sqrt(px * px + py * py + pz * pz + m * m);
  return {status, pdg, px / 1000., py / 1000., pz / 1000., E / 1000.};
}

// builds the served particles of one NEUT event; false if the primary lepton
// is missing. genProc gets NEUT's mode (+-1000 for 3p3h).
bool BuildEvent(const std::vector<VecParticle>& v, int mode, int leptonPdg,
                std::vector<OutParticle>& out, int& genProc)
{
  out.clear();
  const int am = std::abs(mode);
  // initial nucleons
  std::vector<int> init;
  for (size_t i = 1; i < v.size(); ++i)
    if (v[i].iflg == -1 && (v[i].pdg == 2212 || v[i].pdg == 2112)) init.push_back(i);
  if (am == 15 || am == 35) {   // diffractive: index 1 is the (free) target nucleon
    init.clear();
    if (v.size() > 1 && (v[1].pdg == 2212 || v[1].pdg == 2112)) init.push_back(1);
  }
  genProc = mode;
  if (am == 16 || am == 36) {
    // coherent: no struck nucleon
  } else if (init.size() == 1) {
    const auto& p = v[init[0]];
    out.push_back(Out(11, p.pdg, p.px, p.py, p.pz, p.m));
  } else if (init.size() == 2) {   // 2p2h: the pair as one cluster, as GENIE
    const auto& a = v[init[0]];
    const auto& b = v[init[1]];
    const int np = (a.pdg == 2212) + (b.pdg == 2212);
    const double ea = std::sqrt(a.px * a.px + a.py * a.py + a.pz * a.pz + a.m * a.m);
    const double eb = std::sqrt(b.px * b.px + b.py * b.py + b.pz * b.pz + b.m * b.m);
    out.push_back({11, 2000000200 + np, (a.px + b.px) / 1000., (a.py + b.py) / 1000.,
                   (a.pz + b.pz) / 1000., (ea + eb) / 1000.});
  } else if (init.size() == 3) {   // 3p3h: no status-11 particle (as NuWro)
    genProc = mode + (mode > 0 ? 1000 : -1000);
  }
  // final state, primary lepton first
  int iLep = -1;
  for (size_t i = 1; i < v.size(); ++i)
    if (v[i].pdg == leptonPdg && IsFinal(v[i], i, mode)) { iLep = i; break; }
  if (iLep < 0) return false;
  out.push_back(Out(1, v[iLep].pdg, v[iLep].px, v[iLep].py, v[iLep].pz, v[iLep].m));
  for (size_t i = 1; i < v.size(); ++i)
    if ((int)i != iLep && IsFinal(v[i], i, mode))
      out.push_back(Out(1, v[i].pdg, v[i].px, v[i].py, v[i].pz, v[i].m));
  return true;
}

void WriteEvent(FILE* f, long reqId, double eGeV, int genProc, int mode,
                const std::vector<OutParticle>& parts)
{
  std::fprintf(f, "EVENT %ld %.17g %d %d %d %zu\n", reqId, eGeV, genProc, SimbMode(mode),
               SimbIntType(mode), parts.size());
  for (auto const& q : parts)
    std::fprintf(f, "P %d %d %.17g %.17g %.17g %.17g\n", q.status, q.pdg, q.px, q.py, q.pz, q.E);
}

std::vector<VecParticle> CurrentVector()
{
  const auto vc = FortMod::vcworkIF::copy();
  std::vector<VecParticle> v;
  for (int i = 0; i < vc.nvc; ++i)
    v.push_back({vc.ipvc[i], vc.iflgvc[i], vc.icrnvc[i], vc.pvc[i][0], vc.pvc[i][1],
                 vc.pvc[i][2], vc.amasvc[i]});
  return v;
}

int LeptonPdg(int nuPdg, bool cc) { return cc ? (nuPdg > 0 ? nuPdg - 1 : nuPdg + 1) : nuPdg; }

// --- requests ------------------------------------------------------------------

struct Request {
  long id;
  int nuPdg;
  bool cc;
  int tgtPdg;
  double E;          // GeV, as read (written back unchanged)
  std::string Estr;
};

std::vector<Request> ReadRequests(const std::string& path)
{
  std::ifstream in(path.c_str());
  if (!in) die("cannot read " + path);
  std::vector<Request> reqs;
  std::set<long> ids;
  std::string line;
  long lineNo = 0;
  while (std::getline(in, line)) {
    ++lineNo;
    if (line.empty() || line[0] == '#') continue;
    std::istringstream ss(line);
    Request r;
    unsigned long run, sub, evt, tidx;
    std::string cur;
    if (!(ss >> r.id >> run >> sub >> evt >> tidx >> r.nuPdg >> cur >> r.tgtPdg >> r.Estr))
      die(path + ":" + std::to_string(lineNo) + ": expected 'req_id run subrun event truth_idx "
          "nu_pdg CC|NC tgt_pdg E_GeV ...'");
    r.E = std::strtod(r.Estr.c_str(), nullptr);
    if (cur != "CC" && cur != "NC") die(path + ":" + std::to_string(lineNo) + ": current " + cur);
    r.cc = cur == "CC";
    if (!(r.E > 0)) die(path + ":" + std::to_string(lineNo) + ": energy must be positive");
    const int a = std::abs(r.nuPdg);
    if (a != 12 && a != 14) die(path + ":" + std::to_string(lineNo) + ": neutrino " +
                                std::to_string(r.nuPdg) + " (12, -12, 14, -14 only)");
    GenTarget(r.tgtPdg);   // refuses unsupported nuclei
    if (!ids.insert(r.id).second) die(path + ": duplicate req_id " + std::to_string(r.id));
    reqs.push_back(r);
  }
  if (reqs.empty()) die(path + ": no requests");
  return reqs;
}

// --- set-up ----------------------------------------------------------------------

void WriteSeedFile(long seed, const std::string& path)
{
  // NEUT's seed file (nerdseed.F): ISEED1 (RLUXGO) ISEED2 (RM48IN) ISTAU1
  // ISTAU2 ISTAU3 (RMARIN, Tauola). Seeds within each generator's range
  // (RANLUX: 1..2^31-1; RM48/RMARIN: 0..900000000), different per generator.
  FILE* f = std::fopen(path.c_str(), "w");
  if (!f) die("cannot write " + path);
  const long s1 = seed;
  const long s2 = (seed * 7 + 1234567) % 900000000;
  const long s3 = (seed * 13 + 7654321) % 900000000;
  std::fprintf(f, "%ld %ld %ld 0 0\n", s1, s2, s3);
  std::fclose(f);
  setenv("RANFILE", path.c_str(), 1);
}

void InitNEUT(const std::string& card)
{
  if (!neut::gen::initialize(card)) die("NEUT could not read the card " + card, 4);
  const auto c = FortMod::neutcardIF::copy();
  std::cout << kProg << ": NEUT initialised from " << card << " (rng_seed " << c.rng_seed
            << ")" << std::endl;
}

std::string Join(const bool* on)
{
  std::string s;
  for (int i = 0; i < 30; ++i)
    if (on[i]) s += (s.empty() ? "" : ",") + std::to_string(i + 1);
  return s;
}

// --- modes of operation --------------------------------------------------------------

void Info(const ModeMasks& m)
{
  for (int s = 0; s < 2; ++s)
    for (int c = 0; c < 2; ++c)
      std::cout << (s ? "nubar " : "nu    ") << (c ? "NC" : "CC") << " factors: "
                << Join(m.on[s][c]) << std::endl;
  std::cout << "single-nucleon off: nu " << Join(m.singleNucleonOff[0]) << ", nubar "
            << Join(m.singleNucleonOff[1]) << std::endl;
  std::cout << "substitutions: " << SubstitutionList() << std::endl;
  // check: sigma_CC + sigma_NC = sigma_all
  std::printf("%-6s %-11s %6s %12s %12s %12s %9s\n", "nu", "target", "E", "CC", "NC", "all",
              "CC+NC/all");
  for (int nu : {14, -14, 12, -12})
    for (int tgt : {1000180400, 1000060120, 1000010010, 1000260560})
      for (double e : {0.3, 1.0, 3.0}) {
        const bool single = PdgA(GenTarget(tgt)) == 1;
        SetCurrent(m, 0, single);
        const double cc = SigmaPerNucleus(nu, e, tgt);
        SetCurrent(m, 1, single);
        const double nc = SigmaPerNucleus(nu, e, tgt);
        SetCurrent(m, -1, single);
        const double all = SigmaPerNucleus(nu, e, tgt);
        std::printf("%-6d %-11d %6.2f %12.6g %12.6g %12.6g %9.6f\n", nu, tgt, e, cc, nc, all,
                    all > 0 ? (cc + nc) / all : 0.);
      }
}

std::vector<std::string> ReadEnergies(const std::string& path)
{
  std::vector<std::string> es;
  std::ifstream in(path.c_str());
  if (!in) die("cannot read " + path);
  std::string w;
  while (in >> w) {
    if (w[0] == '#') { std::getline(in, w); continue; }
    if (!(std::strtod(w.c_str(), nullptr) > 0)) die(path + ": bad energy " + w);
    es.push_back(w);
  }
  if (es.empty()) die(path + ": no energies");
  for (size_t i = 1; i < es.size(); ++i)
    if (!(std::strtod(es[i].c_str(), nullptr) > std::strtod(es[i - 1].c_str(), nullptr)))
      die(path + ": energies must increase");
  return es;
}

// fraction of NEUT events without final state (Pauli blocked, see the header)
// at energy eGeV, from n events; the current's factors must be set
double BlockedFraction(int nuPdg, bool cc, double eGeV, int reqTgt, long n)
{
  const int gen = GenTarget(reqTgt);
  const int lep = LeptonPdg(nuPdg, cc);
  long blocked = 0, errs = 0;
  std::vector<OutParticle> parts;
  for (long i = 0; i < n; ) {
    const int err = neut::gen::simulate_interaction(nuPdg, {0.f, 0.f, (float)eGeV}, PdgZ(gen),
                                                    PdgA(gen));
    if (err != 0) {
      if (++errs > 100 * n) die("too many NEUT failures in the blocking estimate", 4);
      continue;
    }
    int genProc = 0;
    if (!BuildEvent(CurrentVector(), FortMod::neworkIF::copy().modene, lep, parts, genProc))
      ++blocked;
    ++i;
  }
  return double(blocked) / n;
}

void Xsec(const ModeMasks& m, const std::string& ePath, const std::string& outPath,
          const std::vector<int>& nus, const std::vector<int>& tgts, const std::string& card,
          long nPB, const std::string& pbPath)
{
  const auto es = ReadEnergies(ePath);
  std::vector<std::string> pbEs;
  if (nPB > 0) pbEs = ReadEnergies(pbPath);
  FILE* out = std::fopen(outPath.c_str(), "w");
  if (!out) die("cannot write " + outPath);
  std::fprintf(out, "# NEUT total cross sections (neut_extgen -m xsec), version %s, card %s\n",
               NEUT_EXTGEN_VERSION, card.c_str());
  std::fprintf(out, "# substitutions (requested:generated, per nucleon x requested A): %s\n",
               SubstitutionList().c_str());
  std::fprintf(out, "# zero (not a NEUT target): 1000000010 (free neutron, the geometry's Vacuum)\n");
  if (nPB > 0)
    std::fprintf(out, "# Pauli blocking: sigma = sigma_NEUT x (1 - f_PB), f_PB from %ld NEUT events "
                      "at each energy of %s, linear in E between them (constant beyond)\n",
                 nPB, pbPath.c_str());
  else
    std::fprintf(out, "# Pauli blocking: not applied (f_PB = 0)\n");
  std::fprintf(out, "# nu_pdg CC|NC target_pdg E_GeV sigma[1e-38 cm^2 per nucleus]   # rel_err sigma_NEUT f_PB\n");
  for (int nu : nus)
    for (int c = 0; c < 2; ++c)
      for (int tgt : tgts) {
        if (kZero.count(tgt)) {
          for (auto const& e : es)
            std::fprintf(out, "%d %s %d %s 0   # 0 0 0 zero: not a NEUT target\n", nu,
                         c ? "NC" : "CC", tgt, e.c_str());
          continue;
        }
        const bool single = PdgA(GenTarget(tgt)) == 1;
        SetCurrent(m, c, single);
        // f_PB and its statistical error on the blocking grid (none on a free
        // proton: no nucleus, no blocking)
        std::vector<double> fe, ff, fv;
        for (auto const& e : pbEs) {
          const double E = std::strtod(e.c_str(), nullptr);
          double f = 0;
          if (!single && SigmaPerNucleus(nu, E, tgt) > 0) f = BlockedFraction(nu, c == 0, E, tgt, nPB);
          fe.push_back(E);
          ff.push_back(f);
          fv.push_back(f * (1 - f) / nPB);
        }
        auto interpPB = [&](double E, const std::vector<double>& y) {
          if (fe.empty()) return 0.;
          if (E <= fe.front()) return y.front();
          if (E >= fe.back()) return y.back();
          size_t k = 1;
          while (fe[k] < E) ++k;
          const double t = (E - fe[k - 1]) / (fe[k] - fe[k - 1]);
          return (1 - t) * y[k - 1] + t * y[k];   // exactly y[k] at t = 1
        };
        // sigma_NEUT at the table energies and at the midpoints between them
        const size_t ne = es.size();
        std::vector<double> E(ne), sig(ne), interpErr(ne, 0.);
        for (size_t i = 0; i < ne; ++i) {
          E[i] = std::strtod(es[i].c_str(), nullptr);
          sig[i] = SigmaPerNucleus(nu, E[i], tgt);
        }
        for (size_t i = 0; i + 1 < ne; ++i) {
          const double mid = SigmaPerNucleus(nu, 0.5 * (E[i] + E[i + 1]), tgt);
          const double lin = 0.5 * (sig[i] + sig[i + 1]);
          const double rel = mid > 0 ? std::fabs(mid - lin) / mid : 0.;
          interpErr[i] = std::max(interpErr[i], rel);
          interpErr[i + 1] = std::max(interpErr[i + 1], rel);
        }
        for (size_t i = 0; i < ne; ++i) {
          const double f = interpPB(E[i], ff);
          // (NEUT enables floating-point traps, so no sqrt of a rounding -0)
          const double ef = std::sqrt(std::max(0., interpPB(E[i], fv)));
          const double relPB = f < 1 ? ef / (1 - f) : 0.;
          const double rel = std::sqrt(relPB * relPB + interpErr[i] * interpErr[i] +
                                       kSigmaPrecision * kSigmaPrecision);
          std::fprintf(out, "%d %s %d %s %.8g   # %.6f %.8g %.5f\n", nu, c ? "NC" : "CC", tgt,
                       es[i].c_str(), sig[i] * (1 - f), rel, sig[i], f);
        }
        std::fflush(out);
        std::cout << kProg << ": xsec nu " << nu << (c ? " NC" : " CC") << " target " << tgt
                  << " done" << std::endl;
      }
  if (std::fclose(out) != 0) die("error writing " + outPath);
}

void Serve(const ModeMasks& m, std::vector<Request> reqs, const std::string& reqPath,
           const std::string& evPath, const std::string& statPath, long seed,
           const std::string& card)
{
  FILE* ev = std::fopen(evPath.c_str(), "w");
  if (!ev) die("cannot write " + evPath);
  FILE* ts = std::fopen(statPath.c_str(), "w");
  if (!ts) die("cannot write " + statPath);
  std::fprintf(ev, "# extgen-served v1 generator=NEUT version=%s requests=%s card=%s seed=%ld "
                   "substitutions=%s\n",
               NEUT_EXTGEN_VERSION, reqPath.c_str(), card.c_str(), seed,
               SubstitutionList().c_str());
  std::fprintf(ev, "# EVENT req_id E_GeV gen_proc simb_mode simb_inttype nparts\n");
  std::fprintf(ev, "# P status pdg px py pz E   (GeV, neutrino along +z)\n");
  std::fprintf(ev, "# gen_proc = NEUT mode (+-1000: 3p3h)\n");
  std::fprintf(ts, "# extgen-trial-stats v1 generator=NEUT\n");
  std::fprintf(ts, "# req_id tgt_pdg nu_pdg ccnc E_GeV n_trials sum_w sum_w2 max_w n_dropped"
                   "   (w: 1e-38 cm^2 per nucleus)\n");
  std::stable_sort(reqs.begin(), reqs.end(), [](const Request& a, const Request& b) {
    return std::make_tuple(a.tgtPdg, a.nuPdg, !a.cc) < std::make_tuple(b.tgtPdg, b.nuPdg, !b.cc);
  });
  long nErr = 0, nDropTot = 0;
  int curTgt = 0, curNu = 0, curCC = -1;
  std::map<int, long> modeCount;
  for (auto const& r : reqs) {
    const int gen = GenTarget(r.tgtPdg);
    if (r.tgtPdg != curTgt || r.nuPdg != curNu || (int)r.cc != curCC) {
      SetCurrent(m, r.cc ? 0 : 1, PdgA(gen) == 1);
      curTgt = r.tgtPdg; curNu = r.nuPdg; curCC = r.cc;
    }
    const double sigma = SigmaPerNucleus(r.nuPdg, r.E, r.tgtPdg);
    if (!(sigma > 0))
      die("request " + std::to_string(r.id) + ": NEUT cross section " + std::to_string(sigma) +
          " for nu " + std::to_string(r.nuPdg) + (r.cc ? " CC" : " NC") + " on " +
          std::to_string(r.tgtPdg) + " at " + r.Estr + " GeV (GENIE chose it with the splines: "
          "card or tables do not match)", 4);
    const int lep = LeptonPdg(r.nuPdg, r.cc);
    long n = 0, nDrop = 0, nErrReq = 0;
    bool served = false;
    std::vector<OutParticle> parts;
    while (!served) {
      if (++n > kMaxTrials)
        die("request " + std::to_string(r.id) + ": no event in " + std::to_string(kMaxTrials) +
            " NEUT calls", 4);
      const int err = neut::gen::simulate_interaction(
          r.nuPdg, {0.f, 0.f, (float)r.E}, PdgZ(gen), PdgA(gen));
      if (err != 0) {   // as stock NEUT: try again (not a trial)
        ++nErr; --n;
        if (++nErrReq > kMaxTrials)
          die("request " + std::to_string(r.id) + ": " + std::to_string(kMaxTrials) +
              " NEUT failures (nevect error code)", 4);
        continue;
      }
      const auto nw = FortMod::neworkIF::copy();
      int genProc = 0;
      if (!BuildEvent(CurrentVector(), nw.modene, lep, parts, genProc)) {
        if (std::getenv("NEUT_EXTGEN_DEBUG")) {   // the NEUT vector of a dropped event
          std::cerr << kProg << ": dropped (no lepton " << lep << ") request " << r.id << " mode "
                    << nw.modene << " target " << gen << "\n";
          for (auto const& p : CurrentVector())
            std::cerr << "    pdg " << p.pdg << " iflg " << p.iflg << " icrn " << p.icrn << " p ("
                      << p.px << ", " << p.py << ", " << p.pz << ") m " << p.m << "\n";
        }
        ++nDrop;
        continue;
      }
      const bool modeCC = std::abs(nw.modene) < 30;
      if (modeCC != r.cc)
        die("request " + std::to_string(r.id) + ": NEUT made mode " +
            std::to_string(nw.modene) + " for a " + (r.cc ? "CC" : "NC") + " request", 4);
      WriteEvent(ev, r.id, r.E, genProc, nw.modene, parts);
      ++modeCount[nw.modene];
      served = true;
    }
    nDropTot += nDrop;
    const long nServed = n - nDrop;   // = 1; w = sigma for it, 0 for the dropped trials
    std::fprintf(ts, "%ld %d %d %s %s %ld %.17g %.17g %.17g %ld\n", r.id, r.tgtPdg, r.nuPdg,
                 r.cc ? "CC" : "NC", r.Estr.c_str(), n, nServed * sigma, nServed * sigma * sigma,
                 sigma, nDrop);
  }
  if (std::fclose(ev) != 0) die("error writing " + evPath);
  if (std::fclose(ts) != 0) die("error writing " + statPath);
  std::cout << kProg << ": served " << reqs.size() << " requests (" << nErr
            << " NEUT retries, " << nDropTot << " Pauli-blocked events dropped); modes:";
  for (auto const& kv : modeCount) std::cout << " " << kv.first << ":" << kv.second;
  std::cout << std::endl;
}

#ifdef NEUT_EXTGEN_CONVERT
void Convert(const std::string& inPath, const std::string& evPath, int tgt, int nu, int onlyCur)
{
  TFile f(inPath.c_str());
  TTree* t = f.IsOpen() ? (TTree*)f.Get("neuttree") : nullptr;
  if (!t) die("no neuttree in " + inPath);
  NeutVect* nv = nullptr;
  t->SetBranchAddress("vectorbranch", &nv);
  FILE* ev = std::fopen(evPath.c_str(), "w");
  if (!ev) die("cannot write " + evPath);
  std::fprintf(ev, "# extgen-served v1 generator=NEUT-stock version=%s file=%s tgt_pdg=%d "
                   "nu_pdg=%d\n", NEUT_EXTGEN_VERSION, inPath.c_str(), tgt, nu);
  std::fprintf(ev, "# EVENT req_id E_GeV gen_proc simb_mode simb_inttype nparts\n");
  std::fprintf(ev, "# P status pdg px py pz E   (GeV, neutrino along +z)\n");
  const long n = t->GetEntries();
  long written = 0, dropped = 0, other = 0;
  std::vector<OutParticle> parts;
  for (long i = 0; i < n; ++i) {
    t->GetEntry(i);
    const bool cc = std::abs(nv->Mode) < 30;
    if ((onlyCur == 0 && !cc) || (onlyCur == 1 && cc)) { ++other; continue; }
    std::vector<VecParticle> v;
    for (int k = 0; k < nv->Npart(); ++k) {
      const NeutPart* p = nv->PartInfo(k);
      v.push_back({p->fPID, p->fStatus, (int)p->fIsAlive, p->fP.X(), p->fP.Y(), p->fP.Z(),
                   p->fMass});
    }
    if (v.empty() || v[0].pdg != nu) die("entry " + std::to_string(i) + " has no neutrino " +
                                         std::to_string(nu));
    const double eGeV = std::sqrt(v[0].px * v[0].px + v[0].py * v[0].py + v[0].pz * v[0].pz) / 1000.;
    int genProc = 0;
    if (!BuildEvent(v, nv->Mode, LeptonPdg(nu, cc), parts, genProc)) { ++dropped; continue; }
    WriteEvent(ev, i, eGeV, genProc, nv->Mode, parts);
    ++written;
  }
  std::fclose(ev);
  std::cout << kProg << ": converted " << written << " of " << n << " entries (" << dropped
            << " without lepton, " << other << " of the other current)" << std::endl;
}
#endif

// a crash or floating-point trap (SIGFPE, SIGSEGV, SIGBUS): print where, exit 4
void CrashHandler(int sig)
{
  const char msg[] = "neut_extgen: ERROR: fatal signal (floating-point trap or crash), backtrace:\n";
  if (write(2, msg, sizeof msg - 1) < 0) {}
  void* frames[64];
  const int n = backtrace(frames, 64);
  backtrace_symbols_fd(frames, n, 2);
  std::signal(sig, SIG_DFL);
  _exit(4);
}

std::vector<int> IntList(const std::string& s)
{
  std::vector<int> v;
  std::stringstream ss(s);
  std::string w;
  while (std::getline(ss, w, ',')) v.push_back(std::atoi(w.c_str()));
  return v;
}

}  // namespace

int main(int argc, char** argv)
{
  for (int sig : {SIGFPE, SIGSEGV, SIGBUS}) std::signal(sig, CrashHandler);
  std::string mode, card, reqPath, evPath, statPath, ePath, outPath, inPath, cur;
  std::string nuList = "14,-14,12,-12", tgtList, pbPath;
  long seed = -1, nPB = 0;
  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    if (i + 1 >= argc) die("option " + a + " needs a value");
    const std::string v = argv[++i];
    if (a == "-m") mode = v;
    else if (a == "-c") card = v;
    else if (a == "-r") reqPath = v;
    else if (a == "-s") evPath = v;
    else if (a == "-t") statPath = v;
    else if (a == "-S") seed = std::atol(v.c_str());
    else if (a == "-e") ePath = v;
    else if (a == "-o") outPath = v;
    else if (a == "-n") nuList = v;
    else if (a == "-g") tgtList = v;
    else if (a == "-i") inPath = v;
    else if (a == "-C") cur = v;
    else if (a == "-b") nPB = std::atol(v.c_str());
    else if (a == "-B") pbPath = v;
    else die("unknown option " + a + " (see neut_extgen.cc)");
  }

  if (mode == "convert") {
#ifdef NEUT_EXTGEN_CONVERT
    if (inPath.empty() || evPath.empty() || tgtList.empty()) die("convert needs -i, -s and -g");
    const int onlyCur = cur == "CC" ? 0 : cur == "NC" ? 1 : -1;
    Convert(inPath, evPath, std::atoi(tgtList.c_str()), std::atoi(nuList.c_str()), onlyCur);
    return 0;
#else
    die("built without convert mode (NEUT_EXTGEN_CONVERT)");
#endif
  }
  if (mode != "serve" && mode != "xsec" && mode != "info") die("-m serve, xsec, convert or info");
  if (card.empty()) die("give the card with -c");

  if (mode == "serve") {
    if (reqPath.empty() || evPath.empty() || statPath.empty()) die("serve needs -r, -s and -t");
    if (seed <= 1 || seed >= 900000000) die("give -S SEED with 1 < SEED < 900000000");
    WriteSeedFile(seed, "neut_extgen_seed.txt");
  } else {
    WriteSeedFile(12345, "neut_extgen_seed.txt");   // cross sections draw no random numbers
  }
  InitNEUT(card);
  if (FortMod::neutcardIF::copy().rng_seed != 0)
    die("the card must have rng_seed = \"file\" (neut_extgen seeds NEUT through RANFILE)");
  const ModeMasks masks = FindMasks();

  if (mode == "info") {
    Info(masks);
  } else if (mode == "xsec") {
    if (ePath.empty() || outPath.empty()) die("xsec needs -e and -o");
    std::vector<int> tgts;
    if (tgtList.empty()) {
      for (int t : kDirect) tgts.push_back(t);
      for (auto const& kv : kSubstitutes) tgts.push_back(kv.first);
      for (int t : kZero) tgts.push_back(t);
      std::sort(tgts.begin(), tgts.end());
    } else {
      tgts = IntList(tgtList);
    }
    for (int t : tgts)
      if (!kZero.count(t)) GenTarget(t);
    if (nPB > 0 && pbPath.empty()) die("-b needs the energies of the blocking estimate (-B)");
    Xsec(masks, ePath, outPath, IntList(nuList), tgts, card, nPB, pbPath);
  } else {
    Serve(masks, ReadRequests(reqPath), reqPath, evPath, statPath, seed, card);
  }
  return 0;
}
