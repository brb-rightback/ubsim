////////////////////////////////////////////////////////////////////////
/// \file  ExtGenMerge_module.cc
/// \brief Step D of the ExtGen chain: combines each step-A interaction
///        (GENIE's choice of neutrino, target, current, energy, vertex,
///        time and flux) with the final state served for it by the
///        external generator, and writes the same products as GENIEGen.
///
/// Inputs: the step-A products (label InputTruth), the request file
/// written from them (ExtGenRequestDumper) and the served-event file (see
/// ExtGenIO.h for both formats). Every step-A MCTruth must have exactly one
/// request and one served event, with bit-identical energies; served
/// events that are never used are an error at the end of the job
/// (RequireAllServed).
///
/// For each MCTruth the new record holds:
///   - the step-A neutrino and target (status 0), unchanged;
///   - the served particles, rotated from the generator frame (neutrino
///     along +z) onto the neutrino direction after a random azimuth
///     (RandomAzimuth), all at the step-A vertex and time: the struck
///     nucleon (status 11, mother: target), the primary lepton, then the
///     others in served order (mother: neutrino);
///   - SetNeutrino with the step-A current and target, the served mode and
///     interaction type, the struck nucleon (status-11 particle, or the
///     target itself for a free nucleon), and W, x, y, Q2 from the lepton
///     kinematics as in nutools' GENIE2ART (x and W only with a struck
///     nucleon or nucleon cluster, or for coherent scattering).
/// GTruth is the step-A one with the scattering type, struck nucleon and
/// kinematics replaced (pre-FSI particle counts, resonance and decay mode
/// are not known for external generators and are set to -1).
/// MCFlux, BeamGateInfo, Dk2Nu, NuChoice, POTSummary and RunData are copied.
////////////////////////////////////////////////////////////////////////

#include <cmath>
#include <iomanip>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "CLHEP/Random/RandFlat.h"
#include "TMath.h"

#include "art/Framework/Core/EDProducer.h"
#include "art/Framework/Core/ModuleMacros.h"
#include "art/Framework/Principal/Event.h"
#include "art/Framework/Principal/Handle.h"
#include "art/Framework/Principal/Run.h"
#include "art/Framework/Principal/SubRun.h"
#include "art/Framework/Services/Registry/ServiceHandle.h"
#include "canvas/Persistency/Common/Assns.h"
#include "canvas/Persistency/Common/FindOne.h"
#include "canvas/Utilities/Exception.h"
#include "canvas/Utilities/InputTag.h"
#include "fhiclcpp/ParameterSet.h"
#include "messagefacility/MessageLogger/MessageLogger.h"
#include "nutools/RandomUtils/NuRandomService.h"

#include "dk2nu/tree/NuChoice.h"
#include "dk2nu/tree/dk2nu.h"
#include "larcoreobj/SummaryData/POTSummary.h"
#include "larcoreobj/SummaryData/RunData.h"
#include "lardata/Utilities/AssociationUtil.h"
#include "lardataobj/Simulation/BeamGateInfo.h"
#include "nusimdata/SimulationBase/GTruth.h"
#include "nusimdata/SimulationBase/MCFlux.h"
#include "nusimdata/SimulationBase/MCNeutrino.h"
#include "nusimdata/SimulationBase/MCParticle.h"
#include "nusimdata/SimulationBase/MCTruth.h"

#include "ubsim/ExtGen/Modules/ExtGenIO.h"

namespace ubext {
  class ExtGenMerge;
}

class ubext::ExtGenMerge : public art::EDProducer {
public:
  explicit ExtGenMerge(fhicl::ParameterSet const& p);

  ExtGenMerge(ExtGenMerge const&) = delete;
  ExtGenMerge(ExtGenMerge&&) = delete;
  ExtGenMerge& operator=(ExtGenMerge const&) = delete;
  ExtGenMerge& operator=(ExtGenMerge&&) = delete;

  void produce(art::Event& e) override;
  void beginRun(art::Run& r) override;
  void endSubRun(art::SubRun& sr) override;
  void endJob() override;

private:
  simb::MCTruth BuildTruth(simb::MCTruth const& stepA, ServedEvent const& served,
                           Request const& req, simb::GTruth& gtruth,
                           std::string const& where);

  art::InputTag fInputTruth;
  std::string fRequestFile;
  std::string fServedFile;
  bool fRandomAzimuth;
  bool fRequireAllServed;
  CLHEP::HepRandomEngine& fEngine;

