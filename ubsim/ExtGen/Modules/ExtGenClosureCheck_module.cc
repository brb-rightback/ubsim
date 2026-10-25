////////////////////////////////////////////////////////////////////////
/// \file  ExtGenClosureCheck_module.cc
/// \brief GENIE closure test (V2): compares, event by event, the full GENIE
///        record of step A with what ExtGenMerge rebuilt from it after the
///        round trip through the request and served-event files
///        (ExtGenRequestDumper + ExtGenTruthServer).
///
/// Compared, for every MCTruth:
///   - neutrino and target particles: identical;
///   - MCNeutrino: current, mode, interaction type, target, struck nucleon
///     identical; W, x, y, Q2 within Tolerance (relative);
///   - final state (struck nucleon, primary lepton, then the other status
///     1/15 particles in GENIE's order): same status and PDG; momenta equal
///     within Tolerance (RandomAzimuth false) or, with RandomAzimuth true,
///     the same energy and the same components along and across the
///     neutrino direction; all merged particles exactly at the neutrino
///     vertex and time (GENIE's own intranuclear offsets are only reported);
///   - GTruth: interaction and scattering type, target and struck nucleon;
///   - MCFlux through the associations, and BeamGateInfo: identical;
///   - POTSummary of every subrun: identical.
/// Any difference is printed and makes the job fail at endJob.
////////////////////////////////////////////////////////////////////////

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "art/Framework/Core/EDAnalyzer.h"
#include "art/Framework/Core/ModuleMacros.h"
#include "art/Framework/Principal/Event.h"
#include "art/Framework/Principal/Handle.h"
#include "art/Framework/Principal/SubRun.h"
#include "canvas/Persistency/Common/FindOne.h"
#include "canvas/Utilities/Exception.h"
#include "canvas/Utilities/InputTag.h"
#include "fhiclcpp/types/Atom.h"
#include "messagefacility/MessageLogger/MessageLogger.h"

#include "larcoreobj/SummaryData/POTSummary.h"
#include "lardataobj/Simulation/BeamGateInfo.h"
#include "nusimdata/SimulationBase/GTruth.h"
#include "nusimdata/SimulationBase/MCFlux.h"
#include "nusimdata/SimulationBase/MCNeutrino.h"
#include "nusimdata/SimulationBase/MCTruth.h"

namespace ubext {
  class ExtGenClosureCheck;
}

class ubext::ExtGenClosureCheck : public art::EDAnalyzer {
public:
  struct Config {
    using Name = fhicl::Name;
    using Comment = fhicl::Comment;

    fhicl::Atom<art::InputTag> OriginalTruth {
      Name("OriginalTruth"),
      Comment("full GENIE products of step A, e.g. \"generator::ExtGenClosureA\"")
    };
    fhicl::Atom<art::InputTag> MergedTruth {
      Name("MergedTruth"),
      Comment("ExtGenMerge products, e.g. \"generator::ExtGenMerge\"")
    };
    fhicl::Atom<bool> RandomAzimuth {
      Name("RandomAzimuth"),
      Comment("must match ExtGenMerge's RandomAzimuth")
    };
    fhicl::Atom<double> Tolerance {
      Name("Tolerance"),
      Comment("relative tolerance on momenta and kinematics"),
      1e-9
    };
  };
  using Parameters = art::EDAnalyzer::Table<Config>;

  explicit ExtGenClosureCheck(Parameters const& config);

  void analyze(art::Event const& event) override;
  void endSubRun(art::SubRun const& sr) override;
  void endJob() override;

private:
  void fail(std::string const& what);
  bool close(double a, double b, double scale = 1.) const
  {
    return std::abs(a - b) <= fTol * std::max({1., scale, std::abs(a), std::abs(b)});
  }

  art::InputTag fOriginal;
  art::InputTag fMerged;
  bool fRandomAzimuth;
  double fTol;

  unsigned long fNTruths = 0, fNParticles = 0, fNSubRuns = 0, fNFailures = 0;
  double fMaxDev = 0.;           // largest relative momentum deviation
  double fMaxHitNucDev = 0.;     // GTruth fHitNucP4, informational
  double fMaxPosDev = 0.;        // GENIE vs merged status-1 positions [cm], informational
  double fMaxTimeDev = 0.;       // GENIE vs merged status-1 times [ns], informational
};

//------------------------------------------------------------------------------
ubext::ExtGenClosureCheck::ExtGenClosureCheck(Parameters const& config)
  : EDAnalyzer(config)
  , fOriginal(config().OriginalTruth())
  , fMerged(config().MergedTruth())
  , fRandomAzimuth(config().RandomAzimuth())
  , fTol(config().Tolerance())
{}

//------------------------------------------------------------------------------
void ubext::ExtGenClosureCheck::fail(std::string const& what)
{
  ++fNFailures;
  if (fNFailures <= 50) mf::LogError("ExtGenClosureCheck") << what;
}

//------------------------------------------------------------------------------
void ubext::ExtGenClosureCheck::analyze(art::Event const& event)
{
  auto const& orig = event.getValidHandle<std::vector<simb::MCTruth>>(fOriginal);
  auto const& merged = event.getValidHandle<std::vector<simb::MCTruth>>(fMerged);
  const std::string ev = "event " + std::to_string(event.event()) + " (subrun " +
                         std::to_string(event.subRun()) + ")";

  if (orig->size() != merged->size()) {
    fail(ev + ": " + std::to_string(orig->size()) + " original vs " +
         std::to_string(merged->size()) + " merged MCTruths");
    return;
  }

  art::FindOne<simb::MCFlux> origFlux(orig, event, fOriginal);
  art::FindOne<simb::MCFlux> mergedFlux(merged, event, fMerged);
  art::FindOne<simb::GTruth> origG(orig, event, fOriginal);
  art::FindOne<simb::GTruth> mergedG(merged, event, fMerged);

  for (size_t i = 0; i < orig->size(); ++i) {
    ++fNTruths;
    simb::MCTruth const& a = orig->at(i);
    simb::MCTruth const& b = merged->at(i);
    const std::string where = ev + " truth " + std::to_string(i);

    // --- neutrino and target
    for (int k = 0; k < 2; ++k) {
      simb::MCParticle const& pa = a.GetParticle(k);
      simb::MCParticle const& pb = b.GetParticle(k);
      if (pa.PdgCode() != pb.PdgCode() || pa.StatusCode() != pb.StatusCode() ||
          pa.Momentum() != pb.Momentum() || pa.Position() != pb.Position()) {
        fail(where + ": particle " + std::to_string(k) + " (neutrino/target) differs");
      }
    }

    // --- MCNeutrino
    simb::MCNeutrino const& na = a.GetNeutrino();
    simb::MCNeutrino const& nb = b.GetNeutrino();
    if (na.CCNC() != nb.CCNC() || na.Mode() != nb.Mode() ||
        na.InteractionType() != nb.InteractionType() || na.Target() != nb.Target() ||
        na.HitNuc() != nb.HitNuc()) {
      fail(where + ": MCNeutrino codes differ (ccnc " + std::to_string(na.CCNC()) + "/" +
           std::to_string(nb.CCNC()) + ", mode " + std::to_string(na.Mode()) + "/" +
           std::to_string(nb.Mode()) + ", inttype " + std::to_string(na.InteractionType()) +
           "/" + std::to_string(nb.InteractionType()) + ", hitnuc " +
           std::to_string(na.HitNuc()) + "/" + std::to_string(nb.HitNuc()) + ")");
    }
    // W and x are -1 (no struck nucleon) or computed; NaN only if both are.
    auto sameKine = [&](double x, double y) {
      return (std::isnan(x) && std::isnan(y)) || close(x, y);
    };
    if (!sameKine(na.W(), nb.W()) || !sameKine(na.X(), nb.X()) ||
        !sameKine(na.Y(), nb.Y()) || !sameKine(na.QSqr(), nb.QSqr())) {
      fail(where + ": W/x/y/Q2 differ: " + std::to_string(na.W()) + "/" +
           std::to_string(nb.W()) + " " + std::to_string(na.X()) + "/" +
           std::to_string(nb.X()) + " " + std::to_string(na.Y()) + "/" +
           std::to_string(nb.Y()) + " " + std::to_string(na.QSqr()) + "/" +
           std::to_string(nb.QSqr()));
    }

    // --- final state, in the order ExtGenMerge writes it
    std::vector<simb::MCParticle const*> expect;
    for (int k = 0; k < a.NParticles(); ++k)
      if (a.GetParticle(k).StatusCode() == 11) { expect.push_back(&a.GetParticle(k)); break; }
    int iLepton = -1;
    for (int k = 0; k < a.NParticles(); ++k) {
      if (a.GetParticle(k).TrackId() == na.Lepton().TrackId()) { iLepton = k; break; }
    }
    if (iLepton >= 0) expect.push_back(&a.GetParticle(iLepton));
    for (int k = 0; k < a.NParticles(); ++k) {
      const int st = a.GetParticle(k).StatusCode();
      if (k != iLepton && (st == 1 || st == 15)) expect.push_back(&a.GetParticle(k));
    }
    if (static_cast<int>(expect.size()) + 2 != b.NParticles()) {
      fail(where + ": " + std::to_string(expect.size()) + " expected vs " +
           std::to_string(b.NParticles() - 2) + " merged final-state particles");
      continue;
    }

    const TVector3 dir = na.Nu().Momentum().Vect().Unit();
    const TLorentzVector vtx = na.Nu().Position();
    for (size_t k = 0; k < expect.size(); ++k) {
      ++fNParticles;
      simb::MCParticle const& pa = *expect[k];
      simb::MCParticle const& pb = b.GetParticle(k + 2);
      const std::string pw = where + " particle " + std::to_string(k + 2) + " (pdg " +
                             std::to_string(pa.PdgCode()) + ")";
      if (pa.PdgCode() != pb.PdgCode() || pa.StatusCode() != pb.StatusCode()) {
        fail(pw + ": pdg/status " + std::to_string(pb.PdgCode()) + "/" +
             std::to_string(pb.StatusCode()) + " merged");
        continue;
      }
      TLorentzVector const& ma = pa.Momentum();
      TLorentzVector const& mb = pb.Momentum();
      const double scale = std::max(1., ma.E());
      double dev;
      if (fRandomAzimuth) {
        const double la = ma.Vect().Dot(dir), lb = mb.Vect().Dot(dir);
        const double ta = ma.Vect().Cross(dir).Mag(), tb = mb.Vect().Cross(dir).Mag();
        dev = std::max({std::abs(ma.E() - mb.E()), std::abs(la - lb), std::abs(ta - tb)});
      }
      else {
        dev = std::max((ma.Vect() - mb.Vect()).Mag(), std::abs(ma.E() - mb.E()));
      }
      fMaxDev = std::max(fMaxDev, dev / scale);
      if (dev > fTol * scale) {
        fail(pw + ": momentum differs by " + std::to_string(dev) + " GeV");
      }
      // merged particles must sit exactly at the step-A vertex; GENIE's own
      // positions/times include intranuclear offsets (informational)
      if (pb.Position() != vtx) fail(pw + ": not at the neutrino vertex/time");
      if (pa.StatusCode() == 1) {
        fMaxPosDev = std::max(fMaxPosDev, (pa.Position().Vect() - pb.Position().Vect()).Mag());
        fMaxTimeDev = std::max(fMaxTimeDev, std::abs(pa.T() - pb.T()));
      }
    }

    // --- GTruth and MCFlux through the associations
    cet::maybe_ref<simb::GTruth const> ga = origG.at(i), gb = mergedG.at(i);
    cet::maybe_ref<simb::MCFlux const> fa = origFlux.at(i), fb = mergedFlux.at(i);
    if (!ga.isValid() || !gb.isValid() || !fa.isValid() || !fb.isValid()) {
      fail(where + ": missing GTruth/MCFlux association");
      continue;
    }
    simb::GTruth const& gta = ga.ref();
    simb::GTruth const& gtb = gb.ref();
    if (gta.fGint != gtb.fGint || gta.fGscatter != gtb.fGscatter ||
        gta.ftgtPDG != gtb.ftgtPDG || gta.fHitNucPDG != gtb.fHitNucPDG ||
        gta.fProbePDG != gtb.fProbePDG) {
      fail(where + ": GTruth differs (Gint " + std::to_string(gta.fGint) + "/" +
           std::to_string(gtb.fGint) + ", Gscatter " + std::to_string(gta.fGscatter) + "/" +
           std::to_string(gtb.fGscatter) + ", hitnuc " + std::to_string(gta.fHitNucPDG) +
           "/" + std::to_string(gtb.fHitNucPDG) + ")");
    }
    if (gta.fHitNucPDG != 0) {
      const double d = fRandomAzimuth
        ? std::abs(gta.fHitNucP4.E() - gtb.fHitNucP4.E())
        : (gta.fHitNucP4 - gtb.fHitNucP4).Vect().Mag() + std::abs(gta.fHitNucP4.E() - gtb.fHitNucP4.E());
      fMaxHitNucDev = std::max(fMaxHitNucDev, d);
    }

    simb::MCFlux const& xa = fa.ref();
    simb::MCFlux const& xb = fb.ref();
    if (xa.frun != xb.frun || xa.fevtno != xb.fevtno || xa.fntype != xb.fntype ||
        xa.fnenergy != xb.fnenergy || xa.fnimpwt != xb.fnimpwt || xa.fndecay != xb.fndecay ||
        xa.fptype != xb.fptype || xa.fvx != xb.fvx || xa.fvy != xb.fvy || xa.fvz != xb.fvz ||
        xa.fpdpx != xb.fpdpx || xa.fpdpy != xb.fpdpy || xa.fpdpz != xb.fpdpz ||
        xa.fppenergy != xb.fppenergy || xa.ftptype != xb.ftptype || xa.ftgen != xb.ftgen ||
        xa.fnwtnear != xb.fnwtnear || xa.fnwtfar != xb.fnwtfar ||
        xa.fgenx != xb.fgenx || xa.fgeny != xb.fgeny || xa.fgenz != xb.fgenz ||
        xa.fdk2gen != xb.fdk2gen || xa.fgen2vtx != xb.fgen2vtx) {
      fail(where + ": MCFlux differs");
    }
  }

  // --- beam gate
  auto const& gA = event.getValidHandle<std::vector<sim::BeamGateInfo>>(fOriginal);
  auto const& gB = event.getValidHandle<std::vector<sim::BeamGateInfo>>(fMerged);
  bool same = gA->size() == gB->size();
  for (size_t k = 0; same && k < gA->size(); ++k) {
    same = gA->at(k).Start() == gB->at(k).Start() && gA->at(k).Width() == gB->at(k).Width() &&
           gA->at(k).BeamType() == gB->at(k).BeamType();
  }
  if (!same) fail(ev + ": BeamGateInfo differs");
}