  RequestFile fRequests;
  ServedFile fServed;
  std::set<long> fUsed;
};

namespace {

  // GENIE's mass for x and W (genie::constants::kNucleonMass in
  // GENIE v3_00_04), as used by GENIE2ART.
  constexpr double kNucleonMass = (9.38272081e-01 + 9.39565413e-01) / 2.;

  // simb interaction mode -> genie::ScatteringType_t, the inverse of the
  // mapping in nutools' GENIE2ART.
  int GenieScatteringType(int mode)
  {
    switch (mode) {
    case simb::kQE:                return 1;   // kScQuasiElastic
    case simb::kDIS:               return 3;   // kScDeepInelastic
    case simb::kRes:               return 4;   // kScResonant
    case simb::kCoh:               return 5;   // kScCoherent
    case simb::kDiffractive:       return 6;   // kScDiffractive
    case simb::kNuElectronElastic: return 7;   // kScNuElectronElastic
    case simb::kInverseMuDecay:    return 8;   // kScInverseMuDecay
    case simb::kAMNuGamma:         return 9;   // kScAMNuGamma
    case simb::kMEC:               return 10;  // kScMEC
    case simb::kCohElastic:        return 11;  // kScCoherentElas
    case simb::kInverseBetaDecay:  return 12;  // kScInverseBetaDecay
    case simb::kGlashowResonance:  return 13;  // kScGlashowResonance
    case simb::kIMDAnnihilation:   return 14;  // kScIMDAnnihilation
    default:                       return 0;   // kScNull
    }
  }

  // Step A's particle 1 is the target: the nucleus, or the nucleon itself
  // for a free-nucleon target.
  bool IsTargetParticle(int pdg, int tgtPdg)
  {
    return pdg == tgtPdg || (tgtPdg == 1000010010 && pdg == 2212) ||
           (tgtPdg == 1000000010 && pdg == 2112);
  }

} // namespace

//------------------------------------------------------------------------------
ubext::ExtGenMerge::ExtGenMerge(fhicl::ParameterSet const& p)
  : EDProducer{p}
  , fInputTruth(p.get<art::InputTag>("InputTruth", "generator"))
  , fRequestFile(p.get<std::string>("RequestFile"))
  , fServedFile(p.get<std::string>("ServedFile"))
  , fRandomAzimuth(p.get<bool>("RandomAzimuth", true))
  , fRequireAllServed(p.get<bool>("RequireAllServed", true))
  // seed from NuRandomService unless "Seed" is set
  , fEngine(art::ServiceHandle<rndm::NuRandomService>()->createEngine(*this, p, "Seed"))
{
  fRequests = ReadRequests(fRequestFile);
  fServed = ReadServed(fServedFile);
  {
    mf::LogInfo log("ExtGenMerge");
    log << "Read " << fRequests.requests.size() << " requests from " << fRequestFile
        << " and " << fServed.events.size() << " served events from " << fServedFile;
    for (auto const& h : fServed.header) log << "\n  " << h;
  }

  produces<std::vector<simb::MCTruth>>();
  produces<std::vector<simb::MCFlux>>();
  produces<std::vector<simb::GTruth>>();
  produces<std::vector<sim::BeamGateInfo>>();
  produces<std::vector<bsim::Dk2Nu>>();
  produces<std::vector<bsim::NuChoice>>();
  produces<art::Assns<simb::MCTruth, simb::MCFlux>>();
  produces<art::Assns<simb::MCTruth, simb::GTruth>>();
  produces<art::Assns<simb::MCTruth, bsim::Dk2Nu>>();
  produces<art::Assns<simb::MCTruth, bsim::NuChoice>>();
  produces<sumdata::POTSummary, art::InSubRun>();
  produces<sumdata::RunData, art::InRun>();
}

//------------------------------------------------------------------------------
void ubext::ExtGenMerge::beginRun(art::Run& r)
{
  auto const& rd = r.getValidHandle<sumdata::RunData>(fInputTruth);
  r.put(std::make_unique<sumdata::RunData>(*rd));
}

//------------------------------------------------------------------------------
void ubext::ExtGenMerge::endSubRun(art::SubRun& sr)
{
  // Step A's POT for this subrun (with one event per subrun, the exact POT
  // behind that event).
  auto const& pot = sr.getValidHandle<sumdata::POTSummary>(fInputTruth);
  sr.put(std::make_unique<sumdata::POTSummary>(*pot));
}

//------------------------------------------------------------------------------
simb::MCTruth ubext::ExtGenMerge::BuildTruth(simb::MCTruth const& stepA,
                                             ServedEvent const& served,
                                             Request const& req, simb::GTruth& gtruth,
                                             std::string const& where)
{
  if (stepA.NParticles() < 2) {
    throw art::Exception(art::errors::LogicError)
      << "ExtGenMerge: step-A MCTruth " << where << " has " << stepA.NParticles()
      << " particles, expected the neutrino and the target first\n";
  }
  simb::MCParticle const& nu = stepA.GetParticle(0);
  simb::MCParticle const& tgt = stepA.GetParticle(1);
  if (nu.StatusCode() != 0 || nu.PdgCode() != req.nuPdg || tgt.StatusCode() != 0 ||
      !IsTargetParticle(tgt.PdgCode(), req.tgtPdg)) {
    throw art::Exception(art::errors::LogicError)
      << "ExtGenMerge: step-A MCTruth " << where << " does not start with the requested"
      << " neutrino " << req.nuPdg << " and target " << req.tgtPdg << " (found "
      << nu.PdgCode() << " status " << nu.StatusCode() << ", " << tgt.PdgCode()
      << " status " << tgt.StatusCode() << ")\n";
  }

  // --- check the served particles
  int nHit = 0;
  int iLepton = -1;
  for (size_t i = 0; i < served.particles.size(); ++i) {
    auto const& p = served.particles[i];
    if (p.status != 1 && p.status != 2 && p.status != 11 && p.status != 15) {
      throw art::Exception(art::errors::LogicError)
        << "ExtGenMerge: request " << served.reqId << ": particle " << i << " has status "
        << p.status << " (allowed: 1, 2, 11, 15)\n";
    }
    if (p.status == 11) ++nHit;
    if (p.status == 1 && iLepton < 0) iLepton = i;
  }
  if (nHit > 1) {
    throw art::Exception(art::errors::LogicError)
      << "ExtGenMerge: request " << served.reqId << " has " << nHit << " struck nucleons\n";
  }
  const int sign = (req.nuPdg > 0) ? 1 : -1;
  const int wantLepton = req.isCC ? req.nuPdg - sign : req.nuPdg;
  if (iLepton < 0 || served.particles[iLepton].pdg != wantLepton) {
    throw art::Exception(art::errors::LogicError)
      << "ExtGenMerge: request " << served.reqId << " (" << (req.isCC ? "CC" : "NC")
      << ", nu " << req.nuPdg << "): the first final-state particle must be the primary"
      << " lepton " << wantLepton << ", found "
      << (iLepton < 0 ? 0 : served.particles[iLepton].pdg) << "\n";
  }

  // --- rotation onto the neutrino direction
  const double phi = fRandomAzimuth ? CLHEP::RandFlat::shoot(&fEngine, 0., TMath::TwoPi()) : 0.;
  const TRotation rot = GeneratorToDetector(nu.Momentum().Vect(), phi);
  const TLorentzVector vtx = nu.Position();

  simb::MCTruth truth;
  truth.SetOrigin(stepA.Origin());
  simb::MCParticle nuCopy(nu), tgtCopy(tgt);  // MCTruth::Add takes a non-const reference
  truth.Add(nuCopy);
  truth.Add(tgtCopy);

  // struck nucleon first (mother: target), then the primary lepton, then
  // the others in served order (mother: neutrino), so that the lepton is
  // the first daughter of the neutrino, which is what MCTruth::SetNeutrino
  // takes as the lepton.
  int hitPdg = 0;
  TLorentzVector hitP4;
  TLorentzVector leptonP4;
  int trackId = 2;
  for (int pass = 0; pass < 3; ++pass) {
    for (size_t i = 0; i < served.particles.size(); ++i) {
      auto const& sp = served.particles[i];
      const bool isHit = (sp.status == 11);
      const bool isLepton = (static_cast<int>(i) == iLepton);
      if ((pass == 0 && !isHit) || (pass == 1 && !isLepton) ||
          (pass == 2 && (isHit || isLepton))) continue;
      const TLorentzVector p4 = Rotate(rot, sp.p4);
      const double m2 = p4.M2();
      simb::MCParticle part(trackId++, sp.pdg, "primary",
                            (sp.status == 11 ? tgt.TrackId() : nu.TrackId()),
                            (m2 > 0. ? std::sqrt(m2) : 0.), sp.status);
      part.AddTrajectoryPoint(vtx, p4);
      truth.Add(part);
      if (isHit) { hitPdg = sp.pdg; hitP4 = p4; }
      if (isLepton) leptonP4 = p4;
    }
  }

  // A free-nucleon target is itself the struck nucleon (as in GENIE, which
  // then has no status-11 entry).
  if (hitPdg == 0 && (req.tgtPdg == 1000010010 || req.tgtPdg == 1000000010)) {
    hitPdg = (req.tgtPdg == 1000010010) ? 2212 : 2112;
    hitP4 = tgt.Momentum();
  }

  // --- kinematics from the lepton, as in GENIE2ART
  const TLorentzVector& k1 = nu.Momentum();
  const TLorentzVector q = k1 - leptonP4;
  const double Q2 = -q.M2();
  const double v = q.E();
  const double y = v / k1.E();
  double x = -1., W = -1.;
  if (hitPdg != 0 || served.mode == simb::kCoh) {
    const double M = kNucleonMass;
    x = 0.5 * Q2 / (M * v);
    W = std::sqrt(M * M + 2 * M * v - Q2);
  }
  truth.SetNeutrino(req.isCC ? simb::kCC : simb::kNC, served.mode, served.intType,
                    req.tgtPdg, hitPdg, 0, W, x, y, Q2);

  // --- GTruth: step A's, with what the external generator decided
  gtruth.fGscatter = GenieScatteringType(served.mode);
  // fHitNucPDG is left as step A wrote it: GENIE2ART (nutools v2_27_11)
  // never fills it; the hit nucleon is in MCNeutrino::HitNuc().
  gtruth.fHitNucP4 = hitP4;
  gtruth.fHitQrkPDG = 0;
  gtruth.fIsSeaQuark = false;
  gtruth.fgQ2 = Q2;
  gtruth.fgq2 = -Q2;
  gtruth.fgW = W;
  gtruth.fgX = x;
  gtruth.fgY = y;
  gtruth.fFSleptonP4 = leptonP4;
  gtruth.fFShadSystP4 = q + hitP4;
  gtruth.fIsCharm = false;
  gtruth.fCharmHadronPdg = 0;
  gtruth.fIsStrange = false;
  gtruth.fStrangeHadronPdg = 0;
  gtruth.fNumProton = gtruth.fNumNeutron = gtruth.fNumPi0 = -1;
  gtruth.fNumPiPlus = gtruth.fNumPiMinus = -1;
  gtruth.fResNum = -1;
  gtruth.fDecayMode = -1;

  return truth;
}