//------------------------------------------------------------------------------
void ubext::ExtGenClosureCheck::endSubRun(art::SubRun const& sr)
{
  ++fNSubRuns;
  auto const& a = sr.getValidHandle<sumdata::POTSummary>(fOriginal);
  auto const& b = sr.getValidHandle<sumdata::POTSummary>(fMerged);
  if (a->totpot != b->totpot || a->totgoodpot != b->totgoodpot ||
      a->totspills != b->totspills || a->goodspills != b->goodspills) {
    fail("subrun " + std::to_string(sr.subRun()) + ": POTSummary differs (" +
         std::to_string(a->totpot) + " vs " + std::to_string(b->totpot) + ")");
  }
}

//------------------------------------------------------------------------------
void ubext::ExtGenClosureCheck::endJob()
{
  mf::LogInfo("ExtGenClosureCheck")
    << "Closure check: " << fNTruths << " interactions, " << fNParticles
    << " final-state particles, " << fNSubRuns << " subruns compared ("
    << (fRandomAzimuth ? "random azimuth: E, p_long, p_trans" : "no azimuth: components")
    << ").\n  largest relative momentum deviation: " << fMaxDev
    << "\n  informational (GENIE-internal differences):"
    << "\n    largest GTruth hit-nucleon P4 deviation [GeV]: " << fMaxHitNucDev
    << "\n    largest GENIE vs merged status-1 position [cm]: " << fMaxPosDev
    << "  time [ns]: " << fMaxTimeDev
    << "\n  failures: " << fNFailures;
  if (fNFailures != 0) {
    throw art::Exception(art::errors::EndJobFailure)
      << "ExtGenClosureCheck: " << fNFailures << " differences (first 50 printed above)\n";
  }
}

DEFINE_ART_MODULE(ubext::ExtGenClosureCheck)