//------------------------------------------------------------------------------
void ubext::ExtGenMerge::produce(art::Event& e)
{
  auto const& truthHandle = e.getValidHandle<std::vector<simb::MCTruth>>(fInputTruth);
  art::FindOne<simb::GTruth> gtruths(truthHandle, e, fInputTruth);
  art::FindOne<simb::MCFlux> fluxes(truthHandle, e, fInputTruth);
  art::FindOne<bsim::Dk2Nu> dk2nus(truthHandle, e, fInputTruth);
  art::FindOne<bsim::NuChoice> nuchoices(truthHandle, e, fInputTruth);

  auto truthcol = std::make_unique<std::vector<simb::MCTruth>>();
  auto fluxcol = std::make_unique<std::vector<simb::MCFlux>>();
  auto gtruthcol = std::make_unique<std::vector<simb::GTruth>>();
  auto dk2nucol = std::make_unique<std::vector<bsim::Dk2Nu>>();
  auto nuchoicecol = std::make_unique<std::vector<bsim::NuChoice>>();
  auto tfassn = std::make_unique<art::Assns<simb::MCTruth, simb::MCFlux>>();
  auto tgassn = std::make_unique<art::Assns<simb::MCTruth, simb::GTruth>>();
  auto dk2nuassn = std::make_unique<art::Assns<simb::MCTruth, bsim::Dk2Nu>>();
  auto nuchoiceassn = std::make_unique<art::Assns<simb::MCTruth, bsim::NuChoice>>();

  for (size_t i = 0; i < truthHandle->size(); ++i) {
    simb::MCTruth const& stepA = truthHandle->at(i);
    std::ostringstream where;
    where << i << " of event " << e.id();

    // --- request and served event for this MCTruth
    const RequestKey key(e.run(), e.subRun(), e.event(), i);
    auto rit = fRequests.requests.find(key);
    if (rit == fRequests.requests.end()) {
      throw art::Exception(art::errors::NotFound)
        << "ExtGenMerge: no request for MCTruth " << where.str() << " in " << fRequestFile
        << "\n";
    }
    Request const& req = rit->second;
    if (!stepA.NeutrinoSet() || stepA.GetNeutrino().Nu().E() != req.E ||
        stepA.GetNeutrino().Nu().PdgCode() != req.nuPdg ||
        stepA.GetNeutrino().Target() != req.tgtPdg ||
        (stepA.GetNeutrino().CCNC() == simb::kCC) != req.isCC) {
      throw art::Exception(art::errors::LogicError)
        << "ExtGenMerge: request " << req.reqId << " in " << fRequestFile
        << " does not match MCTruth " << where.str()
        << " (wrong request file for this input?)\n";
    }
    auto sit = fServed.events.find(req.reqId);
    if (sit == fServed.events.end()) {
      throw art::Exception(art::errors::NotFound)
        << "ExtGenMerge: request " << req.reqId << " (MCTruth " << where.str()
        << ") was not served in " << fServedFile << "\n";
    }
    ServedEvent const& served = sit->second;
    if (served.E != req.E) {
      throw art::Exception(art::errors::LogicError)
        << "ExtGenMerge: request " << req.reqId << " asked for E = "
        << std::setprecision(17) << req.E << " GeV but was served at " << served.E
        << " GeV\n";
    }
    if (!fUsed.insert(req.reqId).second) {
      throw art::Exception(art::errors::LogicError)
        << "ExtGenMerge: request " << req.reqId << " used twice\n";
    }

    // --- step-A friends
    cet::maybe_ref<simb::GTruth const> gref = gtruths.at(i);
    cet::maybe_ref<simb::MCFlux const> fref = fluxes.at(i);
    if (!gref.isValid() || !fref.isValid()) {
      throw art::Exception(art::errors::ProductNotFound)
        << "ExtGenMerge: MCTruth " << where.str() << " has no associated "
        << (gref.isValid() ? "MCFlux" : "GTruth") << "\n";
    }
    simb::GTruth gtruth = gref.ref();

    truthcol->push_back(BuildTruth(stepA, served, req, gtruth, where.str()));
    fluxcol->push_back(fref.ref());
    gtruthcol->push_back(gtruth);
    util::CreateAssn(*this, e, *truthcol, *fluxcol, *tfassn, fluxcol->size() - 1, fluxcol->size());
    util::CreateAssn(*this, e, *truthcol, *gtruthcol, *tgassn, gtruthcol->size() - 1, gtruthcol->size());

    cet::maybe_ref<bsim::Dk2Nu const> dref = dk2nus.at(i);
    if (dref.isValid()) {
      dk2nucol->push_back(dref.ref());
      util::CreateAssn(*this, e, *truthcol, *dk2nucol, *dk2nuassn, dk2nucol->size() - 1, dk2nucol->size());
    }
    cet::maybe_ref<bsim::NuChoice const> cref = nuchoices.at(i);
    if (cref.isValid()) {
      nuchoicecol->push_back(cref.ref());
      util::CreateAssn(*this, e, *truthcol, *nuchoicecol, *nuchoiceassn, nuchoicecol->size() - 1, nuchoicecol->size());
    }
  }

  auto const& gates = e.getValidHandle<std::vector<sim::BeamGateInfo>>(fInputTruth);
  e.put(std::make_unique<std::vector<sim::BeamGateInfo>>(*gates));

  e.put(std::move(truthcol));
  e.put(std::move(fluxcol));
  e.put(std::move(gtruthcol));
  e.put(std::move(dk2nucol));
  e.put(std::move(nuchoicecol));
  e.put(std::move(tfassn));
  e.put(std::move(tgassn));
  e.put(std::move(dk2nuassn));
  e.put(std::move(nuchoiceassn));
}

//------------------------------------------------------------------------------
void ubext::ExtGenMerge::endJob()
{
  const size_t unused = fServed.events.size() - fUsed.size();
  mf::LogInfo("ExtGenMerge") << "Merged " << fUsed.size() << " interactions; "
                             << unused << " served events not used";
  if (fRequireAllServed && unused != 0) {
    throw art::Exception(art::errors::EndJobFailure)
      << "ExtGenMerge: " << unused << " of " << fServed.events.size()
      << " served events in " << fServedFile << " were not used (RequireAllServed)\n";
  }
}

DEFINE_ART_MODULE(ubext::ExtGenMerge)
